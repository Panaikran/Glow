#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <os/log.h>
#import <stdarg.h>
#import <stdlib.h>
#import <string.h>

static NSString * const kGNDLegacyBarClass = @"FBTabBar";
static NSString * const kGNDFloatingBarClass = @"FBFloatingTabBar";
static NSString * const kGNDTabControllerClass = @"FBTabBarViewController";
static NSString * const kGNDLegacyItemClass = @"FBTabBarItemDefaultView";
static NSString * const kGNDFloatingItemClass = @"FBFloatingTabBar.FBFloatingTabBarItemView";
static NSString * const kGNDAncestorSelectorName = @"_viewControllerForAncestor";

static const NSUInteger kGNDMaxControllerNodes = 160;
static const NSUInteger kGNDMaxNavbarViewNodes = 160;
static const NSUInteger kGNDMaxItemNodes = 160;
static const NSUInteger kGNDDiscoveryAttempts = 5;

static NSUInteger gNDDiscoveryGeneration = 0;
static CFTimeInterval gNDLastDiscoveryTrigger = 0;
static BOOL gNDProbeCompletedThisActivation = NO;
static NSMutableSet<NSString *> *gNDLoggedSelectorClasses;
static NSHashTable<UIView *> *gNDProbedItems;

static void GNDStartNavbarDiscovery(void);

static void GNDLogTagged(NSString *tag, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "%{public}@",
                     [NSString stringWithFormat:@"[GlowNavDiag][%@] %@", tag, message]);
}

static NSString *GNDClassName(Class cls) {
    return cls ? NSStringFromClass(cls) : @"-";
}

static NSString *GNDObjectClassName(id object) {
    return object ? GNDClassName(object_getClass(object)) : @"-";
}

static NSString *GNDString(id value) {
    if (![value isKindOfClass:NSString.class]) return @"-";
    NSString *string = [(NSString *)value stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (string.length <= 120) return string;
    return [[string substringToIndex:117] stringByAppendingString:@"..."];
}

static NSString *GNDImageForAddress(const void *address) {
    Dl_info info = {0};
    if (!address || dladdr(address, &info) == 0 || !info.dli_fname) return @"-";
    return [NSString stringWithUTF8String:info.dli_fname];
}

static BOOL GNDClassHasName(Class cls, NSString *name) {
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        if ([GNDClassName(current) isEqualToString:name]) return YES;
    }
    return NO;
}

static Method GNDDirectMethod(Class cls, SEL selector) {
    if (!cls) return NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            found = methods[index];
            break;
        }
    }
    free(methods);
    return found;
}

static Class GNDMethodOwner(Class cls, SEL selector) {
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        if (GNDDirectMethod(current, selector)) return current;
    }
    return Nil;
}

static BOOL GNDMethodIsNoArgumentObjectGetter(Method method) {
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!encoding) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:encoding];
    if (!signature || signature.numberOfArguments != 2) return NO;
    const char *returnType = signature.methodReturnType;
    while (returnType && strchr("rnNoORV", returnType[0])) returnType++;
    return returnType && returnType[0] == '@';
}

static void GNDLogAncestorSelectorMetadata(BOOL includeMissingClasses) {
    static NSArray<NSString *> *classNames;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        classNames = @[
            kGNDFloatingItemClass, @"METANoCodingView", @"UIView", @"UIResponder",
            @"NSObject", kGNDLegacyItemClass
        ];
    });

    SEL selector = sel_registerName(kGNDAncestorSelectorName.UTF8String);
    for (NSString *name in classNames) {
        Class cls = NSClassFromString(name);
        if (!cls && !includeMissingClasses) continue;

        NSString *key = cls
            ? [NSString stringWithFormat:@"%@:%p", name, cls]
            : [NSString stringWithFormat:@"%@:<missing>", name];
        if ([gNDLoggedSelectorClasses containsObject:key]) continue;
        [gNDLoggedSelectorClasses addObject:key];

        Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
        Class owner = method ? GNDMethodOwner(cls, selector) : Nil;
        IMP imp = method ? method_getImplementation(method) : NULL;
        NSString *encoding = method && method_getTypeEncoding(method)
            ? [NSString stringWithUTF8String:method_getTypeEncoding(method)] : @"-";
        GNDLogTagged(@"ANCESTOR-SELECTOR",
                     @"class=%@ classLoaded=%@ instancesRespondToSelector=%@ methodFound=%@ owner=%@ encoding=%@ imp=%p image=%@ safeGetterSignature=%@",
                     name, cls ? @"YES" : @"NO",
                     cls && class_respondsToSelector(cls, selector) ? @"YES" : @"NO",
                     method ? @"YES" : @"NO", GNDClassName(owner), encoding, imp,
                     GNDImageForAddress((const void *)imp),
                     GNDMethodIsNoArgumentObjectGetter(method) ? @"YES" : @"NO");
    }
}

static BOOL GNDIsFacebookProcess(void) {
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *bundleID = bundle.bundleIdentifier ?: @"";
    NSString *executable = bundle.infoDictionary[@"CFBundleExecutable"] ?: @"";
    return [bundleID isEqualToString:@"com.facebook.Facebook"] ||
        [executable isEqualToString:@"Facebook"];
}

static UIWindow *GNDActiveWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window || window.hidden || window.alpha <= 0.01 || !window.rootViewController) continue;
            if (window.isKeyWindow) return window;
            if (!fallback || (window.windowLevel == UIWindowLevelNormal &&
                              fallback.windowLevel != UIWindowLevelNormal)) fallback = window;
        }
    }
    return fallback;
}

static UIViewController *GNDFindTabController(UIViewController *controller,
                                               NSUInteger depth,
                                               NSUInteger *visited) {
    if (!controller || depth > 16 || *visited >= kGNDMaxControllerNodes) return nil;
    (*visited)++;
    if (GNDClassHasName(controller.class, kGNDTabControllerClass)) return controller;
    for (UIViewController *child in controller.childViewControllers) {
        UIViewController *match = GNDFindTabController(child, depth + 1, visited);
        if (match) return match;
    }
    return GNDFindTabController(controller.presentedViewController, depth + 1, visited);
}

static BOOL GNDViewVisibleInWindow(UIView *view, UIWindow *window) {
    if (!view || !window || view.window != window) return NO;
    for (UIView *current = view; current; current = current.superview) {
        if (current.hidden || current.alpha <= 0.01) return NO;
        if (current == window) break;
    }
    CGRect frame = [view convertRect:view.bounds toView:window];
    return CGRectIntersectsRect(frame, window.bounds);
}

static NSString *GNDNavbarMode(Class cls) {
    if (GNDClassHasName(cls, kGNDLegacyBarClass)) return @"legacy";
    if (GNDClassHasName(cls, kGNDFloatingBarClass)) return @"floating";
    return @"unknown";
}

static UIView *GNDFindNavbarView(UIView *view, UIWindow *window,
                                  NSUInteger depth, NSUInteger *visited) {
    if (!view || depth > 12 || *visited >= kGNDMaxNavbarViewNodes) return nil;
    (*visited)++;
    if (!GNDViewVisibleInWindow(view, window)) return nil;
    if (![GNDNavbarMode(view.class) isEqualToString:@"unknown"]) return view;
    for (UIView *child in view.subviews) {
        UIView *match = GNDFindNavbarView(child, window, depth + 1, visited);
        if (match) return match;
    }
    return nil;
}

static UIView *GNDCurrentNavbar(UIWindow **windowOut) {
    UIWindow *window = GNDActiveWindow();
    if (!window) return nil;
    NSUInteger visitedControllers = 0;
    UIViewController *controller = GNDFindTabController(window.rootViewController, 0,
                                                        &visitedControllers);
    UIView *bar = nil;
    if (controller.isViewLoaded) {
        NSUInteger visitedViews = 0;
        bar = GNDFindNavbarView(controller.viewIfLoaded, window, 0, &visitedViews);
    }
    if (windowOut) *windowOut = window;
    return bar;
}

static NSString *GNDAccessibilityLabel(UIView *view) {
    return [view respondsToSelector:@selector(accessibilityLabel)]
        ? GNDString(view.accessibilityLabel) : @"-";
}

static NSString *GNDAccessibilityIdentifier(UIView *view) {
    return [view respondsToSelector:@selector(accessibilityIdentifier)]
        ? GNDString(view.accessibilityIdentifier) : @"-";
}

static BOOL GNDIsTabItem(UIView *view) {
    return GNDClassHasName(view.class, kGNDFloatingItemClass) ||
        GNDClassHasName(view.class, kGNDLegacyItemClass);
}

static void GNDCollectTabItems(UIView *view, UIView *bar, UIWindow *window,
                               NSUInteger depth, NSUInteger *visited,
                               NSMutableArray<UIView *> *items,
                               NSMutableSet<NSValue *> *seen) {
    if (!view || depth > 10 || *visited >= kGNDMaxItemNodes) return;
    (*visited)++;
    if (view != bar && !GNDViewVisibleInWindow(view, window)) return;
    if (view != bar && GNDIsTabItem(view) && GNDViewVisibleInWindow(view, window)) {
        NSValue *key = [NSValue valueWithPointer:(__bridge const void *)view];
        if (![seen containsObject:key]) {
            [seen addObject:key];
            [items addObject:view];
        }
    }
    for (UIView *child in view.subviews) {
        GNDCollectTabItems(child, bar, window, depth + 1, visited, items, seen);
    }
}

static NSArray<UIView *> *GNDVisibleTabItems(UIView *bar, UIWindow *window) {
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    NSUInteger visited = 0;
    GNDCollectTabItems(bar, bar, window, 0, &visited, items, seen);
    return [items sortedArrayUsingComparator:^NSComparisonResult(UIView *left, UIView *right) {
        CGFloat leftX = [left convertRect:left.bounds toView:window].origin.x;
        CGFloat rightX = [right convertRect:right.bounds toView:window].origin.x;
        if (leftX < rightX) return NSOrderedAscending;
        if (leftX > rightX) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

static BOOL GNDItemsFinishedLayout(NSArray<UIView *> *items, UIWindow *window) {
    if (!items.count) return NO;
    for (UIView *item in items) {
        if (item.window != window || CGRectIsEmpty(item.bounds) || CGRectIsEmpty(item.frame)) return NO;
    }
    return YES;
}

static NSString *GNDControllerViewWindowState(UIViewController *controller) {
    if (!controller.isViewLoaded) return @"not-loaded";
    return controller.viewIfLoaded.window ? @"YES" : @"NO";
}

static void GNDProbeAncestorForItem(UIView *item) {
    if ([gNDProbedItems containsObject:item]) return;
    [gNDProbedItems addObject:item];

    SEL selector = sel_registerName(kGNDAncestorSelectorName.UTF8String);
    BOOL responds = [item respondsToSelector:selector];
    Method method = class_getInstanceMethod(object_getClass(item), selector);
    BOOL safeSignature = GNDMethodIsNoArgumentObjectGetter(method);
    NSString *tab = GNDAccessibilityLabel(item);
    NSString *identifier = GNDAccessibilityIdentifier(item);
    NSString *frame = NSStringFromCGRect(item.frame);
    NSString *window = item.window ? @"YES" : @"NO";
    NSString *itemName = [NSString stringWithFormat:@"%@#%p", GNDObjectClassName(item), item];

    if (!responds || !method || !safeSignature) {
        GNDLogTagged(@"ANCESTOR-RESULT",
                     @"tab=%@ id=%@ item=%@ frame=%@ window=%@ responds=%@ safeGetterSignature=%@ invocation=SKIPPED",
                     tab, identifier, itemName, frame, window,
                     responds ? @"YES" : @"NO", safeSignature ? @"YES" : @"NO");
        return;
    }

    id result = nil;
    NSString *exception = nil;
    @try {
        result = ((id (*)(id, SEL))objc_msgSend)(item, selector);
    } @catch (NSException *caught) {
        exception = caught.name ?: @"NSException";
    }

    BOOL isViewController = [result isKindOfClass:UIViewController.class];
    NSString *viewInWindow = isViewController
        ? GNDControllerViewWindowState((UIViewController *)result) : @"-";
    NSString *resultName = result
        ? [NSString stringWithFormat:@"%@#%p", GNDObjectClassName(result), result] : @"nil";
    GNDLogTagged(@"ANCESTOR-RESULT",
                 @"tab=%@ id=%@ item=%@ frame=%@ window=%@ responds=YES result=%@ isViewController=%@ viewInWindow=%@ exception=%@",
                 tab, identifier, itemName, frame, window, resultName,
                 isViewController ? @"YES" : @"NO", viewInWindow,
                 exception ?: @"-");
}

static void GNDTryNavbarDiscovery(NSUInteger generation, NSUInteger attempt) {
    if (generation != gNDDiscoveryGeneration || gNDProbeCompletedThisActivation ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;

    GNDLogAncestorSelectorMetadata(NO);
    UIWindow *window = nil;
    UIView *bar = GNDCurrentNavbar(&window);
    if (bar && window) {
        NSString *mode = GNDNavbarMode(bar.class);
        NSArray<UIView *> *items = GNDVisibleTabItems(bar, window);
        if (([mode isEqualToString:@"floating"] || [mode isEqualToString:@"legacy"]) &&
            GNDItemsFinishedLayout(items, window)) {
            GNDLogAncestorSelectorMetadata(YES);
            for (UIView *item in items) GNDProbeAncestorForItem(item);
            gNDProbeCompletedThisActivation = YES;
            return;
        }
    }

    if (attempt >= kGNDDiscoveryAttempts) {
        GNDLogAncestorSelectorMetadata(YES);
        GNDLogTagged(@"ANCESTOR-RESULT", @"status=navbar-items-not-laid-out mode=%@",
                     bar ? GNDNavbarMode(bar.class) : @"unknown");
        gNDProbeCompletedThisActivation = YES;
    }
}

static void GNDStartNavbarDiscovery(void) {
    CFTimeInterval now = CACurrentMediaTime();
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        gNDProbeCompletedThisActivation) return;
    if (gNDLastDiscoveryTrigger > 0 && now - gNDLastDiscoveryTrigger < 0.75) return;
    gNDLastDiscoveryTrigger = now;
    NSUInteger generation = ++gNDDiscoveryGeneration;
    NSArray<NSNumber *> *delays = @[@0.0, @0.5, @1.5, @3.0, @5.0];
    for (NSUInteger index = 0; index < delays.count; index++) {
        NSUInteger attempt = index + 1;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delays[index].doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            GNDTryNavbarDiscovery(generation, attempt);
        });
    }
}

__attribute__((constructor))
static void GNDInitialize(void) {
    @autoreleasepool {
        if (!GNDIsFacebookProcess()) return;
        gNDLoggedSelectorClasses = [NSMutableSet set];
        gNDProbedItems = [NSHashTable weakObjectsHashTable];
        GNDLogTagged(@"ANCESTOR-RESULT", @"probe=loaded bundle=%@ iOS=%@",
                     NSBundle.mainBundle.bundleIdentifier ?: @"-",
                     UIDevice.currentDevice.systemVersion);
        GNDLogAncestorSelectorMetadata(NO);

        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *note) {
            gNDProbeCompletedThisActivation = NO;
            GNDStartNavbarDiscovery();
        }];
        [center addObserverForName:UIWindowDidBecomeKeyNotification
                            object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *note) {
            GNDStartNavbarDiscovery();
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            GNDStartNavbarDiscovery();
        });
    }
}
