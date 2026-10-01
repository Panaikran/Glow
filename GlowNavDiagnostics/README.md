# GlowNavDiagnostics

Standalone, passive runtime probe for Facebook 580 and Glow 1.3.1. It inspects only named navbar and Glow classes. It does not add or remove interactions, invoke Glow methods, or change Facebook gesture behavior.

## Runtime evidence

- Resolves `FBTabBarItemDefaultView`'s `contextMenuInteraction:configurationForMenuAtLocation:` implementation, its direct owner, type encoding, IMP image, and symbol using Objective-C runtime APIs and `dladdr`. It never calls the IMP.
- Inventories filtered instance and class methods only on the six named Glow classes. It separately reports direct methods on `FBTabBar`, `FBTabBarViewController`, and `FBTabBarItemDefaultView` whose IMP image is `Glow.dylib`.
- Reports `UIContextMenuInteractionDelegate` conformance for those Glow classes and the legacy tab item.
- Inspects the public `UIView.interactions` collection on visible navbar items and records context-menu delegate class/address when present.
- Passively forwards `UIContextMenuInteraction initWithDelegate:` and `UIView addInteraction:` unchanged. Logs creation when its delegate or caller is Glow/navbar-related, and attachment only for context-menu interactions on the four named navbar classes.

The probe does not use a global class scan, private KVC, unknown ivars, stack walking, or method invocation on Glow classes. If no legacy item exists in Facebook 580, the legacy item's naturally occurring attachment can still be observed through the narrow `addInteraction:` observer, but an interaction that was attached before the probe loaded and exists outside the visible navbar will not be discovered.

## Build

Build the standalone arm64 library from an ext4 WSL directory with the existing Theos installation:

```sh
THEOS=/home/panaikran/theos make -C /path/on/ext4/GlowNavDiagnostics ARCHS=arm64 FINALPACKAGE=1 clean all
```

The project uses `library.mk`, targets iOS 15.0, and has no Logos or Substrate linkage. The output is a raw dylib for direct LiveContainer loading; no `.deb` is produced.

## Facebook 580 test procedure

1. Use the Facebook 580 IPA with Glow already embedded at `Facebook.app/Frameworks/Glow.dylib`.
2. In LiveContainer, enable only **GlowNavDiagnostics_0.4.0_arm64.dylib** from the tweak folder.
3. Start filtered logging:

   ```sh
   idevicesyslog --match '\[GlowNavDiag\]' | tee GlowNavDiag-facebook580-0.4.log
   ```

4. Fully terminate Facebook, then launch it.
5. Wait for navbar initialization and let the app sit for about five seconds. Do not long-press initially.
6. Optionally tap between Home and Reels once.
7. Optionally long-press Home once afterward.
8. Stop logging.

Send the `[LEGACY-IMP]`, `[GLOW-METHOD]`, `[GLOW-PATCH]`, `[PROTOCOL]`, `[INTERACTION]`, `[CTX-CREATE]`, and `[CTX-ATTACH]` lines, plus the `[GLOW]` image line and navbar/item inventory. This is runtime metadata only; whether the standalone dylib loads in LiveContainer and which interactions Facebook creates still require device verification.
