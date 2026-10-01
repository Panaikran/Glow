# GlowCompat 0.1.0

Standalone LiveContainer adapter for Facebook 580's `FBFloatingTabBar.FBFloatingTabBarItemView`. It validates Glow's directly installed legacy context-menu method at runtime, then forwards UIKit's context-menu request to that Glow IMP with the real floating item as `self`. It does not add gestures or change Facebook's existing gesture recognizers.

## Build

Build from an ext4 WSL working directory with the existing Theos installation:

```sh
THEOS=/home/panaikran/theos make ARCHS=arm64 FINALPACKAGE=1 clean all
```

The output is a raw arm64 dylib with an iOS 15.0 deployment target. The project uses `library.mk` and has no Logos, CydiaSubstrate, or libsubstrate dependency.

## Device test

Use Facebook 580 with the exact Glow 1.3.1 dylib already embedded at `Facebook.app/Frameworks/Glow.dylib`. In LiveContainer, enable only `GlowCompat_0.1.0_arm64.dylib` as the added tweak; GlowNavDiagnostics is not required.

In PowerShell, start filtered logging:

```powershell
.\idevicesyslog.exe --match GlowCompat |
    Tee-Object -FilePath GlowCompat-facebook580-0.1.log
```

1. Fully terminate Facebook.
2. Enable only GlowCompat in the LiveContainer tweak folder.
3. Start the logger and launch Facebook.
4. Confirm the floating navbar remains visible and visually unchanged; wait for `legacy context IMP validated` and attachment lines for the five floating tabs.
5. Long-press Home and check whether the context menu and **Glow settings** appear.
6. If present, open Glow settings and verify the settings controller opens and dismisses.
7. Repeat once on Reels; confirm ordinary tab taps still switch tabs.
8. Navigate away and back to exercise navbar item recreation; confirm Facebook does not crash, then stop logging.

Successful menu presentation and opening Glow settings still require on-device verification.
