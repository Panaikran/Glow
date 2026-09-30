# GlowNavDiagnostics

Read-only runtime discovery for Facebook's bottom navigation. This tweak does not change Glow, Facebook views, gestures, or navigation state.

## Confirmed repository findings

- The fork contains the IPA workflow, README, localization files, and Sileo assets. It does not contain Glow's Logos/Objective-C source or a Theos project.
- `.github/workflows/main.yml` requests `https://api.github.com/repos/dayanch96/Glow/releases/latest`, reads `.assets[0].browser_download_url`, saves it as `glow_fb.deb`, and passes that deb to `cyan` for injection.
- At inspection time (2026-09-30), upstream's latest release is `v1.3.1` (published 2025-06-25). The workflow's first asset is `com.dvntm.glow_1.3.1_iphoneos-arm.deb`; the release also has `iphoneos-arm64` and `iphoneos-arm64e` assets. The filenames establish which asset is selected, but do not establish which Mach-O slices are inside it.
- The fork's last commit is `b3b6a5a` (2025-07-13). Upstream `main` is now `681ee3e` (2026-08-03); the intervening diff is one Polish localization file. No Glow implementation source was added.
- Changing the workflow could select a different release asset or alter IPA packaging. It cannot change the hooks inside the downloaded closed-source Glow deb. Asset selection is a separate packaging variable and should be recorded during the runtime test.

## Upstream failure evidence

- Glow's README documents settings via long press on any tab: [upstream README](https://github.com/dayanch96/Glow/blob/main/README.md).
- Issue [#37](https://github.com/dayanch96/Glow/issues/37), opened 2026-01-28, reports that Glow settings cannot be accessed on a new Facebook version. It gives no Facebook build number, logs, or reproduction details beyond that statement.
- Issue [#38](https://github.com/dayanch96/Glow/issues/38), opened 2026-02-02, reports that Reels removal has no effect and says normal navbar-item removal also does nothing. The reporter tested Facebook `546.0.0` and `519.0.0`.
- Issue [#31](https://github.com/dayanch96/Glow/issues/31), opened 2025-11-06, is a Reels-tab feature request, not a failure report.
- Issue [#44](https://github.com/dayanch96/Glow/issues/44), opened 2026-08-21, says Glow crashes on launch but supplies no Facebook version or diagnostic evidence. It cannot be tied to the navbar reports.
- The earliest concrete public evidence found for these navbar failures is #37 on 2026-01-28, followed by the specific hide failures in #38 on 2026-02-02. This dates reports, not the actual regression: the issues do not identify the first affected Facebook build or a cause.

## What the diagnostic records

- On app activation or a key-window event, it takes three snapshots at about 1.5, 6, and 15 seconds. Requests are rate-limited to one sequence per 30 seconds. The class scan runs on the first and last snapshots so classes loaded lazily have a chance to appear.
- It scans visible app windows, controller containment/presentation, and views intersecting the bottom 200 points. Per window, the view scan is capped at 350 objects and the controller scan at 80.
- For each scanned bottom view it logs class and superclass chain, address, frame/bounds/window frame, hidden/alpha/interaction state, subview count, superview, owning controller, gestures, accessibility identifier/label/traits, layer corner radius, and visual-effect class when present.
- It reads `UIControl` targets/actions through public APIs. It records `UIGestureRecognizer` class, delegate class, state, and public long-press/tap settings. UIKit does not publicly expose a gesture recognizer's registered target/action list, so the diagnostic deliberately does not read private ivars or use KVC for it.
- A narrowly filtered `UIApplication sendEvent:` observer captures touch-began objects, forwards the original event unchanged, then logs at most 50 hit-tested touches per sequence and only when they start in the bottom 200 points. Each line identifies UIKit's hit-tested touch view and its ancestor path, including gesture recognizers and public control actions.
- Runtime class enumeration is limited to images inside Facebook.app. It prints candidate names and matching instance/class method names; it never invokes those methods.
- There are no `UIView` layout hooks, view mutations, synthetic gestures, or KVC reads.

## Build

Build with Theos on macOS, Linux, or WSL. Set `THEOS` to the Theos checkout, then run:

```sh
make clean package
```

The package is written under `packages/`. The Makefile includes `arm64` and `arm64e` slices and targets iOS 15 or later. No Theos toolchain is configured in this Windows workspace, so the package has not been built here.

If the app was injected with a custom bundle identifier, add that identifier to `GlowNavDiagnostics.plist` under `Filter.Bundles` before building. The runtime guard also accepts an app whose executable remains `Facebook`.

## Inject alongside Facebook and Glow

Use a decrypted Facebook IPA you already have. With cyan installed, pass both debs to its `-f` option (which accepts multiple files):

```sh
cyan -i facebook.ipa -o Glow_FB_navdiag.ipa -u -w -e -s \
  -f glow_fb.deb GlowNavDiagnostics.deb \
  -n Facebook -b com.facebook.Facebook
```

For the first reproduction, use the same Glow deb that your normal workflow selects and record its filename. The current workflow selects the `iphoneos-arm` asset; if you also compare against an explicit `iphoneos-arm64` or `iphoneos-arm64e` asset, keep those runs separate. That distinguishes package selection/loading from a Facebook UI-hook change.

Install/sign `Glow_FB_navdiag.ipa` through the same LiveContainer/SideStore path as the failing build. Launch Facebook, wait 15 seconds on the main screen, and tap several bottom tabs once. To compare with an older Facebook build, repeat with an older IPA already available to you; the diagnostic code and injection procedure are unchanged.

## Collect and return logs

Search device syslog for this exact prefix:

```text
[GlowNavDiag]
```

Useful record markers are:

```text
[GlowNavDiag] loaded
[GlowNavDiag] candidate navigation class:
[GlowNavDiag] controller
[GlowNavDiag] view
[GlowNavDiag] gesture on
[GlowNavDiag] bottom touch began
[GlowNavDiag] bottom inventory
```

Send back the log section from `[GlowNavDiag] loaded` through the last `bottom inventory` for each Facebook version. Include the Facebook version/build, iOS version, device model, injection route, and exact Glow deb filename. Keep the `class-scan` output and complete bottom-view/controller/touch paths. Redact any accessibility labels that contain account names or other personal text.

## Architecture and current limits

No runtime log has been collected yet, so A–G cannot be selected as observed facts. The diagnostic tests for these candidate categories without assuming one:

- UIKit `UITabBar` / `UITabBarController`, including subclasses or wrappers.
- Facebook-owned custom `UIView`, `UIControl`, collection, or stack-view layers.
- A decorative `UIVisualEffectView`/blur/material layer separate from the hit-tested tab control.
- ComponentKit/Litho-like, Swift/SwiftUI-hosted, or lazily loaded/reused components, if their runtime class names are present.

It also cannot safely enumerate private `UIGestureRecognizer` target/action registrations. The touch-path, recognizer delegate, UIControl actions, owner controller, and runtime method list provide the non-invasive evidence; a private-ivar probe is not included.

## Compatibility-layer decision

The upstream reports establish that settings access and tab hiding fail for at least some newer Facebook builds. They do not reveal whether Facebook replaced a `UITabBar`, wrapped it, or moved to a custom/recycled component. There is therefore no evidence-based private class or method to hook yet.

After collecting logs, keep any fix in a separate `GlowCompat.dylib`. Prefer a stable Facebook-owned parent controller/model only if the trace identifies its role and selection path. Use per-item view hooks only if the trace shows stable item instances; if touch paths show recycled views, target the proven owner/model instead. The present milestone stops at discovery.
