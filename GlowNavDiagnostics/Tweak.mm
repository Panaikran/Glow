#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <os/log.h>
#import <stdarg.h>
#import <math.h>
#import <string.h>
#import <stdlib.h>

static NSString * const kGNDLegacyBarClass = @"FBTabBar";
static NSString * const kGNDFloatingBarClass = @"FBFloatingTabBar";
static NSString * const kGNDTabControllerClass = @"FBTabBarViewController";
static NSString * const kGNDLegacyItemClass = @"FBTabBarItemDefaultView";
static NSString * const kGNDFloatingItemClass = @"FBFloatingTabBar.FBFloatingTabBarItemView";

static const NSUInteger kGNDMaxControllerNodes = 160;
static const NSUInteger kGNDMaxNavbarViewNodes = 160;
static const NSUInteger kGNDMaxItemNodes = 160;
static const CFTimeInterval kGNDTransitionPollInterval = 0.04;
static const CFTimeInterval kGNDMaxTransitionPollDuration = 10.0;

@interface GNDHoldSession : NSObject
@property(nonatomic, strong) UITouch *touch;
@property(nonatomic, strong) UIView *bar;
@property(nonatomic, strong) UIView *item;
@property(nonatomic, copy) NSString *tab;
@property(nonatomic, copy) NSString *tabIdentifier;
@property(nonatomic, copy) NSString *tabLabel;
@property(nonatomic, copy) NSString *barClassName;
@property(nonatomic, copy) NSString *itemClassName;
@property(nonatomic, copy) NSString *controllerClassName;
@property(nonatomic, strong) UIViewController *controller;
@property(nonatomic, copy) NSArray<NSString *> *labels;
@property(nonatomic, copy) NSArray<UILongPressGestureRecognizer *> *recognizers;
@property(nonatomic, strong) NSMutableArray<NSString *> *lastStates;
@property(nonatomic, strong) NSMutableArray<NSMutableSet<NSString *> *> *reachedStates;
@property(nonatomic, assign) CFTimeInterval startTime;
@property(nonatomic, assign) BOOL active;
@property(nonatomic, assign) BOOL handlerWindowStarted;
@property(nonatomic, assign) BOOL handlerWindowActive;
@property(nonatomic, assign) CFTimeInterval handlerWindowStartTime;
@property(nonatomic, assign) NSUInteger handlerCallCount;
@property(nonatomic, assign) NSUInteger presentationAttemptCount;
@end

@implementation GNDHoldSession
@end

static BOOL gNDEnabled = NO;
static IMP gNDOriginalSendEvent = NULL;
static UIView *gNDActiveBar;
static UIViewController *gNDActiveController;
static GNDHoldSession *gNDHoldSession;
static GNDHoldSession *gNDHandlerSession;
static NSUInteger gNDDiscoveryGeneration = 0;
static CFTimeInterval gNDLastDiscoveryTrigger = 0;
static BOOL gNDNavbarLoggedThisActivation = NO;
static NSMutableSet<NSValue *> *gNDInventoriedClasses;
static NSMutableSet<NSString *> *gNDInstalledCandidateMethods;
static NSMutableSet<NSString *> *gNDScannedGlowImages;
static NSMutableSet<NSString *> *gNDUnavailableRuntimeNames;
static BOOL gNDLoggedGlowNotLoaded = NO;
static Method gNDPresentationMethod = NULL;
static IMP gNDOriginalPresentation = NULL;
static IMP gNDPresentationReplacement = NULL;
static NSUInteger gNDHandlerWindowGeneration = 0;

static void GNDMaybeStartHandlerWindow(void);
static void GNDStartHandlerWindow(GNDHoldSession *session, NSString *recognizerLabel);
static void GNDDiscoverMethods(void);
static void GNDScanGlowImage(void);

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

static BOOL GNDClassHasName(Class cls, NSString *name) {
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        if ([GNDClassName(current) isEqualToString:name]) return YES;
    }
    return NO;
}

static NSString *GNDNavbarMode(Class cls) {
    if (GNDClassHasName(cls, kGNDLegacyBarClass)) return @"legacy";
    if (GNDClassHasName(cls, kGNDFloatingBarClass)) return @"floating";
    return @"unknown";
}

static NSString *GNDGestureStateName(UIGestureRecognizerState state) {
    switch (state) {
        case UIGestureRecognizerStatePossible: return @"possible";
        case UIGestureRecognizerStateBegan: return @"began";
        case UIGestureRecognizerStateChanged: return @"changed";
        case UIGestureRecognizerStateEnded: return @"ended";
        case UIGestureRecognizerStateCancelled: return @"cancelled";
        case UIGestureRecognizerStateFailed: return @"failed";
    }
    return @"unknown";
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
    CGRect windowFrame = [view convertRect:view.bounds toView:window];
    return CGRectIntersectsRect(windowFrame, window.bounds);
}

static UIView *GNDFindNavbarView(UIView *view, UIWindow *window,
                                  NSUInteger depth, NSUInteger *visited) {
    if (!view || depth > 12 || *visited >= kGNDMaxNavbarViewNodes) return nil;
    (*visited)++;
    if (!GNDViewVisibleInWindow(view, window)) return nil;
    if ([GNDNavbarMode(view.class) isEqualToString:@"legacy"] ||
        [GNDNavbarMode(view.class) isEqualToString:@"floating"]) return view;

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
        if (GNDIsKnownTabItemClass(view.class)) {
            GNDAddUniqueView(view, knownItems, knownSeen);
        } else if ([GNDAccessibilityIdentifier(view) hasPrefix:@"tab-bar-item-"]) {
            GNDAddUniqueView(view, identifiedItems, identifiedSeen);
        }
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

static void GNDLogRecognizer(UILongPressGestureRecognizer *recognizer, NSString *label,
                             UIView *owner) {
    id delegate = recognizer.delegate;
    GNDLog(@"recognizer label=%@ class=%@ address=%p ownerClass=%@ delegateClass=%@ delegate=%p minimumPressDuration=%.3f allowableMovement=%.1f numberOfTouchesRequired=%lu enabled=%@ initialState=%@",
           label, GNDClassName(recognizer.class), recognizer, GNDClassName(owner.class),
           GNDClassName([delegate class]), delegate, recognizer.minimumPressDuration,
           recognizer.allowableMovement, (unsigned long)recognizer.numberOfTouchesRequired,
           recognizer.enabled ? @"YES" : @"NO", GNDGestureStateName(recognizer.state));
}

static NSString *GNDRecognizerLabel(UILongPressGestureRecognizer *recognizer,
                                   UIView *bar, NSUInteger *unknownIndex) {
    BOOL legacyBar = GNDClassHasName(bar.class, kGNDLegacyBarClass);
    BOOL floatingBar = GNDClassHasName(bar.class, kGNDFloatingBarClass);
    BOOL controllerDelegate = GNDClassHasName([recognizer.delegate class], kGNDTabControllerClass);
    BOOL floatingDelegate = GNDClassHasName([recognizer.delegate class], kGNDFloatingBarClass);
    BOOL controllerDuration = fabs(recognizer.minimumPressDuration - 0.750) < 0.025;
    BOOL zeroDuration = recognizer.minimumPressDuration < 0.025;

    if (legacyBar && controllerDelegate && controllerDuration) return @"legacy-controller-longpress";
    if (floatingBar && floatingDelegate && zeroDuration) return @"floating-bar-longpress";
    if (controllerDelegate && controllerDuration) return @"controller-longpress";
    return [NSString stringWithFormat:@"unknown-longpress-%lu", (unsigned long)(++*unknownIndex)];
}

static NSArray<NSDictionary<NSString *, id> *> *GNDLongPressEntries(UIView *bar, UIView *item) {
    NSMutableArray<NSDictionary<NSString *, id> *> *entries = [NSMutableArray array];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    NSMutableSet<NSString *> *usedLabels = [NSMutableSet set];
    NSUInteger unknownIndex = 0;
    NSArray<UIView *> *owners = item ? @[bar, item] : @[bar];

    for (UIView *owner in owners) {
        for (UIGestureRecognizer *candidate in owner.gestureRecognizers) {
            if (![candidate isKindOfClass:UILongPressGestureRecognizer.class]) continue;
            NSValue *key = [NSValue valueWithPointer:(__bridge const void *)candidate];
            if ([seen containsObject:key]) continue;
            [seen addObject:key];

            UILongPressGestureRecognizer *recognizer = (UILongPressGestureRecognizer *)candidate;
            NSString *label = GNDRecognizerLabel(recognizer, bar, &unknownIndex);
            NSString *base = label;
            NSUInteger suffix = 2;
            while ([usedLabels containsObject:label]) {
                label = [NSString stringWithFormat:@"%@-%lu", base, (unsigned long)suffix++];
            }
            [usedLabels addObject:label];
            [entries addObject:@{@"recognizer": recognizer, @"label": label, @"owner": owner}];
        }
    }
    return entries;
}

static void GNDLogNavbarIfChanged(UIView *bar, UIViewController *controller, UIWindow *window) {
    if (!bar || !controller || !window) return;
    if (gNDActiveBar == bar && gNDActiveController == controller &&
        gNDNavbarLoggedThisActivation) return;

    gNDActiveBar = bar;
    gNDActiveController = controller;
    gNDNavbarLoggedThisActivation = YES;

    NSArray<UIView *> *items = GNDVisibleTabItems(bar, window);
    CGRect windowFrame = [bar convertRect:bar.bounds toView:window];
    GNDLog(@"navbar mode=%@ class=%@ bar=%p controller=%p frame=%@ windowFrame=%@ visibleItems=%lu",
           GNDNavbarMode(bar.class), GNDClassName(bar.class), bar, controller,
           NSStringFromCGRect(bar.frame), NSStringFromCGRect(windowFrame),
           (unsigned long)items.count);
    for (UIView *item in items) {
        GNDLog(@"item class=%@ address=%p accessibilityIdentifier=%@ accessibilityLabel=%@ frame=%@",
               GNDClassName(item.class), item, GNDAccessibilityIdentifier(item),
               GNDAccessibilityLabel(item), NSStringFromCGRect(item.frame));
    }

    for (NSDictionary<NSString *, id> *entry in GNDLongPressEntries(bar, nil)) {
        GNDLogRecognizer(entry[@"recognizer"], entry[@"label"], entry[@"owner"]);
    }
}

static void GNDTryNavbarDiscovery(NSUInteger generation, NSUInteger attempt) {
    if (generation != gNDDiscoveryGeneration ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;

    UIWindow *window = nil;
    UIViewController *controller = nil;
    UIView *bar = GNDCurrentNavbar(&window, &controller);
    if (bar && controller && window) {
        GNDScanGlowImage();
        GNDDiscoverMethods();
        GNDLogNavbarIfChanged(bar, controller, window);
        return;
    }
    if (attempt == 3) {
        GNDLog(@"navbar mode=unknown class=- controller=%@ window=%@",
               GNDClassName(controller.class), window ? @"available" : @"unavailable");
    }
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

static UIViewController *GNDTabControllerForView(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:UIViewController.class] &&
            GNDClassHasName(responder.class, kGNDTabControllerClass)) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

static BOOL GNDTabContextForView(UIView *view, UIView **itemOut, UIView **barOut) {
    UIView *knownItem = nil;
    UIView *identifiedItem = nil;
    UIView *bar = nil;
    for (UIView *current = view; current; current = current.superview) {
        if (!knownItem && GNDIsKnownTabItemClass(current.class)) knownItem = current;
        if (!identifiedItem && [GNDAccessibilityIdentifier(current) hasPrefix:@"tab-bar-item-"]) {
            identifiedItem = current;
        }
        NSString *mode = GNDNavbarMode(current.class);
        if ([mode isEqualToString:@"legacy"] || [mode isEqualToString:@"floating"]) {
            bar = current;
            break;
        }
    }
    UIView *item = knownItem ?: identifiedItem;
    if (!item || !bar) return NO;
    if (itemOut) *itemOut = item;
    if (barOut) *barOut = bar;
    return YES;
}

static NSString *GNDCompactLabel(NSString *label) {
    if ([label isEqualToString:@"floating-bar-longpress"]) return @"floating";
    if ([label isEqualToString:@"controller-longpress"] ||
        [label isEqualToString:@"legacy-controller-longpress"]) return @"controller";
    return label;
}

static void GNDRecordRecognizerStates(GNDHoldSession *session) {
    CFTimeInterval elapsed = CACurrentMediaTime() - session.startTime;
    for (NSUInteger index = 0; index < session.recognizers.count; index++) {
        UILongPressGestureRecognizer *recognizer = session.recognizers[index];
        NSString *state = GNDGestureStateName(recognizer.state);
        NSMutableSet<NSString *> *reached = session.reachedStates[index];
        [reached addObject:state];

        NSString *previous = session.lastStates[index];
        if (![previous isEqualToString:state]) {
            if (previous.length) {
                GNDLog(@"hold transition tab=%@ elapsed=%.2f recognizer=%@ from=%@ to=%@",
                       session.tab, elapsed, session.labels[index], previous, state);
            } else {
                GNDLog(@"hold recognizer observed tab=%@ elapsed=%.2f recognizer=%@ state=%@",
                       session.tab, elapsed, session.labels[index], state);
            }
            session.lastStates[index] = state;
        }
        if ([session.labels[index] isEqualToString:@"controller-longpress"] ||
            [session.labels[index] isEqualToString:@"legacy-controller-longpress"]) {
            if (recognizer.state == UIGestureRecognizerStateBegan) {
                GNDStartHandlerWindow(session, session.labels[index]);
            }
        }
    }
}

static BOOL GNDClassIsInFacebookApp(Class cls) {
    const char *imageName = cls ? class_getImageName(cls) : NULL;
    if (!imageName) return NO;
    NSString *image = [NSString stringWithUTF8String:imageName];
    NSString *bundle = NSBundle.mainBundle.bundlePath;
    return [image isEqualToString:NSBundle.mainBundle.executablePath] ||
        [image hasPrefix:[bundle stringByAppendingString:@"/"]];
}

static BOOL GNDSelectorIsInteresting(NSString *selector) {
    static NSArray<NSString *> *keywords;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[@"long", @"press", @"gesture", @"tab", @"item", @"menu",
                     @"context", @"shortcut", @"action", @"select", @"reorder",
                     @"configure", @"settings"];
    });
    NSString *lower = selector.lowercaseString;
    for (NSString *keyword in keywords) {
        if ([lower containsString:keyword]) return YES;
    }
    return NO;
}

static BOOL GNDSelectorIsHandlerCandidate(NSString *selector, BOOL exactTargetClass) {
    NSString *lower = selector.lowercaseString;
    for (NSString *keyword in @[@"long", @"press", @"gesture", @"menu", @"context",
                                @"shortcut", @"settings"]) {
        if ([lower containsString:keyword]) return YES;
    }
    return exactTargetClass && [lower containsString:@"action"];
}

static NSString *GNDMethodSignatureDescription(Method method) {
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    return encoding ? [NSString stringWithUTF8String:encoding] : @"?";
}

static BOOL GNDMethodHasSafeObjectSignature(Method method, NSUInteger *objectArgumentCount) {
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!encoding) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:encoding];
    if (!signature || signature.methodReturnType[0] != 'v' ||
        signature.numberOfArguments < 2 || signature.numberOfArguments > 5) return NO;

    NSUInteger explicitCount = signature.numberOfArguments - 2;
    for (NSUInteger index = 2; index < signature.numberOfArguments; index++) {
        const char *type = [signature getArgumentTypeAtIndex:index];
        while (type && strchr("rnNoORV", type[0])) type++;
        if (!type || (type[0] != '@' && type[0] != '#')) return NO;
    }
    if (objectArgumentCount) *objectArgumentCount = explicitCount;
    return YES;
}

static NSString *GNDObjectDescription(id object) {
    if (!object) return @"nil";
    if (object == NSNull.null) return @"nil";
    return [NSString stringWithFormat:@"%@#%p", GNDClassName(object_getClass(object)), object];
}

static BOOL GNDHandlerWindowIsActive(void) {
    GNDHoldSession *session = gNDHandlerSession;
    return session && session.handlerWindowActive &&
        CACurrentMediaTime() - session.handlerWindowStartTime <= 1.0;
}

static NSString *GNDHandlerContext(GNDHoldSession *session) {
    if (!session) return @"bar=- item=- tab=- id=-";
    return [NSString stringWithFormat:@"bar=%@#%p item=%@#%p tab=%@ id=%@",
            session.barClassName ?: @"-", session.bar,
            session.itemClassName ?: @"-", session.item,
            session.tabLabel.length ? session.tabLabel : session.tab,
            session.tabIdentifier ?: @"-"];
}

static void GNDLogCandidateCall(id object, SEL selector, NSArray *arguments) {
    GNDMaybeStartHandlerWindow();
    if (!GNDHandlerWindowIsActive()) return;
    GNDHoldSession *session = gNDHandlerSession;
    session.handlerCallCount++;
    NSMutableArray<NSString *> *argumentDescriptions = [NSMutableArray arrayWithCapacity:arguments.count];
    for (id argument in arguments) [argumentDescriptions addObject:GNDObjectDescription(argument)];
    CFTimeInterval elapsed = CACurrentMediaTime() - session.handlerWindowStartTime;
    GNDLogTagged(@"CALL", @"elapsed=%.3f selector=%@ self=%@#%p args=[%@] controller=%@#%p %@",
                 elapsed, NSStringFromSelector(selector), GNDClassName(object_getClass(object)), object,
                 argumentDescriptions.count ? [argumentDescriptions componentsJoinedByString:@", "] : @"",
                 session.controllerClassName ?: @"-", session.controller,
                 GNDHandlerContext(session));
}

static NSString *GNDInstallCandidateMethod(Class owner, Method method) {
    NSUInteger argumentCount = 0;
    if (!GNDMethodHasSafeObjectSignature(method, &argumentCount)) return @"skip-signature";

    SEL selector = method_getName(method);
    NSString *key = [NSString stringWithFormat:@"%p:%@", owner, NSStringFromSelector(selector)];
    if ([gNDInstalledCandidateMethods containsObject:key]) return @"installed";

    IMP original = method_getImplementation(method);
    IMP replacement = NULL;
    switch (argumentCount) {
        case 0:
            replacement = imp_implementationWithBlock(^(id object) {
                GNDLogCandidateCall(object, selector, @[]);
                ((void (*)(id, SEL))original)(object, selector);
            });
            break;
        case 1:
            replacement = imp_implementationWithBlock(^(id object, id first) {
                GNDLogCandidateCall(object, selector, @[first ?: NSNull.null]);
                ((void (*)(id, SEL, id))original)(object, selector, first);
            });
            break;
        case 2:
            replacement = imp_implementationWithBlock(^(id object, id first, id second) {
                GNDLogCandidateCall(object, selector,
                                    @[first ?: NSNull.null, second ?: NSNull.null]);
                ((void (*)(id, SEL, id, id))original)(object, selector, first, second);
            });
            break;
        case 3:
            replacement = imp_implementationWithBlock(^(id object, id first, id second, id third) {
                GNDLogCandidateCall(object, selector,
                                    @[first ?: NSNull.null, second ?: NSNull.null,
                                      third ?: NSNull.null]);
                ((void (*)(id, SEL, id, id, id))original)(object, selector,
                                                          first, second, third);
            });
            break;
        default:
            return @"skip-arity";
    }
    if (!replacement) return @"skip-wrapper";

    method_setImplementation(method, replacement);
    [gNDInstalledCandidateMethods addObject:key];
    return @"installed";
}

static void GNDDiscoverMethods(void) {
    if (!gNDInventoriedClasses) gNDInventoriedClasses = [NSMutableSet set];
    if (!gNDInstalledCandidateMethods) gNDInstalledCandidateMethods = [NSMutableSet set];
    if (!gNDUnavailableRuntimeNames) gNDUnavailableRuntimeNames = [NSMutableSet set];
    NSArray<NSString *> *requestedClasses = @[kGNDTabControllerClass, kGNDLegacyBarClass,
                                               kGNDLegacyItemClass, kGNDFloatingBarClass,
                                               kGNDFloatingItemClass];
    for (NSString *requestedName in requestedClasses) {
        Class requested = NSClassFromString(requestedName);
        if (!requested) {
            if (![gNDUnavailableRuntimeNames containsObject:requestedName]) {
                [gNDUnavailableRuntimeNames addObject:requestedName];
                GNDLogTagged(@"METHOD", @"class=%@ unavailable", requestedName);
            }
            continue;
        }
        [gNDUnavailableRuntimeNames removeObject:requestedName];
        for (Class cls = requested; cls; cls = class_getSuperclass(cls)) {
            NSValue *classKey = [NSValue valueWithPointer:(__bridge const void *)cls];
            if ([gNDInventoriedClasses containsObject:classKey]) continue;
            [gNDInventoriedClasses addObject:classKey];

            unsigned int count = 0;
            Method *methods = class_copyMethodList(cls, &count);
            NSMutableArray<NSString *> *inventory = [NSMutableArray array];
            for (unsigned int index = 0; index < count; index++) {
                Method method = methods[index];
                NSString *selectorName = NSStringFromSelector(method_getName(method));
                if (!GNDSelectorIsInteresting(selectorName)) continue;

                NSString *trace = @"inventory-only";
                if (GNDSelectorIsHandlerCandidate(selectorName, cls == requested) &&
                    GNDClassIsInFacebookApp(cls)) {
                    trace = GNDInstallCandidateMethod(cls, method);
                }
                [inventory addObject:[NSString stringWithFormat:@"%@{%@,%@}", selectorName,
                                     GNDMethodSignatureDescription(method), trace]];
            }
            free(methods);
            GNDLogTagged(@"METHOD", @"class=%@ superclass=%@ selectors=%@",
                         GNDClassName(cls), GNDClassName(class_getSuperclass(cls)),
                         inventory.count ? [inventory componentsJoinedByString:@"; "] : @"none");
        }
    }
}

static Method GNDDirectInstanceMethod(Class cls, SEL selector) {
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

static void GNDPresentViewController(id presenter, SEL selector, UIViewController *presented,
                                     BOOL animated, void (^completion)(void)) {
    GNDMaybeStartHandlerWindow();
    if (GNDHandlerWindowIsActive()) {
        GNDHoldSession *session = gNDHandlerSession;
        session.presentationAttemptCount++;
        GNDLogTagged(@"PRESENT", @"elapsed=%.3f selector=%@ presenter=%@#%p presented=%@#%p animated=%@ %@",
                     CACurrentMediaTime() - session.handlerWindowStartTime,
                     NSStringFromSelector(selector), GNDClassName(object_getClass(presenter)), presenter,
                     GNDClassName(object_getClass(presented)), presented,
                     animated ? @"YES" : @"NO", GNDHandlerContext(session));
    }
    IMP original = gNDOriginalPresentation;
    if (original) {
        ((void (*)(id, SEL, UIViewController *, BOOL, void (^)(void)))original)(
            presenter, selector, presented, animated, completion);
    }
}

static BOOL GNDInstallPresentationObserver(void) {
    if (gNDPresentationMethod && gNDPresentationReplacement) {
        return method_getImplementation(gNDPresentationMethod) == gNDPresentationReplacement;
    }
    Class cls = UIViewController.class;
    SEL selector = @selector(presentViewController:animated:completion:);
    Method method = GNDDirectInstanceMethod(cls, selector);
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (!signature || signature.numberOfArguments != 5 || signature.methodReturnType[0] != 'v') return NO;
    const char *controllerType = [signature getArgumentTypeAtIndex:2];
    const char *animatedType = [signature getArgumentTypeAtIndex:3];
    const char *completionType = [signature getArgumentTypeAtIndex:4];
    if (!controllerType || controllerType[0] != '@' || !animatedType ||
        (animatedType[0] != 'c' && animatedType[0] != 'B') ||
        !completionType || completionType[0] != '@') return NO;

    IMP current = method_getImplementation(method);
    if (current == (IMP)GNDPresentViewController) return YES;
    gNDPresentationMethod = method;
    gNDOriginalPresentation = current;
    gNDPresentationReplacement = (IMP)GNDPresentViewController;
    method_setImplementation(method, gNDPresentationReplacement);
    return YES;
}

static void GNDRemovePresentationObserver(void) {
    if (!gNDPresentationMethod || !gNDPresentationReplacement) return;
    if (method_getImplementation(gNDPresentationMethod) != gNDPresentationReplacement) return;
    method_setImplementation(gNDPresentationMethod, gNDOriginalPresentation);
    gNDPresentationMethod = NULL;
    gNDOriginalPresentation = NULL;
    gNDPresentationReplacement = NULL;
}

static void GNDEndHandlerWindow(GNDHoldSession *session, NSUInteger generation) {
    if (!session || !session.handlerWindowActive || generation != gNDHandlerWindowGeneration) return;
    session.handlerWindowActive = NO;
    GNDRemovePresentationObserver();
    GNDLogTagged(@"HANDLER", @"window complete tab=%@ calls=%lu presentations=%lu",
                 session.tabLabel.length ? session.tabLabel : session.tab,
                 (unsigned long)session.handlerCallCount,
                 (unsigned long)session.presentationAttemptCount);
}

static void GNDStartHandlerWindow(GNDHoldSession *session, NSString *recognizerLabel) {
    if (!session || session.handlerWindowStarted) return;
    session.handlerWindowStarted = YES;
    session.handlerWindowActive = YES;
    session.handlerWindowStartTime = CACurrentMediaTime();
    gNDHandlerSession = session;
    NSUInteger generation = ++gNDHandlerWindowGeneration;
    BOOL presentationObserver = GNDInstallPresentationObserver();
    GNDLogTagged(@"HANDLER", @"elapsed=%.3f trigger=%@->began controller=%@#%p %@ presentationObserver=%@ window=1.0s",
                 session.handlerWindowStartTime - session.startTime, recognizerLabel,
                 session.controllerClassName ?: @"-", session.controller,
                 GNDHandlerContext(session), presentationObserver ? @"installed" : @"unavailable");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        GNDEndHandlerWindow(session, generation);
    });
}

static void GNDMaybeStartHandlerWindow(void) {
    GNDHoldSession *session = gNDHoldSession;
    if (!session || session.handlerWindowStarted) return;
    for (NSUInteger index = 0; index < session.recognizers.count; index++) {
        NSString *label = session.labels[index];
        if (([label isEqualToString:@"controller-longpress"] ||
             [label isEqualToString:@"legacy-controller-longpress"]) &&
            session.recognizers[index].state == UIGestureRecognizerStateBegan) {
            GNDStartHandlerWindow(session, label);
            return;
        }
    }
}

static void GNDScanGlowImage(void) {
    if (!gNDScannedGlowImages) gNDScannedGlowImages = [NSMutableSet set];
    BOOL found = NO;
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t index = 0; index < imageCount; index++) {
        const char *imageName = _dyld_get_image_name(index);
        if (!imageName) continue;
        NSString *path = [NSString stringWithUTF8String:imageName];
        if ([path.lastPathComponent caseInsensitiveCompare:@"Glow.dylib"] != NSOrderedSame) continue;
        found = YES;
        if ([gNDScannedGlowImages containsObject:path]) continue;
        [gNDScannedGlowImages addObject:path];
        GNDLogTagged(@"GLOW", @"image=%@", path);
        unsigned int classCount = 0;
        const char **classNames = objc_copyClassNamesForImage(imageName, &classCount);
        for (unsigned int classIndex = 0; classNames && classIndex < classCount; classIndex++) {
            if (classNames[classIndex]) {
                GNDLogTagged(@"GLOW", @"class=%s", classNames[classIndex]);
            }
        }
        free((void *)classNames);
    }
    if (!found && !gNDLoggedGlowNotLoaded) {
        gNDLoggedGlowNotLoaded = YES;
        GNDLogTagged(@"GLOW", @"image=not-loaded");
    }
}

static void GNDEmitHoldSample(GNDHoldSession *session) {
    if (!session.active || gNDHoldSession != session) return;
    GNDRecordRecognizerStates(session);
    NSMutableArray<NSString *> *states = [NSMutableArray array];
    for (NSUInteger index = 0; index < session.recognizers.count; index++) {
        [states addObject:[NSString stringWithFormat:@"%@=%@",
                           GNDCompactLabel(session.labels[index]),
                           GNDGestureStateName(session.recognizers[index].state)]];
    }
    CFTimeInterval elapsed = CACurrentMediaTime() - session.startTime;
    GNDLog(@"hold sample tab=%@ elapsed=%.2f %@",
           session.tab, elapsed, states.count ? [states componentsJoinedByString:@" "] : @"recognizers=none");
}

static void GNDContinueTransitionPolling(GNDHoldSession *session) {
    if (!session.active || gNDHoldSession != session) return;
    GNDRecordRecognizerStates(session);
    if (CACurrentMediaTime() - session.startTime >= kGNDMaxTransitionPollDuration) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kGNDTransitionPollInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        GNDContinueTransitionPolling(session);
    });
}

static void GNDStartHold(UITouch *touch) {
    if (!gNDEnabled || gNDHoldSession) return;
    UIView *item = nil;
    UIView *bar = nil;
    if (!GNDTabContextForView(touch.view, &item, &bar)) return;

    UIWindow *window = touch.window ?: item.window;
    UIViewController *controller = GNDTabControllerForView(bar) ?: gNDActiveController;
    if (!controller || !window) return;
    GNDScanGlowImage();
    GNDDiscoverMethods();
    GNDLogNavbarIfChanged(bar, controller, window);

    NSString *identifier = GNDAccessibilityIdentifier(item);
    NSString *label = GNDAccessibilityLabel(item);
    NSString *tab = [label isEqualToString:@"-"] ? identifier : label;
    NSArray<NSDictionary<NSString *, id> *> *entries = GNDLongPressEntries(bar, item);
    NSMutableArray<UILongPressGestureRecognizer *> *recognizers = [NSMutableArray array];
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *entry in entries) {
        UILongPressGestureRecognizer *recognizer = entry[@"recognizer"];
        [recognizers addObject:recognizer];
        [labels addObject:entry[@"label"]];
        GNDLogRecognizer(recognizer, entry[@"label"], entry[@"owner"]);
    }

    GNDHoldSession *session = [GNDHoldSession new];
    session.touch = touch;
    session.bar = bar;
    session.item = item;
    session.tab = tab;
    session.tabIdentifier = identifier;
    session.tabLabel = label;
    session.barClassName = GNDClassName(bar.class);
    session.itemClassName = GNDClassName(item.class);
    session.controller = controller;
    session.controllerClassName = GNDClassName(controller.class);
    session.labels = labels;
    session.recognizers = recognizers;
    session.lastStates = [NSMutableArray arrayWithCapacity:recognizers.count];
    session.reachedStates = [NSMutableArray arrayWithCapacity:recognizers.count];
    for (NSUInteger index = 0; index < recognizers.count; index++) {
        [session.lastStates addObject:@""];
        [session.reachedStates addObject:[NSMutableSet set]];
    }
    session.startTime = touch.timestamp;
    session.active = YES;
    gNDHoldSession = session;

    GNDLog(@"hold begin tab=%@ id=%@ mode=%@ item=%p", tab, identifier,
           GNDNavbarMode(bar.class), item);
    GNDEmitHoldSample(session);
    NSArray<NSNumber *> *sampleTimes = @[@0.25, @0.50, @0.80, @1.00, @1.50, @3.00];
    for (NSNumber *time in sampleTimes) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(time.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            GNDEmitHoldSample(session);
        });
    }
    GNDContinueTransitionPolling(session);
}

static void GNDFinishHold(UITouch *touch) {
    GNDHoldSession *session = gNDHoldSession;
    if (!session || session.touch != touch) return;

    GNDRecordRecognizerStates(session);
    session.active = NO;
    CFTimeInterval duration = CACurrentMediaTime() - session.startTime;
    GNDLog(@"hold complete tab=%@ duration=%.2f touch=%@", session.tab, duration,
           touch.phase == UITouchPhaseCancelled ? @"cancelled" : @"ended");

    NSArray<NSString *> *reportOrder = @[@"began", @"changed", @"ended", @"failed", @"cancelled"];
    for (NSUInteger index = 0; index < session.recognizers.count; index++) {
        NSMutableArray<NSString *> *reached = [NSMutableArray array];
        for (NSString *state in reportOrder) {
            if ([session.reachedStates[index] containsObject:state]) [reached addObject:state];
        }
        GNDLog(@"hold result recognizer=%@ final=%@ reached=%@",
               session.labels[index],
               GNDGestureStateName(session.recognizers[index].state),
               reached.count ? [reached componentsJoinedByString:@","] : @"none");
    }
    gNDHoldSession = nil;
}

static void GNDSendEvent(UIApplication *application, SEL selector, UIEvent *event) {
    NSMutableArray<UITouch *> *beganTouches = nil;
    NSMutableArray<UITouch *> *finishedTouches = nil;
    if (gNDEnabled && event.type == UIEventTypeTouches) {
        for (UITouch *touch in event.allTouches) {
            if (touch.phase == UITouchPhaseBegan) {
                if (!beganTouches) beganTouches = [NSMutableArray arrayWithCapacity:1];
                [beganTouches addObject:touch];
            } else if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
                if (!finishedTouches) finishedTouches = [NSMutableArray arrayWithCapacity:1];
                [finishedTouches addObject:touch];
            }
        }
    }

    IMP original = gNDOriginalSendEvent;
    if (original) {
        ((void (*)(UIApplication *, SEL, UIEvent *))original)(application, selector, event);
    }
    if (gNDHoldSession) GNDRecordRecognizerStates(gNDHoldSession);
    for (UITouch *touch in beganTouches) GNDStartHold(touch);
    for (UITouch *touch in finishedTouches) GNDFinishHold(touch);
}

static BOOL GNDInstallSendEventHook(void) {
    Class applicationClass = objc_getClass("UIApplication");
    SEL selector = sel_registerName("sendEvent:");
    Method method = applicationClass ? class_getInstanceMethod(applicationClass, selector) : NULL;
    if (!method) return NO;

    IMP original = method_getImplementation(method);
    if (original == (IMP)GNDSendEvent) return gNDOriginalSendEvent != NULL;
    if (class_addMethod(applicationClass, selector, (IMP)GNDSendEvent,
                        method_getTypeEncoding(method))) {
        gNDOriginalSendEvent = original;
    } else {
        gNDOriginalSendEvent = method_setImplementation(method, (IMP)GNDSendEvent);
    }
    return gNDOriginalSendEvent != NULL;
}

__attribute__((constructor))
static void GNDInitialize(void) {
    @autoreleasepool {
        if (!GNDIsFacebookProcess()) return;
        gNDEnabled = GNDInstallSendEventHook();
        GNDScanGlowImage();
        GNDLog(@"loaded bundle=%@ executable=%@ iOS=%@ sendEventHook=%@",
               NSBundle.mainBundle.bundleIdentifier ?: @"-",
               NSBundle.mainBundle.infoDictionary[@"CFBundleExecutable"] ?: @"-",
               UIDevice.currentDevice.systemVersion,
               gNDEnabled ? @"installed" : @"unavailable");

        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *note) {
            gNDNavbarLoggedThisActivation = NO;
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
