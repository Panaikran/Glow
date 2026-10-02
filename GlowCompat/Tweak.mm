#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <os/log.h>
#import <stdarg.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

@interface GlowFloatingTabContextMenuDelegate : NSObject <UIContextMenuInteractionDelegate>
@property (nonatomic, weak) UIView *item;
@end

using GlowLegacyContextMenuIMP = id (*)(id, SEL, UIContextMenuInteraction *, CGPoint);

static NSString * const kFloatingBarName = @"FBFloatingTabBar";
static NSString * const kLegacyItemName = @"FBTabBarItemDefaultView";
static NSString * const kFloatingItemName = @"FBFloatingTabBar.FBFloatingTabBarItemView";
static NSString * const kGlowImageName = @"Glow.dylib";
static SEL gContextMenuSelector;
static Class gFloatingItemClass;
static GlowLegacyContextMenuIMP gLegacyContextMenuIMP;
static NSString *gGlowImagePath;
static IMP gOriginalLayoutSubviews;
static BOOL gCompatEnabled;
static NSUInteger gSetupGeneration;
static CFTimeInterval gLastSetupStart;
static NSString *gLastReadinessReason;

static char kDelegateAssociation;
static char kInteractionAssociation;
static char kSkipLogAssociation;

static void GCLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void GCEnsureContextMenuAttached(UIView *item);
static void GCScheduleSetup(void);
static void GCFloatingItemLayoutSubviews(id self, SEL selector);

static void GCLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "[GlowCompat] %{public}@", message);
}

static NSString *GCClassName(Class cls) {
    return cls ? NSStringFromClass(cls) : @"-";
}

static NSString *GCObjectClassName(id object) {
    return object ? GCClassName(object_getClass(object)) : @"-";
}

static NSString *GCSafeString(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length == 0) return @"-";
    NSString *singleLine = [value stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (singleLine.length <= 100) return singleLine;
    return [[singleLine substringToIndex:97] stringByAppendingString:@"..."];
}

static NSString *GCItemDescription(UIView *item) {
    NSString *label = [item respondsToSelector:@selector(accessibilityLabel)]
        ? GCSafeString(item.accessibilityLabel) : @"-";
    NSString *identifier = [item respondsToSelector:@selector(accessibilityIdentifier)]
        ? GCSafeString(item.accessibilityIdentifier) : @"-";
    return [NSString stringWithFormat:@"tab=%@ id=%@", label, identifier];
}

static NSString *GCImageForAddress(const void *address) {
    Dl_info info = {0};
    if (!address || dladdr(address, &info) == 0 || !info.dli_fname) return @"-";
    return [NSString stringWithUTF8String:info.dli_fname] ?: @"-";
}

static BOOL GCIsGlowImagePath(NSString *path) {
    return path.length > 0 && [path.lastPathComponent isEqualToString:kGlowImageName];
}

static NSString *GCLoadedGlowImagePath(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const char *rawPath = _dyld_get_image_name(index);
        if (!rawPath) continue;
        NSString *path = [NSString stringWithUTF8String:rawPath];
        if (GCIsGlowImagePath(path)) return path;
    }
    return nil;
}

static Method GCDirectMethod(Class cls, SEL selector) {
    if (!cls || !selector) return NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method result = NULL;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            result = methods[index];
            break;
        }
    }
    free(methods);
    return result;
}

static const char *GCSkipTypeQualifiers(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL GCObjectType(const char *type) {
    type = GCSkipTypeQualifiers(type);
    return type && type[0] == '@';
}

static BOOL GCContextMenuSignatureIsCompatible(Method method) {
    if (!method || method_getNumberOfArguments(method) != 4) return NO;

    char *returnType = method_copyReturnType(method);
    char *selfType = method_copyArgumentType(method, 0);
    char *selectorType = method_copyArgumentType(method, 1);
    char *interactionType = method_copyArgumentType(method, 2);
    char *locationType = method_copyArgumentType(method, 3);

    NSUInteger locationSize = 0;
    BOOL locationIsPoint = NO;
    if (locationType) {
        const char *type = GCSkipTypeQualifiers(locationType);
        if (type && strncmp(type, "{CGPoint=", sizeof("{CGPoint=") - 1) == 0) {
            NSGetSizeAndAlignment(type, &locationSize, NULL);
            locationIsPoint = locationSize == sizeof(CGPoint);
        }
    }

    BOOL compatible = GCObjectType(returnType) && GCObjectType(selfType) &&
        GCSkipTypeQualifiers(selectorType) && GCSkipTypeQualifiers(selectorType)[0] == ':' &&
        GCObjectType(interactionType) && locationIsPoint;
    free(returnType);
    free(selfType);
    free(selectorType);
    free(interactionType);
    free(locationType);
    return compatible;
}

static BOOL GCIsFacebookProcess(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.facebook.Facebook"];
}

static BOOL GCInstallFloatingItemLayoutHook(NSString **failure) {
    SEL selector = @selector(layoutSubviews);
    Method resolved = class_getInstanceMethod(gFloatingItemClass, selector);
    if (!resolved) {
        if (failure) *failure = @"floating-item-layoutSubviews-missing";
        return NO;
    }

    Method direct = GCDirectMethod(gFloatingItemClass, selector);
    IMP original = method_getImplementation(resolved);
    const char *types = method_getTypeEncoding(resolved);
    if (!original || !types || original == (IMP)GCFloatingItemLayoutSubviews) {
        if (failure) *failure = @"floating-item-layoutSubviews-invalid";
        return NO;
    }
    gOriginalLayoutSubviews = original;

    if (direct) {
        class_replaceMethod(gFloatingItemClass, selector,
                            (IMP)GCFloatingItemLayoutSubviews, types);
    } else if (!class_addMethod(gFloatingItemClass, selector,
                                (IMP)GCFloatingItemLayoutSubviews, types)) {
        if (failure) *failure = @"floating-item-layout-hook-install-failed";
        gOriginalLayoutSubviews = NULL;
        return NO;
    }

    Method installed = class_getInstanceMethod(gFloatingItemClass, selector);
    if (!installed || method_getImplementation(installed) != (IMP)GCFloatingItemLayoutSubviews) {
        if (failure) *failure = @"floating-item-layout-hook-verification-failed";
        gOriginalLayoutSubviews = NULL;
        return NO;
    }

    GCLog(@"lifecycle hook installed class=%@ mode=%@ original=%p image=%@",
          kFloatingItemName, direct ? @"replace" : @"override", original,
          GCImageForAddress((const void *)original));
    return YES;
}

static BOOL GCConfigure(NSString **failure) {
    if (gCompatEnabled) return YES;

    NSString *glowPath = GCLoadedGlowImagePath();
    if (!glowPath) {
        if (failure) *failure = @"Glow.dylib-not-loaded";
        return NO;
    }

    Class legacyClass = NSClassFromString(kLegacyItemName);
    if (!legacyClass) {
        if (failure) *failure = @"FBTabBarItemDefaultView-not-found";
        return NO;
    }
    Class floatingClass = NSClassFromString(kFloatingItemName);
    if (!floatingClass) {
        if (failure) *failure = @"FBFloatingTabBarItemView-not-found";
        return NO;
    }

    SEL selector = sel_registerName("contextMenuInteraction:configurationForMenuAtLocation:");
    Method resolvedMethod = class_getInstanceMethod(legacyClass, selector);
    if (!resolvedMethod) {
        if (failure) *failure = @"Glow-context-menu-method-not-found";
        return NO;
    }
    Method directMethod = GCDirectMethod(legacyClass, selector);
    if (!directMethod) {
        if (failure) *failure = @"Glow-context-menu-method-not-direct-on-legacy-class";
        return NO;
    }

    IMP implementation = method_getImplementation(directMethod);
    NSString *implementationImage = GCImageForAddress((const void *)implementation);
    if (!implementation || !GCIsGlowImagePath(implementationImage)) {
        if (failure) *failure = @"legacy-context-menu-IMP-not-in-Glow.dylib";
        return NO;
    }
    if (!GCContextMenuSignatureIsCompatible(directMethod)) {
        if (failure) *failure = @"legacy-context-menu-signature-incompatible";
        return NO;
    }

    gContextMenuSelector = selector;
    gFloatingItemClass = floatingClass;
    gLegacyContextMenuIMP = (GlowLegacyContextMenuIMP)implementation;
    gGlowImagePath = glowPath;
    GCLog(@"Glow detected image=%@", gGlowImagePath);
    GCLog(@"legacy context IMP validated imp=%p encoding=%s image=%@",
          implementation, method_getTypeEncoding(directMethod), implementationImage);

    if (!GCInstallFloatingItemLayoutHook(failure)) return NO;
    gCompatEnabled = YES;
    gLastReadinessReason = nil;
    GCLog(@"floating item class ready class=%@", kFloatingItemName);
    return YES;
}

static BOOL GCVisibleInWindow(UIView *view, UIWindow *window) {
    if (!view || !window || view.window != window || view.hidden || view.alpha <= 0.01) return NO;
    CGRect rect = [view convertRect:view.bounds toView:window];
    return CGRectIntersectsRect(rect, window.bounds);
}

static UIView *GCFindFloatingBar(UIView *view, UIWindow *window,
                                 NSUInteger depth, NSUInteger *visited) {
    if (!view || depth > 16 || *visited >= 400 || !GCVisibleInWindow(view, window)) return nil;
    (*visited)++;
    if (object_getClass(view) == NSClassFromString(kFloatingBarName)) return view;
    for (UIView *child in view.subviews) {
        UIView *match = GCFindFloatingBar(child, window, depth + 1, visited);
        if (match) return match;
    }
    return nil;
}

static void GCCollectFloatingItems(UIView *view, UIWindow *window,
                                  NSUInteger depth, NSUInteger *visited) {
    if (!view || depth > 10 || *visited >= 160 || !GCVisibleInWindow(view, window)) return;
    (*visited)++;
    if (object_getClass(view) == gFloatingItemClass) {
        GCEnsureContextMenuAttached(view);
        return;
    }
    for (UIView *child in view.subviews) {
        GCCollectFloatingItems(child, window, depth + 1, visited);
    }
}

static UIWindow *GCActiveWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || window.alpha <= 0.01 || !window.rootViewController) continue;
            if (window.isKeyWindow) return window;
            if (!fallback || (window.windowLevel == UIWindowLevelNormal &&
                              fallback.windowLevel != UIWindowLevelNormal)) fallback = window;
        }
    }
    return fallback;
}

static void GCDiscoverExistingItems(void) {
    if (!gCompatEnabled || !NSThread.isMainThread ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    UIWindow *window = GCActiveWindow();
    UIViewController *rootController = window.rootViewController;
    UIView *rootView = rootController.isViewLoaded ? rootController.viewIfLoaded : nil;
    if (!rootView) return;

    NSUInteger visited = 0;
    UIView *bar = GCFindFloatingBar(rootView, window, 0, &visited);
    if (!bar) return;
    NSUInteger itemNodes = 0;
    GCCollectFloatingItems(bar, window, 0, &itemNodes);
}

static void GCFloatingItemLayoutSubviews(id self, SEL selector) {
    IMP original = gOriginalLayoutSubviews;
    if (original) ((void (*)(id, SEL))original)(self, selector);
    if (gCompatEnabled && object_getClass(self) == gFloatingItemClass) {
        GCEnsureContextMenuAttached((UIView *)self);
    }
}

static void GCEnsureContextMenuAttached(UIView *item) {
    if (!gCompatEnabled || !item || object_getClass(item) != gFloatingItemClass) return;
    if (!NSThread.isMainThread) {
        __weak UIView *weakItem = item;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIView *strongItem = weakItem;
            if (strongItem) GCEnsureContextMenuAttached(strongItem);
        });
        return;
    }

    UIContextMenuInteraction *ownedInteraction =
        objc_getAssociatedObject(item, &kInteractionAssociation);
    BOOL ownedAttached = NO;
    BOOL unrelatedContextInteraction = NO;
    for (id interaction in item.interactions) {
        if (![interaction isKindOfClass:UIContextMenuInteraction.class]) continue;
        if (interaction == ownedInteraction) ownedAttached = YES;
        else unrelatedContextInteraction = YES;
    }
    if (ownedAttached) return;
    if (unrelatedContextInteraction) {
        if (!objc_getAssociatedObject(item, &kSkipLogAssociation)) {
            objc_setAssociatedObject(item, &kSkipLogAssociation, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            GCLog(@"skipped %@ reason=existing-context-interaction",
                  GCItemDescription(item));
        }
        return;
    }

    GlowFloatingTabContextMenuDelegate *delegate =
        objc_getAssociatedObject(item, &kDelegateAssociation);
    if (!delegate) {
        delegate = [GlowFloatingTabContextMenuDelegate new];
        delegate.item = item;
        objc_setAssociatedObject(item, &kDelegateAssociation, delegate,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIContextMenuInteraction *interaction = ownedInteraction;
    if (!interaction) {
        interaction = [[UIContextMenuInteraction alloc] initWithDelegate:delegate];
        if (!interaction) {
            GCLog(@"skipped %@ reason=context-interaction-init-failed", GCItemDescription(item));
            return;
        }
        objc_setAssociatedObject(item, &kInteractionAssociation, interaction,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    [item addInteraction:interaction];
    BOOL attached = [item.interactions containsObject:interaction];
    if (attached) {
        GCLog(@"attached itemClass=%@#%p %@ interaction=%p delegate=%@#%p",
              GCObjectClassName(item), item, GCItemDescription(item), interaction,
              GCObjectClassName(delegate), delegate);
    } else {
        GCLog(@"attach failed %@ interaction=%p", GCItemDescription(item), interaction);
    }
}

@implementation GlowFloatingTabContextMenuDelegate

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                               configurationForMenuAtLocation:(CGPoint)location {
    UIView *item = self.item;
    if (!item || object_getClass(item) != gFloatingItemClass || !gLegacyContextMenuIMP) {
        GCLog(@"context request skipped reason=invalid-item-or-IMP");
        return nil;
    }
    if (objc_getAssociatedObject(item, &kInteractionAssociation) != interaction) {
        GCLog(@"context request skipped %@ reason=interaction-mismatch", GCItemDescription(item));
        return nil;
    }

    GCLog(@"context requested %@", GCItemDescription(item));
    UIContextMenuConfiguration *configuration = nil;
    @try {
        configuration = gLegacyContextMenuIMP(item, gContextMenuSelector, interaction, location);
    } @catch (NSException *exception) {
        GCLog(@"exception %@ name=%@ reason=%@", GCItemDescription(item),
              GCSafeString(exception.name), GCSafeString(exception.reason));
        return nil;
    }

    if (configuration) {
        GCLog(@"Glow configuration returned class=%@ %@",
              GCObjectClassName(configuration), GCItemDescription(item));
    } else {
        GCLog(@"Glow configuration returned nil %@", GCItemDescription(item));
    }
    return configuration;
}

@end

static void GCAttemptSetup(NSUInteger generation, NSUInteger attempt) {
    if (generation != gSetupGeneration ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;

    if (!gCompatEnabled) {
        NSString *failure = nil;
        if (!GCConfigure(&failure)) {
            if (![gLastReadinessReason isEqualToString:failure]) {
                gLastReadinessReason = failure;
                GCLog(@"waiting reason=%@", failure ?: @"unknown");
            }
            if (attempt == 6) GCLog(@"disabled reason=%@", failure ?: @"unknown");
            return;
        }
    }
    GCDiscoverExistingItems();
}

static void GCScheduleSetup(void) {
    if (!GCIsFacebookProcess()) return;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ GCScheduleSetup(); });
        return;
    }
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;

    CFTimeInterval now = CACurrentMediaTime();
    if (gLastSetupStart > 0 && now - gLastSetupStart < 0.75) return;
    gLastSetupStart = now;
    NSUInteger generation = ++gSetupGeneration;
    NSArray<NSNumber *> *delays = @[@0.0, @0.5, @1.5, @3.0, @6.0, @10.0];
    for (NSUInteger index = 0; index < delays.count; index++) {
        NSUInteger attempt = index + 1;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delays[index].doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            GCAttemptSetup(generation, attempt);
        });
    }
}

__attribute__((constructor))
static void GCInitialize(void) {
#if GLOWCOMPAT_DISABLE_STARTUP
    static const char enterMarker[] = "[GlowCompatEarly] ctor-enter\n";
    static const char exitMarker[] = "[GlowCompatEarly] ctor-exit\n";
    (void)write(STDERR_FILENO, enterMarker, sizeof(enterMarker) - 1);
    (void)write(STDERR_FILENO, exitMarker, sizeof(exitMarker) - 1);
    return;
#else
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!GCIsFacebookProcess()) return;
            GCLog(@"loaded bundle=%@", NSBundle.mainBundle.bundleIdentifier ?: @"-");
            NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
            [center addObserverForName:UIApplicationDidBecomeActiveNotification
                                object:nil queue:NSOperationQueue.mainQueue
                            usingBlock:^(NSNotification *note) { GCScheduleSetup(); }];
            [center addObserverForName:UIWindowDidBecomeKeyNotification
                                object:nil queue:NSOperationQueue.mainQueue
                            usingBlock:^(NSNotification *note) { GCScheduleSetup(); }];
            GCScheduleSetup();
        });
    }
#endif
}
