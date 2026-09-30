# GlowNavDiagnostics

Standalone, read-only gesture-state diagnostic for Facebook 580's bottom navigation. It does not modify Glow, Facebook views, or gesture behavior.

## Scope

The existing legacy baseline is:

```text
FBTabBarAndContentViewController
  -> FBTabBarViewController
       -> FBTabBar
            -> FBTabBarItemDefaultView
```

The captured floating-bar implementation is:

```text
FBTabBarAndContentViewController
  -> FBTabBarFloatableContainerView
       -> FBFloatingTabBar
            -> UIStackView
                 -> FBFloatingTabBar.FBFloatingTabBarItemView
```

The logical `tab-bar-item-*` accessibility identifiers are stable across both implementations. The diagnostic checks for `FBTabBar` and `FBFloatingTabBar` under `FBTabBarViewController`, and scans only that bar's bounded subtree for visible tab items.

There is no global Objective-C class enumeration or broad hierarchy dump. The diagnostic logs one active-navbar summary, visible tab-item summaries, and long-press recognizers attached directly to the active bar. During a tab touch, it additionally observes long-press recognizers attached directly to that item.

## Gesture observation

`UIApplication sendEvent:` is observed only in the Facebook process. Touches are forwarded unchanged. For a touch resolving to a known tab item under a known bar, the diagnostic records recognizer states immediately and polls every 40 ms while that touch remains active (up to 10 seconds). It also samples near 0, 250, 500, 800, 1000, 1500, and 3000 ms. State output uses names, not enum integers. UIKit's `Recognized` value aliases `Ended`, so it is reported as `ended`.

Recognizer observation is passive polling. The diagnostic does not use KVO, swizzle recognizers, change delegates or gesture settings, add recognizers, or inspect haptics. If a haptic occurs, note its approximate timing separately so it can be compared with the state-transition timestamps.

## Build

Build the standalone arm64 library from an ext4 WSL directory with the existing Theos installation:

```sh
THEOS=/home/panaikran/theos make -C /path/on/ext4/GlowNavDiagnostics ARCHS=arm64 FINALPACKAGE=1 clean all
```

The project uses `library.mk`, Objective-C runtime APIs, and a C constructor. It targets iOS 15.0 and has no Logos or Substrate linkage. Load the generated raw `GlowNavDiagnostics.dylib` directly in LiveContainer. No `.deb` is produced.

## Facebook 580 test procedure

1. In LiveContainer, enable **only GlowNavDiagnostics** for the Facebook 580 app.
2. Connect the device and start filtered logging:

   ```sh
   idevicesyslog --match '\[GlowNavDiag\]' | tee GlowNavDiag-facebook580.log
   ```

3. Launch Facebook 580.
4. Confirm the floating navbar is visible.
5. Press and hold **Home** for at least 3 seconds without moving your finger.
6. Release. If a haptic occurs, note approximately when it happened during the hold.
7. Optionally repeat once on **Reels**.
8. Stop logging.

Do not reproduce the legacy navbar for this run. Send the lines from `[GlowNavDiag] loaded` through each `[GlowNavDiag] hold complete`, including the navbar/item inventory, recognizer lines, samples, transitions, and hold results.

## Output markers

```text
[GlowNavDiag] navbar mode=floating ...
[GlowNavDiag] item class=... accessibilityIdentifier=tab-bar-item-...
[GlowNavDiag] recognizer label=floating-bar-longpress ...
[GlowNavDiag] recognizer label=controller-longpress ...
[GlowNavDiag] hold begin tab=Home ...
[GlowNavDiag] hold sample tab=Home elapsed=0.80 floating=began controller=possible
[GlowNavDiag] hold transition tab=Home elapsed=... recognizer=controller-longpress ...
[GlowNavDiag] hold complete tab=Home duration=...
[GlowNavDiag] hold result recognizer=controller-longpress final=failed reached=failed
```

The logs can establish whether the controller recognizer begins, fails, or cancels during the same physical hold and whether behavior differs by tab. They cannot attribute a haptic source; only timing correlation can be recorded from this diagnostic.
