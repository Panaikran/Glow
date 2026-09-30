# GlowNavDiagnostics

Standalone, read-only diagnostic for Facebook 580's legacy and floating bottom navigation. It does not modify Glow's implementation, Facebook views, or gesture settings.

## What it records

- The active `FBTabBar` or `FBFloatingTabBar`, its controller, and visible tab items.
- Filtered instance-method inventories for the two bar classes, two known item classes, `FBTabBarViewController`, and their superclass chains. There is no global class or selector scan.
- Calls to candidate long-press, gesture, menu, context, shortcut, action, and settings methods. Only Facebook-app-owned methods with `void` return and up to three Objective-C object arguments are wrapped; all original arguments and return behavior are forwarded unchanged. Other signatures are listed but not hooked.
- A one-second post-`.began` window. The diagnostic temporarily observes `UIViewController`'s direct `presentViewController:animated:completion:` implementation, if its runtime signature matches, and restores the implementation after the window.
- Whether `Glow.dylib` is loaded and Objective-C classes defined by that image only.

The diagnostic does not intercept `isKindOfClass:` because that would require broad `NSObject` tracing. It therefore cannot prove whether Facebook performs a legacy class check. Presentation tracing covers calls dispatched through `UIViewController`'s direct implementation; an override that does not call `super`, or a non-view-controller menu API, may be missed. Related candidate selector calls may still appear in `[CALL]` lines.

## Build

Build the standalone arm64 library from an ext4 WSL directory with the existing Theos installation:

```sh
THEOS=/home/panaikran/theos make -C /path/on/ext4/GlowNavDiagnostics ARCHS=arm64 FINALPACKAGE=1 clean all
```

The project uses `library.mk`, Objective-C runtime APIs, and a C constructor. It targets iOS 15.0 and has no Logos or Substrate linkage. The output is a raw dylib for direct LiveContainer loading; no `.deb` is produced.

## Facebook 580 test procedure

1. In LiveContainer, assign Facebook 580 to the tweak folder containing both **Glow** and **GlowNavDiagnostics_0.3.0_arm64.dylib**.
2. Confirm the floating navbar is active.
3. Start filtered logging:

   ```sh
   idevicesyslog --match '\[GlowNavDiag\]' | tee GlowNavDiag-facebook580.log
   ```

4. Launch Facebook 580.
5. Wait for `[GlowNavDiag] navbar mode=floating`.
6. Press and hold **Home** until `[GlowNavDiag][HANDLER]` reports `trigger=controller-longpress->began`. Hold for about 1.5–2 seconds to let the observation window complete.
7. Release.
8. Stop logging.
9. Optionally repeat once on **Reels**.

Send back the `[METHOD]` and `[GLOW]` lines, the navbar and recognizer inventory, and all `[HANDLER]`, `[CALL]`, and `[PRESENT]` lines for each hold. Note the approximate haptic timing separately if one occurs; this diagnostic does not infer its source.
