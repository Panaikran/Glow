#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <os/log.h>
#import <stdarg.h>
#import <stdlib.h>
#import <stdint.h>
#import <string.h>

static NSString * const kGNDLegacyBarClass = @"FBTabBar";
static NSString * const kGNDFloatingBarClass = @"FBFloatingTabBar";
static NSString * const kGNDTabControllerClass = @"FBTabBarViewController";
static NSString * const kGNDLegacyItemClass = @"FBTabBarItemDefaultView";
static NSString * const kGNDFloatingItemClass = @"FBFloatingTabBar.FBFloatingTabBarItemView";
static NSString * const kGNDLegacyContextSelector = @"contextMenuInteraction:configurationForMenuAtLocation:";

static const NSUInteger kGNDMaxControllerNodes = 160;
static const NSUInteger kGNDMaxNavbarViewNodes = 160;
static const NSUInteger kGNDMaxItemNodes = 160;

static IMP gNDOriginalContextMenuInit = NULL;
static IMP gNDOriginalAddInteraction = NULL;
static NSString *gNDGlowImagePath;
static NSString *gNDLastLegacyIMPState;
static BOOL gNDLoggedGlowNotLoaded = NO;
static BOOL gNDNavbarLoggedThisActivation = NO;
static NSUInteger gNDDiscoveryGeneration = 0;
static CFTimeInterval gNDLastDiscoveryTrigger = 0;
static UIView *gNDActiveBar;
static UIViewController *gNDActiveController;
static NSHashTable<UIView *> *gNDLoggedItems;
static NSMutableDictionary<NSString *, NSString *> *gNDInteractionSnapshots;
static NSMutableDictionary<NSString *, NSString *> *gNDProtocolStates;
static NSMutableSet<NSString *> *gNDLoggedMethodEntries;
static NSMutableSet<NSString *> *gNDLoggedPatchEntries;
static NSMutableSet<NSString *> *gNDLoggedIMPMaps;

static void GNDRefreshRuntimeMetadata(void);
static void GNDStartNavbarDiscovery(void);

static void GNDLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "%{public}@",
                     [@"[GlowNavDiag] " stringByAppendingString:message]);
}

static void GNDLogTagged(NSString *tag, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "%{public}@",
                     [NSString stringWithFormat:@"[GlowNavDiag][%@] %@", tag, message]);
}

static NSString *GNDString(id value) {
    if (![value isKindOfClass:NSString.class]) return @"-";
    NSString *string = [(NSString *)value stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (string.length <= 160) return string;
    return [[string substringToIndex:157] stringByAppendingString:@"..."];
}

static NSString *GNDClassName(Class cls) {
    return cls ? NSStringFromClass(cls) : @"-";
}

static NSString *GNDObjectClassName(id object) {
    return object ? GNDClassName(object_getClass(object)) : @"-";
}

static BOOL GNDClassHasName(Class cls, NSString *name) {
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        if ([GNDClassName(current) isEqualToString:name]) return YES;
    }
    return NO;
}

static BOOL GNDIsFacebookProcess(void) {
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *bundleID = bundle.bundleIdentifier ?: @"";
    NSString *executable = bundle.infoDictionary[@"CFBundleExecutable"] ?: @"";
    return [bundleID isEqualToString:@"com.facebook.Facebook"] ||
        [executable isEqualToString:@"Facebook"];
}

static NSString *GNDImageForAddress(const void *address, NSString **symbolOut) {
    Dl_info info = {0};
    if (symbolOut) *symbolOut = @"-";
    if (!address || dladdr(address, &info) == 0) return @"-";
    if (symbolOut && info.dli_sname) *symbolOut = [NSString stringWithUTF8String:info.dli_sname];
    return info.dli_fname ? [NSString stringWithUTF8String:info.dli_fname] : @"-";
}

static BOOL GNDIsGlowImage(NSString *image) {
    if (!image.length) return NO;
    if (gNDGlowImagePath.length) return [image isEqualToString:gNDGlowImagePath];
    return [image.lastPathComponent caseInsensitiveCompare:@"Glow.dylib"] == NSOrderedSame;
}

typedef struct {
    uint32_t imageIndex;
    const struct mach_header *header;
    intptr_t slide;
    uint64_t textVMAddr;
    uintptr_t runtimeTextBase;
} GNDLoadedImageLayout;

static BOOL GNDLoadedImageLayoutForAddress(const void *imageBase, NSString *imagePath,
                                           GNDLoadedImageLayout *layoutOut) {
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t index = 0; index < imageCount; index++) {
        const struct mach_header *header = _dyld_get_image_header(index);
        const char *pathBytes = _dyld_get_image_name(index);
        if (!header) continue;
        NSString *loadedPath = pathBytes ? [NSString stringWithUTF8String:pathBytes] : nil;
        BOOL pathMatches = imagePath.length && loadedPath.length &&
            [imagePath.stringByStandardizingPath isEqualToString:loadedPath.stringByStandardizingPath];
        if (header != imageBase && !pathMatches) continue;
        if (header->magic != MH_MAGIC_64) return NO;

        const struct mach_header_64 *header64 = (const struct mach_header_64 *)header;
        const uint8_t *cursor = (const uint8_t *)header64 + sizeof(*header64);
        const uint8_t *commandsEnd = cursor + header64->sizeofcmds;
        BOOL foundText = NO;
        uint64_t textVMAddr = 0;
        for (uint32_t commandIndex = 0; commandIndex < header64->ncmds; commandIndex++) {
            if (cursor + sizeof(struct load_command) > commandsEnd) break;
            const struct load_command *command = (const struct load_command *)cursor;
            if (command->cmdsize < sizeof(struct load_command) || cursor + command->cmdsize > commandsEnd) break;
            if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(struct segment_command_64)) {
                const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
                if (strncmp(segment->segname, SEG_TEXT, sizeof(segment->segname)) == 0) {
                    textVMAddr = segment->vmaddr;
                    foundText = YES;
                    break;
                }
            }
            cursor += command->cmdsize;
        }
        if (!foundText) return NO;

        intptr_t slide = _dyld_get_image_vmaddr_slide(index);
        if (layoutOut) {
            layoutOut->imageIndex = index;
            layoutOut->header = header;
            layoutOut->slide = slide;
            layoutOut->textVMAddr = textVMAddr;
            layoutOut->runtimeTextBase = (uintptr_t)((intptr_t)textVMAddr + slide);
        }
        return YES;
    }
    return NO;
}

static void GNDLogIMPMap(NSString *tag, NSString *className, NSString *selectorName, IMP imp) {
    if (!imp) return;
    Dl_info info = {0};
    if (dladdr((const void *)imp, &info) == 0 || !info.dli_fname || !info.dli_fbase) return;
    NSString *image = [NSString stringWithUTF8String:info.dli_fname];
    if (!GNDIsGlowImage(image)) return;

    NSString *key = [NSString stringWithFormat:@"%@:%@:%p:%@", className, selectorName, imp, image];
    if (!gNDLoggedIMPMaps) gNDLoggedIMPMaps = [NSMutableSet set];
    if ([gNDLoggedIMPMaps containsObject:key]) return;
    [gNDLoggedIMPMaps addObject:key];

    uintptr_t runtimeIMP = (uintptr_t)imp;
    uintptr_t imageBase = (uintptr_t)info.dli_fbase;
    NSString *imageOffset = runtimeIMP >= imageBase
        ? [NSString stringWithFormat:@"0x%llx", (unsigned long long)(runtimeIMP - imageBase)]
        : @"unavailable";
    GNDLoadedImageLayout layout = {0};
    BOOL hasLayout = GNDLoadedImageLayoutForAddress(info.dli_fbase, image, &layout);
    NSString *layoutFields = hasLayout
        ? [NSString stringWithFormat:@"imageIndex=%u header=%p slide=0x%llx textVMAddr=0x%llx runtimeTextBase=%p",
           layout.imageIndex, layout.header, (unsigned long long)(uint64_t)layout.slide,
           (unsigned long long)layout.textVMAddr, (void *)layout.runtimeTextBase]
        : @"imageIndex=unavailable header=unavailable slide=unavailable textVMAddr=unavailable runtimeTextBase=unavailable";
    GNDLogTagged(tag, @"class=%@ selector=%@ imp=%p imageBase=%p imageOffset=%@ %@ image=%@",
                 className, selectorName, imp, info.dli_fbase, imageOffset, layoutFields, image);
}

static BOOL GNDClassIsGlowOwned(Class cls) {
    const char *image = cls ? class_getImageName(cls) : NULL;
    return image && GNDIsGlowImage([NSString stringWithUTF8String:image]);
}

static NSString *GNDFindGlowImage(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const char *image = _dyld_get_image_name(index);
        if (!image) continue;
        NSString *path = [NSString stringWithUTF8String:image];
        if (GNDIsGlowImage(path)) return path;
    }
    return nil;
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

static NSString *GNDMethodEncoding(Method method) {
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    return encoding ? [NSString stringWithUTF8String:encoding] : @"-";
}

static Class GNDMethodOwner(Class cls, SEL selector, Method *methodOut) {
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        Method direct = GNDDirectMethod(current, selector);
        if (!direct) continue;
        if (methodOut) *methodOut = direct;
        return current;
    }
    if (methodOut) *methodOut = NULL;
    return Nil;
}

static BOOL GNDSelectorMatchesGlowFilter(NSString *selector) {
    static NSArray<NSString *> *keywords;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[@"settings", @"setting", @"sheet", @"present", @"menu", @"context",
                     @"action", @"configuration", @"config", @"long", @"press", @"open",
                     @"show", @"controller", @"view", @"init"];
    });
    NSString *lower = selector.lowercaseString;
    for (NSString *keyword in keywords) {
        if ([lower containsString:keyword]) return YES;
    }
    return NO;
}

static void GNDLogMethodList(Class cls, BOOL classMethods) {
    Class listOwner = classMethods ? object_getClass(cls) : cls;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(listOwner, &count);
    for (unsigned int index = 0; index < count; index++) {
        Method method = methods[index];
        NSString *selector = NSStringFromSelector(method_getName(method));
        if (!GNDSelectorMatchesGlowFilter(selector)) continue;
        IMP imp = method_getImplementation(method);
        NSString *symbol = nil;
        NSString *image = GNDImageForAddress((const void *)imp, &symbol);
        NSString *entry = [NSString stringWithFormat:@"%@:%@:%p:%p", GNDClassName(cls),
                           classMethods ? @"class" : @"instance", method, imp];
        if (![gNDLoggedMethodEntries containsObject:entry]) {
            [gNDLoggedMethodEntries addObject:entry];
            const char *classImage = class_getImageName(cls);
            GNDLogTagged(@"GLOW-METHOD", @"class=%@ classImage=%@ kind=%@ selector=%@ encoding=%@ imp=%p image=%@ dladdrSymbolHint=%@",
                         GNDClassName(cls), classImage ? [NSString stringWithUTF8String:classImage] : @"-",
                         classMethods ? @"class" : @"instance", selector,
                         GNDMethodEncoding(method), imp, image, symbol ?: @"-");
        }
    }
    free(methods);
}

static void GNDInspectNamedGlowClass(NSString *name) {
    Class cls = NSClassFromString(name);
    if (!cls) return;
    GNDLogMethodList(cls, NO);
    GNDLogMethodList(cls, YES);
}

static void GNDLogGlowPatchesForClass(NSString *name) {
    Class cls = NSClassFromString(name);
    if (!cls) return;
    for (NSUInteger kind = 0; kind < 2; kind++) {
        BOOL classMethods = kind == 1;
        Class owner = classMethods ? object_getClass(cls) : cls;
        unsigned int count = 0;
        Method *methods = class_copyMethodList(owner, &count);
        for (unsigned int index = 0; index < count; index++) {
            Method method = methods[index];
            IMP imp = method_getImplementation(method);
            NSString *symbol = nil;
            NSString *image = GNDImageForAddress((const void *)imp, &symbol);
            if (!GNDIsGlowImage(image)) continue;
            NSString *selector = NSStringFromSelector(method_getName(method));
            NSString *entry = [NSString stringWithFormat:@"%@:%@:%p:%p", name,
                               classMethods ? @"class" : @"instance", method, imp];
            if ([gNDLoggedPatchEntries containsObject:entry]) continue;
            [gNDLoggedPatchEntries addObject:entry];
            GNDLogTagged(@"GLOW-PATCH", @"class=%@ kind=%@ selector=%@ encoding=%@ imp=%p image=%@ dladdrSymbolHint=%@",
                         name, classMethods ? @"class" : @"instance", selector,
                         GNDMethodEncoding(method), imp, image, symbol ?: @"-");
        }
        free(methods);
    }
}

static void GNDLogProtocolStatus(NSString *name) {
    Class cls = NSClassFromString(name);
    NSString *status = cls
        ? (class_conformsToProtocol(cls, @protocol(UIContextMenuInteractionDelegate)) ? @"YES" : @"NO")
        : @"UNKNOWN";
    if (!gNDProtocolStates) gNDProtocolStates = [NSMutableDictionary dictionary];
    if ([gNDProtocolStates[name] isEqualToString:status]) return;
    gNDProtocolStates[name] = status;
    GNDLogTagged(@"PROTOCOL", @"class=%@ UIContextMenuInteractionDelegate=%@", name, status);
}

static void GNDInspectLegacyContextIMP(void) {
    Class cls = NSClassFromString(kGNDLegacyItemClass);
    SEL selector = sel_registerName(kGNDLegacyContextSelector.UTF8String);
    Method resolvedMethod = cls ? class_getInstanceMethod(cls, selector) : NULL;
    Method directMethod = NULL;
    Class owner = resolvedMethod ? GNDMethodOwner(cls, selector, &directMethod) : Nil;
    IMP imp = resolvedMethod ? method_getImplementation(resolvedMethod) : NULL;
    NSString *symbol = nil;
    NSString *image = GNDImageForAddress((const void *)imp, &symbol);
    BOOL responds = cls && class_respondsToSelector(cls, selector);
    NSString *state = [NSString stringWithFormat:@"responds=%@ owner=%@ direct=%@ imp=%p encoding=%@ image=%@ dladdrSymbolHint=%@ inGlow=%@",
                       responds ? @"YES" : @"NO", GNDClassName(owner),
                       directMethod && owner == cls ? @"YES" : @"NO", imp,
                       GNDMethodEncoding(resolvedMethod), image, symbol ?: @"-",
                       GNDIsGlowImage(image) ? @"YES" : @"NO"];
    if ([gNDLastLegacyIMPState isEqualToString:state]) return;
    gNDLastLegacyIMPState = state;
    GNDLogTagged(@"LEGACY-IMP", @"class=%@ selector=%@ %@", kGNDLegacyItemClass,
                 kGNDLegacyContextSelector, state);
    GNDLogIMPMap(@"LEGACY-IMP-MAP", kGNDLegacyItemClass, kGNDLegacyContextSelector, imp);
}

static void GNDLogDirectGlowIMPMap(NSString *className, SEL selector) {
    Class cls = NSClassFromString(className);
    Method method = cls ? GNDDirectMethod(cls, selector) : NULL;
    if (!method) return;
    GNDLogIMPMap(@"GLOW-IMP-MAP", className, NSStringFromSelector(selector),
                 method_getImplementation(method));
}

static void GNDLogConfirmedGlowIMPMaps(void) {
    GNDLogDirectGlowIMPMap(kGNDLegacyBarClass, @selector(layoutSubviews));
    GNDLogDirectGlowIMPMap(kGNDLegacyItemClass, @selector(layoutSubviews));
}

static void GNDRefreshRuntimeMetadata(void) {
    NSString *glowImage = GNDFindGlowImage();
    if (glowImage) {
        if (![gNDGlowImagePath isEqualToString:glowImage]) {
            gNDGlowImagePath = glowImage;
            GNDLogTagged(@"GLOW", @"image=%@", glowImage);
        }
    } else if (!gNDGlowImagePath && !gNDLoggedGlowNotLoaded) {
        gNDLoggedGlowNotLoaded = YES;
        GNDLogTagged(@"GLOW", @"image=not-loaded");
    }

    GNDInspectLegacyContextIMP();
    NSArray<NSString *> *protocolClasses = @[
        @"SettingsViewController", @"DVNSheetPresenter", @"DVNSheetController",
        @"DVNLongPressGestureRecognizer", @"WelcomeVC", @"GlowUserDefaults",
        kGNDLegacyItemClass
    ];
    for (NSString *name in protocolClasses) GNDLogProtocolStatus(name);
    GNDLogConfirmedGlowIMPMaps();

    NSArray<NSString *> *glowClasses = @[
        @"SettingsViewController", @"DVNSheetPresenter", @"DVNSheetController",
        @"DVNLongPressGestureRecognizer", @"WelcomeVC", @"GlowUserDefaults"
    ];
    for (NSString *name in glowClasses) GNDInspectNamedGlowClass(name);

    NSArray<NSString *> *patchedClasses = @[
        kGNDLegacyBarClass, kGNDTabControllerClass, kGNDLegacyItemClass
    ];
    for (NSString *name in patchedClasses) GNDLogGlowPatchesForClass(name);
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
    NSString *mode = GNDNavbarMode(view.class);
    if (![mode isEqualToString:@"unknown"]) return view;
    for (UIView *child in view.subviews) {
        UIView *match = GNDFindNavbarView(child, window, depth + 1, visited);
        if (match) return match;
    }
    return nil;
}

static UIView *GNDCurrentNavbar(UIWindow **windowOut, UIViewController **controllerOut) {
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
    if (controllerOut) *controllerOut = controller;
    return bar;
}

static NSString *GNDAccessibilityIdentifier(UIView *view) {
    return [view respondsToSelector:@selector(accessibilityIdentifier)]
        ? GNDString(view.accessibilityIdentifier) : @"-";
}

static NSString *GNDAccessibilityLabel(UIView *view) {
    return [view respondsToSelector:@selector(accessibilityLabel)]
        ? GNDString(view.accessibilityLabel) : @"-";
}

static BOOL GNDIsKnownTabItemClass(Class cls) {
    return GNDClassHasName(cls, kGNDLegacyItemClass) ||
        GNDClassHasName(cls, kGNDFloatingItemClass);
}

static void GNDAddUniqueView(UIView *view, NSMutableArray<UIView *> *views,
                             NSMutableSet<NSValue *> *seen) {
    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)view];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    [views addObject:view];
}

static void GNDCollectTabItems(UIView *view, UIView *bar, UIWindow *window,
                               NSUInteger depth, NSUInteger *visited,
                               NSMutableArray<UIView *> *knownItems,
                               NSMutableSet<NSValue *> *knownSeen,
                               NSMutableArray<UIView *> *identifiedItems,
                               NSMutableSet<NSValue *> *identifiedSeen) {
    if (!view || depth > 10 || *visited >= kGNDMaxItemNodes) return;
    (*visited)++;
    if (view != bar && !GNDViewVisibleInWindow(view, window)) return;
    if (GNDViewVisibleInWindow(view, window)) {
        if (GNDIsKnownTabItemClass(view.class)) GNDAddUniqueView(view, knownItems, knownSeen);
        else if ([GNDAccessibilityIdentifier(view) hasPrefix:@"tab-bar-item-"])
            GNDAddUniqueView(view, identifiedItems, identifiedSeen);
    }
    for (UIView *child in view.subviews) {
        GNDCollectTabItems(child, bar, window, depth + 1, visited,
                           knownItems, knownSeen, identifiedItems, identifiedSeen);
    }
}

static NSArray<UIView *> *GNDVisibleTabItems(UIView *bar, UIWindow *window) {
    NSMutableArray<UIView *> *knownItems = [NSMutableArray array];
    NSMutableArray<UIView *> *identifiedItems = [NSMutableArray array];
    NSMutableSet<NSValue *> *knownSeen = [NSMutableSet set];
    NSMutableSet<NSValue *> *identifiedSeen = [NSMutableSet set];
    NSUInteger visited = 0;
    GNDCollectTabItems(bar, bar, window, 0, &visited, knownItems, knownSeen,
                       identifiedItems, identifiedSeen);
    NSArray<UIView *> *items = knownItems.count ? knownItems : identifiedItems;
    return [items sortedArrayUsingComparator:^NSComparisonResult(UIView *left, UIView *right) {
        CGFloat leftX = [left convertRect:left.bounds toView:window].origin.x;
        CGFloat rightX = [right convertRect:right.bounds toView:window].origin.x;
        if (leftX < rightX) return NSOrderedAscending;
        if (leftX > rightX) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

static BOOL GNDIsContextMenuInteraction(id interaction) {
    return interaction && [interaction isKindOfClass:UIContextMenuInteraction.class];
}

static BOOL GNDIsNavbarReceiver(Class cls) {
    return GNDClassHasName(cls, kGNDLegacyItemClass) ||
        GNDClassHasName(cls, kGNDFloatingItemClass) ||
        GNDClassHasName(cls, kGNDLegacyBarClass) ||
        GNDClassHasName(cls, kGNDFloatingBarClass);
}

static BOOL GNDIsRelevantContextDelegate(id delegate) {
    Class cls = delegate ? object_getClass(delegate) : Nil;
    return GNDIsNavbarReceiver(cls) || GNDClassIsGlowOwned(cls);
}

static void GNDLogItemInteractions(UIView *item) {
    if (!item || ![item respondsToSelector:@selector(interactions)]) return;
    NSArray<id<UIInteraction>> *interactions = item.interactions ?: @[];
    NSString *tab = GNDAccessibilityLabel(item);
    if ([tab isEqualToString:@"-"]) tab = GNDAccessibilityIdentifier(item);
    NSString *identifier = GNDAccessibilityIdentifier(item);
    NSString *itemKey = [NSString stringWithFormat:@"%p:%@", item, identifier];
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:interactions.count];
    for (id<UIInteraction> interaction in interactions) {
        if (GNDIsContextMenuInteraction(interaction)) {
            UIContextMenuInteraction *context = (UIContextMenuInteraction *)interaction;
            id delegate = context.delegate;
            [parts addObject:[NSString stringWithFormat:@"%p:%@:%p", context,
                              GNDObjectClassName(delegate), delegate]];
        } else {
            [parts addObject:[NSString stringWithFormat:@"%p:%@", (__bridge void *)interaction,
                              GNDObjectClassName(interaction)]];
        }
    }
    NSString *snapshot = parts.count ? [parts componentsJoinedByString:@";"] : @"<empty>";
    if (!gNDInteractionSnapshots) gNDInteractionSnapshots = [NSMutableDictionary dictionary];
    if ([gNDInteractionSnapshots[itemKey] isEqualToString:snapshot]) return;
    gNDInteractionSnapshots[itemKey] = snapshot;
    GNDLogTagged(@"INTERACTION", @"tab=%@ itemClass=%@ item=%p id=%@ interactions=%lu",
                 tab, GNDObjectClassName(item), item, identifier, (unsigned long)interactions.count);
    for (id<UIInteraction> interaction in interactions) {
        if (GNDIsContextMenuInteraction(interaction)) {
            UIContextMenuInteraction *context = (UIContextMenuInteraction *)interaction;
            id delegate = context.delegate;
            GNDLogTagged(@"INTERACTION", @"tab=%@ itemClass=%@ interactionClass=%@ interaction=%p delegateClass=%@ delegate=%p",
                         tab, GNDObjectClassName(item), GNDObjectClassName(context), context,
                         GNDObjectClassName(delegate), delegate);
        } else {
            GNDLogTagged(@"INTERACTION", @"tab=%@ itemClass=%@ interactionClass=%@ interaction=%p",
                         tab, GNDObjectClassName(item), GNDObjectClassName(interaction),
                         (__bridge void *)interaction);
        }
    }
}

static void GNDInspectNavbarItems(UIView *bar, UIWindow *window) {
    NSArray<UIView *> *items = GNDVisibleTabItems(bar, window);
    if (!gNDLoggedItems) gNDLoggedItems = [NSHashTable weakObjectsHashTable];
    for (UIView *item in items) {
        if (![gNDLoggedItems containsObject:item]) {
            [gNDLoggedItems addObject:item];
            GNDLog(@"item class=%@ address=%p accessibilityIdentifier=%@ accessibilityLabel=%@ frame=%@",
                   GNDObjectClassName(item), item, GNDAccessibilityIdentifier(item),
                   GNDAccessibilityLabel(item), NSStringFromCGRect(item.frame));
        }
        GNDLogItemInteractions(item);
    }
}

static void GNDLogNavbarIfChanged(UIView *bar, UIViewController *controller,
                                  UIWindow *window) {
    if (!bar || !controller || !window) return;
    BOOL changed = gNDActiveBar != bar || gNDActiveController != controller ||
        !gNDNavbarLoggedThisActivation;
    if (changed) {
        gNDActiveBar = bar;
        gNDActiveController = controller;
        gNDNavbarLoggedThisActivation = YES;
        CGRect windowFrame = [bar convertRect:bar.bounds toView:window];
        GNDLog(@"navbar mode=%@ class=%@ bar=%p controller=%p frame=%@ windowFrame=%@",
               GNDNavbarMode(bar.class), GNDObjectClassName(bar), bar, controller,
               NSStringFromCGRect(bar.frame), NSStringFromCGRect(windowFrame));
    }
    GNDInspectNavbarItems(bar, window);
}

static void GNDTryNavbarDiscovery(NSUInteger generation, NSUInteger attempt) {
    if (generation != gNDDiscoveryGeneration ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    GNDRefreshRuntimeMetadata();
    UIWindow *window = nil;
    UIViewController *controller = nil;
    UIView *bar = GNDCurrentNavbar(&window, &controller);
    if (bar && controller && window) {
        GNDLogNavbarIfChanged(bar, controller, window);
        return;
    }
    if (attempt == 3) GNDLog(@"navbar mode=unknown class=- controller=%@ window=%@",
                             GNDObjectClassName(controller), window ? @"available" : @"unavailable");
}

static void GNDStartNavbarDiscovery(void) {
    CFTimeInterval now = CACurrentMediaTime();
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    if (gNDLastDiscoveryTrigger > 0 && now - gNDLastDiscoveryTrigger < 0.75) return;
    gNDLastDiscoveryTrigger = now;
    NSUInteger generation = ++gNDDiscoveryGeneration;
    NSArray<NSNumber *> *delays = @[@0.0, @0.5, @1.5];
    for (NSUInteger index = 0; index < delays.count; index++) {
        NSUInteger attempt = index + 1;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delays[index].doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            GNDTryNavbarDiscovery(generation, attempt);
        });
    }
}

static BOOL GNDIsRelevantCreationCaller(const void *caller, NSString **imageOut,
                                       NSString **symbolOut) {
    NSString *image = GNDImageForAddress(caller, symbolOut);
    if (imageOut) *imageOut = image;
    return GNDIsGlowImage(image);
}

typedef id (*GNDContextInitIMP)(id, SEL, id) __attribute__((ns_returns_retained));
static id GNDContextMenuInteractionInit(id self, SEL selector, id delegate)
    __attribute__((ns_returns_retained, noinline));

static id GNDContextMenuInteractionInit(id self, SEL selector, id delegate) {
    const void *caller = __builtin_return_address(0);
    IMP original = gNDOriginalContextMenuInit;
    id interaction = original ? ((GNDContextInitIMP)original)(self, selector, delegate) : nil;
    NSString *callerImage = nil;
    NSString *callerSymbol = nil;
    BOOL glowCaller = GNDIsRelevantCreationCaller(caller, &callerImage, &callerSymbol);
    if (glowCaller || GNDIsRelevantContextDelegate(delegate)) {
        GNDLogTagged(@"CTX-CREATE", @"interaction=%p delegateClass=%@ delegate=%p caller=%p callerImage=%@ callerSymbol=%@",
                     interaction, GNDObjectClassName(delegate), delegate, caller,
                     callerImage ?: @"-", callerSymbol ?: @"-");
    }
    return interaction;
}

static void GNDViewAddInteraction(id receiver, SEL selector, id interaction)
    __attribute__((noinline));

static void GNDViewAddInteraction(id receiver, SEL selector, id interaction) {
    const void *caller = __builtin_return_address(0);
    IMP original = gNDOriginalAddInteraction;
    if (original) ((void (*)(id, SEL, id))original)(receiver, selector, interaction);
    Class receiverClass = receiver ? object_getClass(receiver) : Nil;
    if (!GNDIsContextMenuInteraction(interaction) || !GNDIsNavbarReceiver(receiverClass)) return;
    NSString *callerImage = nil;
    NSString *callerSymbol = nil;
    callerImage = GNDImageForAddress(caller, &callerSymbol);
    UIContextMenuInteraction *context = interaction;
    id delegate = context.delegate;
    UIView *view = [receiver isKindOfClass:UIView.class] ? receiver : nil;
    NSString *tab = view ? GNDAccessibilityLabel(view) : @"-";
    if ([tab isEqualToString:@"-"] && view) tab = GNDAccessibilityIdentifier(view);
    GNDLogTagged(@"CTX-ATTACH", @"receiverClass=%@ receiver=%p tab=%@ id=%@ interaction=%p delegateClass=%@ delegate=%p caller=%p callerImage=%@ callerSymbol=%@",
                 GNDObjectClassName(receiver), receiver, tab,
                 view ? GNDAccessibilityIdentifier(view) : @"-", context,
                 GNDObjectClassName(delegate), delegate, caller,
                 callerImage ?: @"-", callerSymbol ?: @"-");
}

static BOOL GNDMethodMatchesSignature(Method method, NSUInteger expectedArguments,
                                     char expectedReturnType) {
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!encoding) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:encoding];
    if (!signature || signature.numberOfArguments != expectedArguments) return NO;
    const char *argumentType = [signature getArgumentTypeAtIndex:2];
    while (argumentType && strchr("rnNoORV", argumentType[0])) argumentType++;
    return signature.methodReturnType[0] == expectedReturnType &&
        argumentType && argumentType[0] == '@';
}

static void GNDInstallPassiveInteractionObservers(void) {
    Class interactionClass = UIContextMenuInteraction.class;
    SEL initSelector = @selector(initWithDelegate:);
    Method initMethod = GNDDirectMethod(interactionClass, initSelector);
    if (initMethod && GNDMethodMatchesSignature(initMethod, 3, '@')) {
        IMP current = method_getImplementation(initMethod);
        if (current != (IMP)GNDContextMenuInteractionInit) {
            gNDOriginalContextMenuInit = method_setImplementation(initMethod,
                                                                   (IMP)GNDContextMenuInteractionInit);
        }
        GNDLogTagged(@"CTX-CREATE", @"observer=%@", gNDOriginalContextMenuInit ? @"installed" : @"unavailable");
    } else {
        GNDLogTagged(@"CTX-CREATE", @"observer=unavailable");
    }

    SEL addSelector = @selector(addInteraction:);
    Method addMethod = GNDDirectMethod(UIView.class, addSelector);
    if (addMethod && GNDMethodMatchesSignature(addMethod, 3, 'v')) {
        IMP current = method_getImplementation(addMethod);
        if (current != (IMP)GNDViewAddInteraction) {
            gNDOriginalAddInteraction = method_setImplementation(addMethod,
                                                                  (IMP)GNDViewAddInteraction);
        }
        GNDLogTagged(@"CTX-ATTACH", @"observer=%@", gNDOriginalAddInteraction ? @"installed" : @"unavailable");
    } else {
        GNDLogTagged(@"CTX-ATTACH", @"observer=unavailable");
    }
}

__attribute__((constructor))
static void GNDInitialize(void) {
    @autoreleasepool {
        if (!GNDIsFacebookProcess()) return;
        gNDLoggedMethodEntries = [NSMutableSet set];
        gNDLoggedPatchEntries = [NSMutableSet set];
        gNDLoggedIMPMaps = [NSMutableSet set];
        GNDInstallPassiveInteractionObservers();
        GNDLog(@"loaded bundle=%@ executable=%@ iOS=%@",
               NSBundle.mainBundle.bundleIdentifier ?: @"-",
               NSBundle.mainBundle.infoDictionary[@"CFBundleExecutable"] ?: @"-",
               UIDevice.currentDevice.systemVersion);
        GNDRefreshRuntimeMetadata();

        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *note) {
            gNDNavbarLoggedThisActivation = NO;
            GNDRefreshRuntimeMetadata();
            GNDStartNavbarDiscovery();
        }];
        [center addObserverForName:UIWindowDidBecomeKeyNotification
                            object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *note) {
            GNDStartNavbarDiscovery();
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            GNDRefreshRuntimeMetadata();
            GNDStartNavbarDiscovery();
        });
    }
}
