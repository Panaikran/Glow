#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <stdarg.h>
#import <math.h>

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
@property(nonatomic, copy) NSArray<NSString *> *labels;
@property(nonatomic, copy) NSArray<UILongPressGestureRecognizer *> *recognizers;
@property(nonatomic, strong) NSMutableArray<NSString *> *lastStates;
@property(nonatomic, strong) NSMutableArray<NSMutableSet<NSString *> *> *reachedStates;
@property(nonatomic, assign) CFTimeInterval startTime;
@property(nonatomic, assign) BOOL active;
@end

@implementation GNDHoldSession
@end

static BOOL gNDEnabled = NO;
static IMP gNDOriginalSendEvent = NULL;
static UIView *gNDActiveBar;
static UIViewController *gNDActiveController;
static GNDHoldSession *gNDHoldSession;
static NSUInteger gNDDiscoveryGeneration = 0;
static CFTimeInterval gNDLastDiscoveryTrigger = 0;
static BOOL gNDNavbarLoggedThisActivation = NO;

static void GNDLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "%{public}@",
                     [@"[GlowNavDiag] " stringByAppendingString:message]);
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
