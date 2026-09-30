#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <stdarg.h>
#import <stdlib.h>

static const NSUInteger kGNDMaxBottomViews = 350;
static const NSUInteger kGNDMaxControllers = 80;
static const NSUInteger kGNDMaxClassCandidatesPerPass = 160;
static const NSUInteger kGNDMaxMethodsPerClass = 18;

static NSUInteger gNDSequence = 0;
static CFTimeInterval gNDLastSequenceTime = 0;
static NSMutableSet<NSString *> *gNDLoggedClasses;
static dispatch_queue_t gNDClassScanQueue;
static BOOL gNDEnabled = NO;
static NSUInteger gNDBottomTouchLogs = 0;

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
    NSString *string = (NSString *)value;
    if (string.length <= 160) return string;
    return [[string substringToIndex:157] stringByAppendingString:@"..."];
}

static NSString *GNDClassName(Class cls) {
    return cls ? NSStringFromClass(cls) : @"-";
}

static NSString *GNDClassChain(Class cls) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (Class current = cls; current && names.count < 12; current = class_getSuperclass(current)) {
        [names addObject:GNDClassName(current)];
    }
    return names.count ? [names componentsJoinedByString:@"<"] : @"-";
}

static BOOL GNDContainsAny(NSString *value, NSArray<NSString *> *terms) {
    NSString *lower = value.lowercaseString;
    for (NSString *term in terms) {
        if ([lower containsString:term]) return YES;
    }
    return NO;
}

static NSArray<NSString *> *GNDInterestingTerms(void) {
    return @[@"tab", @"select", @"selected", @"navigation", @"item", @"shortcut",
             @"longpress", @"long_press", @"gesture", @"tap", @"bar", @"update",
             @"layout", @"config", @"destination"];
}

static NSArray<NSString *> *GNDStrongTerms(void) {
    return @[@"tab", @"selected", @"navigation", @"shortcut", @"longpress",
             @"long_press", @"gesture", @"destination"];
}

static NSArray<NSString *> *GNDClassNameTerms(void) {
    return @[@"tab", @"navigation", @"nav", @"dock", @"bottom", @"shortcut",
             @"chrome", @"pill", @"glass", @"floating", @"toolbar", @"bar",
             @"bookmark", @"componentkit", @"litho", @"hosting", @"visualeffect", @"fb", @"fbn",
             @"blur", @"material"];
}

static NSInteger GNDMethodPriority(NSString *name) {
    return GNDContainsAny(name, GNDStrongTerms()) ? 0 : 1;
}

static NSString *GNDImageName(Class cls, NSString *appPath) {
    const char *rawPath = class_getImageName(cls);
    if (!rawPath) return @"-";
    NSString *path = [NSString stringWithUTF8String:rawPath];
    if (![path hasPrefix:appPath]) return @"outside-app";
    NSString *relative = [path substringFromIndex:appPath.length];
    while ([relative hasPrefix:@"/"]) relative = [relative substringFromIndex:1];
    return relative.length ? relative : @"Facebook.app";
}

static BOOL GNDImageBelongsToApp(Class cls, NSString *appPath) {
    const char *rawPath = class_getImageName(cls);
    if (!rawPath) return NO;
    NSString *path = [NSString stringWithUTF8String:rawPath];
    return [path isEqualToString:appPath] ||
        [path hasPrefix:[appPath stringByAppendingString:@"/"]];
}

static NSArray<NSString *> *GNDMatchingMethods(Class cls, NSArray<NSString *> *terms) {
    if (!cls) return @[];
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSMutableArray<NSString *> *matches = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        SEL selector = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(selector);
        if (GNDContainsAny(name, terms)) [matches addObject:name];
    }
    free(methods);
    [matches sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSInteger left = GNDMethodPriority(a);
        NSInteger right = GNDMethodPriority(b);
        if (left != right) return left < right ? NSOrderedAscending : NSOrderedDescending;
        return [a compare:b];
    }];
    if (matches.count > kGNDMaxMethodsPerClass) {
        [matches removeObjectsInRange:NSMakeRange(kGNDMaxMethodsPerClass,
                                                   matches.count - kGNDMaxMethodsPerClass)];
        [matches addObject:@"...(method list capped)"];
    }
    return matches;
}

static NSInteger GNDClassPriority(NSString *name, BOOL methodMatch) {
    NSString *lower = name.lowercaseString;
    if (GNDContainsAny(lower, @[@"tab", @"navigation", @"dock", @"bottom", @"shortcut"])) return 0;
    if (GNDContainsAny(lower, @[@"glass", @"pill", @"floating", @"toolbar", @"chrome"])) return 1;
    if (methodMatch) return 2;
    if (GNDContainsAny(lower, @[@"bar", @"bookmark", @"componentkit", @"litho", @"hosting",
                                @"visualeffect", @"blur", @"material"])) return 3;
    return 4;
}

static void GNDDumpClassCandidates(void) {
    if (!gNDLoggedClasses) gNDLoggedClasses = [NSMutableSet set];

    NSString *appPath = NSBundle.mainBundle.bundlePath;
    unsigned int totalClasses = 0;
    Class *classes = objc_copyClassList(&totalClasses);
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    NSUInteger appClassCount = 0;

    for (unsigned int i = 0; i < totalClasses; i++) {
        Class cls = classes[i];
        if (!GNDImageBelongsToApp(cls, appPath)) continue;
        appClassCount++;

        NSString *name = GNDClassName(cls);
        NSArray<NSString *> *instanceMethods = GNDMatchingMethods(cls, GNDInterestingTerms());
        NSArray<NSString *> *classMethods = GNDMatchingMethods(object_getClass(cls), GNDInterestingTerms());
        BOOL nameMatch = GNDContainsAny(name, GNDClassNameTerms());
        BOOL methodMatch = GNDContainsAny([instanceMethods componentsJoinedByString:@" "], GNDStrongTerms()) ||
            GNDContainsAny([classMethods componentsJoinedByString:@" "], GNDStrongTerms());
        if (!nameMatch && !methodMatch) continue;
        if ([gNDLoggedClasses containsObject:name]) continue;

        [candidates addObject:@{
            @"class": cls,
            @"name": name,
            @"super": GNDClassName(class_getSuperclass(cls)),
            @"image": GNDImageName(cls, appPath),
            @"instance": instanceMethods,
            @"classMethods": classMethods,
            @"priority": @(GNDClassPriority(name, methodMatch))
        }];
    }
    free(classes);

    [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger left = [a[@"priority"] integerValue];
        NSInteger right = [b[@"priority"] integerValue];
        if (left != right) return left < right ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"name"] compare:b[@"name"]];
    }];

    NSUInteger emitted = MIN(candidates.count, kGNDMaxClassCandidatesPerPass);
    GNDLog(@"class-scan begin loaded=%u facebook-image-classes=%lu new-candidates=%lu",
           totalClasses, (unsigned long)appClassCount, (unsigned long)candidates.count);
    for (NSUInteger i = 0; i < emitted; i++) {
        NSDictionary *candidate = candidates[i];
        NSString *name = candidate[@"name"];
        [gNDLoggedClasses addObject:name];
        GNDLog(@"candidate navigation class: %@ address=%p superclass=%@ image=%@",
               name, candidate[@"class"], candidate[@"super"], candidate[@"image"]);
        GNDLog(@"  interesting instance methods: %@",
               [candidate[@"instance"] count] ? [candidate[@"instance"] componentsJoinedByString:@", "] : @"(none)");
        GNDLog(@"  interesting class methods: %@",
               [candidate[@"classMethods"] count] ? [candidate[@"classMethods"] componentsJoinedByString:@", "] : @"(none)");
    }
    if (candidates.count > emitted) {
        GNDLog(@"class-scan output capped; %lu additional candidates remain for a later pass",
               (unsigned long)(candidates.count - emitted));
    }
    GNDLog(@"class-scan complete");
}

static UIViewController *GNDViewControllerForView(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:UIViewController.class]) return (UIViewController *)responder;
        responder = responder.nextResponder;
    }
    return nil;
}

static NSString *GNDGestureSummary(UIGestureRecognizer *recognizer) {
    NSString *name = GNDClassName(recognizer.class);
    NSString *delegate = GNDClassName(recognizer.delegate.class);
    NSMutableString *details = [NSMutableString stringWithFormat:@"%@ state=%ld enabled=%@ delegate=%@",
                                name, (long)recognizer.state,
                                recognizer.enabled ? @"YES" : @"NO", delegate];
    if ([recognizer isKindOfClass:UILongPressGestureRecognizer.class]) {
        UILongPressGestureRecognizer *press = (UILongPressGestureRecognizer *)recognizer;
        [details appendFormat:@" minDuration=%.3f allowableMovement=%.1f touches=%lu",
         press.minimumPressDuration, press.allowableMovement,
         (unsigned long)press.numberOfTouchesRequired];
    } else if ([recognizer isKindOfClass:UITapGestureRecognizer.class]) {
        UITapGestureRecognizer *tap = (UITapGestureRecognizer *)recognizer;
        [details appendFormat:@" taps=%lu touches=%lu",
         (unsigned long)tap.numberOfTapsRequired, (unsigned long)tap.numberOfTouchesRequired];
    }
    [details appendString:@" gesture-target-actions=not-publicly-enumerable"];
    return details;
}

static void GNDDumpControlActions(UIControl *control) {
    NSArray *targets = control.allTargets.allObjects;
    if (!targets.count) return;

    NSUInteger shown = 0;
    for (id target in targets) {
        if (shown++ >= 8) {
            GNDLog(@"    control actions truncated after 8 targets");
            break;
        }
        NSArray<NSString *> *actions = [control actionsForTarget:target
                                                 forControlEvent:UIControlEventAllEvents] ?: @[];
        GNDLog(@"    control target=%@@%p actions=%@", GNDClassName([target class]), target,
               actions.count ? [actions componentsJoinedByString:@", "] : @"(none)");
    }
}

static void GNDTrackClass(NSString *name, NSMutableSet<NSString *> *found) {
    NSString *lower = name.lowercaseString;
    if ([lower containsString:@"swiftui"] || [lower containsString:@"hosting"]) [found addObject:@"Swift/SwiftUI hosting name"];
    if ([lower containsString:@"componentkit"]) [found addObject:@"ComponentKit name"];
    if ([lower containsString:@"litho"]) [found addObject:@"Litho name"];
}

static void GNDDumpBottomView(UIView *view, UIWindow *window, CGRect bottomBand,
                              NSUInteger depth, NSUInteger *visited, BOOL *truncated,
                              NSMutableSet<NSString *> *found) {
    if (!view || depth > 40 || *visited >= kGNDMaxBottomViews) {
        if (*visited >= kGNDMaxBottomViews) *truncated = YES;
        return;
    }

    CGRect windowRect = [view convertRect:view.bounds toView:window];
    if (!CGRectIntersectsRect(windowRect, bottomBand)) return;
    (*visited)++;

    NSString *name = GNDClassName(view.class);
    GNDTrackClass(name, found);
    if ([view isKindOfClass:UITabBar.class]) [found addObject:@"UITabBar view"];
    if ([view isKindOfClass:UIVisualEffectView.class]) [found addObject:@"UIVisualEffectView"];
    if ([view isKindOfClass:UICollectionView.class]) [found addObject:@"UICollectionView"];
    if ([view isKindOfClass:UIStackView.class]) [found addObject:@"UIStackView"];
    if ([view isKindOfClass:UIControl.class]) [found addObject:@"UIControl"];
    if ([view isKindOfClass:UIScrollView.class]) [found addObject:@"UIScrollView"];

    UIViewController *owner = GNDViewControllerForView(view);
    NSString *ownerDescription = owner
        ? [NSString stringWithFormat:@"%@%@%p", GNDClassName(owner.class), @"@", owner]
        : @"-";
    NSString *identifier = [view respondsToSelector:@selector(accessibilityIdentifier)]
        ? GNDString(view.accessibilityIdentifier) : @"-";
    NSString *label = [view respondsToSelector:@selector(accessibilityLabel)]
        ? GNDString(view.accessibilityLabel) : @"-";
    unsigned long long traits = [view respondsToSelector:@selector(accessibilityTraits)]
        ? (unsigned long long)view.accessibilityTraits : 0;
    NSString *parent = view.superview ? GNDClassName(view.superview.class) : @"-";
    NSString *effectName = @"-";
    if ([view isKindOfClass:UIVisualEffectView.class]) {
        UIVisualEffect *effect = ((UIVisualEffectView *)view).effect;
        effectName = effect ? GNDClassName(effect.class) : @"nil";
    }

    GNDLog(@"view depth=%lu class=%@ chain=%@ address=%p frame=%@ bounds=%@ windowFrame=%@ hidden=%@ alpha=%.3f interaction=%@ subviews=%lu parent=%@ ownerVC=%@ accessibilityID=%@ label=%@ traits=0x%llx cornerRadius=%.2f masksToBounds=%@ effect=%@",
           (unsigned long)depth, name, GNDClassChain(view.class), view,
           NSStringFromCGRect(view.frame), NSStringFromCGRect(view.bounds), NSStringFromCGRect(windowRect),
           view.hidden ? @"YES" : @"NO", view.alpha,
           view.userInteractionEnabled ? @"YES" : @"NO", (unsigned long)view.subviews.count,
           parent, ownerDescription, identifier, label, traits, view.layer.cornerRadius,
           view.layer.masksToBounds ? @"YES" : @"NO", effectName);

    for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
        GNDLog(@"  gesture on %@@%p recognizer=%@ address=%p: %@",
               name, view, GNDClassName(recognizer.class), recognizer, GNDGestureSummary(recognizer));
    }
    if ([view isKindOfClass:UIControl.class]) GNDDumpControlActions((UIControl *)view);

    for (UIView *child in view.subviews) {
        if (*visited >= kGNDMaxBottomViews) {
            *truncated = YES;
            break;
        }
        GNDDumpBottomView(child, window, bottomBand, depth + 1, visited, truncated, found);
    }
}

static void GNDDumpController(UIViewController *controller, UIWindow *window,
                              NSUInteger depth, NSUInteger *visited,
                              NSMutableSet<NSValue *> *seen,
                              NSMutableSet<NSString *> *found) {
    if (!controller || depth > 20 || *visited >= kGNDMaxControllers) return;
    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)controller];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    (*visited)++;

    NSString *name = GNDClassName(controller.class);
    GNDTrackClass(name, found);
    if ([controller isKindOfClass:UITabBarController.class]) [found addObject:@"UITabBarController"];
    UIView *loadedView = controller.isViewLoaded ? controller.viewIfLoaded : nil;
    NSString *windowFrame = loadedView.window == window
        ? NSStringFromCGRect([loadedView convertRect:loadedView.bounds toView:window]) : @"-";
    NSString *viewDetails = loadedView
        ? [NSString stringWithFormat:@"view=%@ frame=%@ bounds=%@ windowFrame=%@",
           GNDClassName(loadedView.class), NSStringFromCGRect(loadedView.frame),
           NSStringFromCGRect(loadedView.bounds), windowFrame]
        : @"view=not-loaded";
    GNDLog(@"controller depth=%lu class=%@ chain=%@ address=%p parent=%@ presented=%@ %@",
           (unsigned long)depth, name, GNDClassChain(controller.class), controller,
           GNDClassName(controller.parentViewController.class),
           GNDClassName(controller.presentedViewController.class), viewDetails);

    for (UIViewController *child in controller.childViewControllers) {
        GNDDumpController(child, window, depth + 1, visited, seen, found);
    }
    GNDDumpController(controller.presentedViewController, window, depth + 1, visited, seen, found);
}

static NSArray<UIWindow *> *GNDVisibleWindows(void) {
    UIApplication *application = UIApplication.sharedApplication;
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    NSHashTable<UIWindow *> *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];

    for (UIWindow *window in application.windows) {
        if (window && ![seen containsObject:window]) {
            [seen addObject:window];
            [windows addObject:window];
        }
    }
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window && ![seen containsObject:window]) {
                [seen addObject:window];
                [windows addObject:window];
            }
        }
    }

    NSPredicate *visible = [NSPredicate predicateWithBlock:^BOOL(UIWindow *window, NSDictionary *bindings) {
        return !window.hidden && window.alpha > 0.01 && window.rootViewController != nil;
    }];
    NSArray<UIWindow *> *visibleWindows = [windows filteredArrayUsingPredicate:visible];
    return [visibleWindows subarrayWithRange:NSMakeRange(0, MIN(visibleWindows.count, 5))];
}

static void GNDDumpWindow(UIWindow *window, NSUInteger sequence, NSUInteger attempt) {
    CGRect bounds = window.bounds;
    CGFloat bandHeight = MIN(200.0, CGRectGetHeight(bounds));
    CGRect bottomBand = CGRectMake(CGRectGetMinX(bounds), CGRectGetMaxY(bounds) - bandHeight,
                                   CGRectGetWidth(bounds), bandHeight);
    GNDLog(@"snapshot sequence=%lu attempt=%lu window=%@ address=%p key=%@ level=%.1f bounds=%@ bottomBand=%@ root=%@",
           (unsigned long)sequence, (unsigned long)attempt, GNDClassName(window.class), window,
           window.isKeyWindow ? @"YES" : @"NO", window.windowLevel,
           NSStringFromCGRect(bounds), NSStringFromCGRect(bottomBand),
           GNDClassName(window.rootViewController.class));

    NSMutableSet<NSString *> *found = [NSMutableSet set];
    NSUInteger controllerCount = 0;
    NSMutableSet<NSValue *> *seenControllers = [NSMutableSet set];
    GNDDumpController(window.rootViewController, window, 0, &controllerCount, seenControllers, found);

    NSUInteger viewCount = 0;
    BOOL truncated = NO;
    GNDDumpBottomView(window, window, bottomBand, 0, &viewCount, &truncated, found);
    NSArray<NSString *> *summary = [[found allObjects] sortedArrayUsingSelector:@selector(compare:)];
    GNDLog(@"bottom inventory window=%@ relevantViews=%lu controllers=%lu types=%@ truncated=%@",
           GNDClassName(window.class), (unsigned long)viewCount, (unsigned long)controllerCount,
           summary.count ? [summary componentsJoinedByString:@", "] : @"(no typed matches)",
           truncated ? @"YES" : @"NO");
}

static void GNDSnapshot(NSUInteger sequence, NSUInteger attempt) {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    if ((attempt == 1 || attempt == 3) && gNDClassScanQueue) {
        dispatch_async(gNDClassScanQueue, ^{
            GNDDumpClassCandidates();
        });
    }

    NSArray<UIWindow *> *windows = GNDVisibleWindows();
    GNDLog(@"snapshot sequence=%lu attempt=%lu visibleWindows=%lu",
           (unsigned long)sequence, (unsigned long)attempt, (unsigned long)windows.count);
    if (!windows.count) {
        GNDLog(@"no visible app window with a root view controller yet");
        return;
    }
    for (UIWindow *window in windows) GNDDumpWindow(window, sequence, attempt);
}

static void GNDStartSequence(NSString *trigger) {
    CFTimeInterval now = CACurrentMediaTime();
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    if (gNDSequence > 0 && now - gNDLastSequenceTime < 30.0) return;
    gNDLastSequenceTime = now;
    NSUInteger sequence = ++gNDSequence;
    gNDBottomTouchLogs = 0;
    GNDLog(@"discovery scheduled sequence=%lu trigger=%@; three snapshots over 15 seconds",
           (unsigned long)sequence, trigger);

    NSArray<NSNumber *> *delays = @[@1.5, @6.0, @15.0];
    for (NSUInteger i = 0; i < delays.count; i++) {
        NSUInteger attempt = i + 1;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delays[i].doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (sequence == gNDSequence) GNDSnapshot(sequence, attempt);
        });
    }
}

static BOOL GNDIsFacebookProcess(void) {
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *bundleID = bundle.bundleIdentifier ?: @"";
    NSString *executable = bundle.infoDictionary[@"CFBundleExecutable"] ?: @"";
    return [bundleID isEqualToString:@"com.facebook.Facebook"] ||
        [executable isEqualToString:@"Facebook"];
}

static void GNDLogBottomTouch(UITouch *touch) {
    if (!gNDEnabled || gNDSequence == 0 || touch.phase != UITouchPhaseBegan || gNDBottomTouchLogs >= 50) return;

    UIView *hitView = touch.view;
    UIWindow *window = touch.window ?: hitView.window;
    if (!hitView || !window) return;

    CGPoint point = [touch locationInView:window];
    CGRect bounds = window.bounds;
    CGFloat bandHeight = MIN(200.0, CGRectGetHeight(bounds));
    CGRect bottomBand = CGRectMake(CGRectGetMinX(bounds), CGRectGetMaxY(bounds) - bandHeight,
                                   CGRectGetWidth(bounds), bandHeight);
    if (!CGRectContainsPoint(bottomBand, point)) return;
    gNDBottomTouchLogs++;

    UIViewController *owner = GNDViewControllerForView(hitView);
    NSString *ownerDescription = owner
        ? [NSString stringWithFormat:@"%@%@%p", GNDClassName(owner.class), @"@", owner]
        : @"-";
    GNDLog(@"bottom touch began hit=%@ chain=%@ address=%p point=%@ ownerVC=%@",
           GNDClassName(hitView.class), GNDClassChain(hitView.class), hitView,
           NSStringFromCGPoint(point), ownerDescription);

    UIView *cursor = hitView;
    NSUInteger depth = 0;
    while (cursor && depth < 12) {
        GNDLog(@"  touch-path depth=%lu class=%@ address=%p frame=%@ interaction=%@",
               (unsigned long)depth, GNDClassName(cursor.class), cursor,
               NSStringFromCGRect(cursor.frame), cursor.userInteractionEnabled ? @"YES" : @"NO");
        for (UIGestureRecognizer *recognizer in cursor.gestureRecognizers) {
            GNDLog(@"    touch-path gesture class=%@ address=%p: %@",
                   GNDClassName(recognizer.class), recognizer, GNDGestureSummary(recognizer));
        }
        if ([cursor isKindOfClass:UIControl.class]) GNDDumpControlActions((UIControl *)cursor);
        cursor = cursor.superview;
        depth++;
    }
}

%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    if (gNDEnabled && event.type == UIEventTypeTouches) {
        for (UITouch *touch in event.allTouches) GNDLogBottomTouch(touch);
    }
    %orig;
}
%end

%ctor {
    @autoreleasepool {
        if (!GNDIsFacebookProcess()) return;
        gNDEnabled = YES;
        gNDClassScanQueue = dispatch_queue_create("com.panaikran.glownavdiagnostics.class-scan",
                                                  DISPATCH_QUEUE_SERIAL);
        GNDLog(@"loaded bundle=%@ executable=%@ iOS=%@",
               NSBundle.mainBundle.bundleIdentifier ?: @"-",
               NSBundle.mainBundle.infoDictionary[@"CFBundleExecutable"] ?: @"-",
               UIDevice.currentDevice.systemVersion);

        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *note) {
            GNDStartSequence(@"UIApplicationDidBecomeActive");
        }];
        [center addObserverForName:UIWindowDidBecomeKeyNotification
                            object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *note) {
            GNDStartSequence(@"UIWindowDidBecomeKey");
        }];
    }
}
