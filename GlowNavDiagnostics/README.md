# GlowNavDiagnostics

Standalone, passive runtime probe for Facebook 580 and Glow 1.3.1. It inspects only named navbar and Glow classes. It does not add or remove interactions, invoke Glow methods, or change Facebook gesture behavior.

## Runtime evidence

- Resolves `FBTabBarItemDefaultView`'s `contextMenuInteraction:configurationForMenuAtLocation:` implementation, its direct owner, type encoding, IMP image, and symbol using Objective-C runtime APIs and `dladdr`. It never calls the IMP.
- Logs the context-menu IMP and Glow's two confirmed `layoutSubviews` patch IMPs with their image base/offset, dyld image index/header/slide, preferred `__TEXT.vmaddr`, and runtime `__TEXT` base.
- Inventories filtered instance and class methods only on the six named Glow classes. It separately reports direct methods on `FBTabBar`, `FBTabBarViewController`, and `FBTabBarItemDefaultView` whose IMP image is `Glow.dylib`.
- Reports `UIContextMenuInteractionDelegate` conformance for those Glow classes and the legacy tab item.
- Inspects the public `UIView.interactions` collection on visible navbar items and records context-menu delegate class/address when present.
- Passively forwards `UIContextMenuInteraction initWithDelegate:` and `UIView addInteraction:` unchanged. Logs creation when its delegate or caller is Glow/navbar-related, and attachment only for context-menu interactions on the four named navbar classes.

The probe does not use a global class scan, private KVC, unknown ivars, stack walking, or method invocation on Glow classes. `dladdr` symbol strings are logged only as hints; use IMP addresses and Mach-O mappings as evidence.

## Build

Build the standalone arm64 library from an ext4 WSL directory with the existing Theos installation:

```sh
THEOS=/home/panaikran/theos make -C /path/on/ext4/GlowNavDiagnostics ARCHS=arm64 FINALPACKAGE=1 clean all
```

The project uses `library.mk`, targets iOS 15.0, and has no Logos or Substrate linkage. Build arm64 with `FINALPACKAGE=1`; the raw LiveContainer dylib is `artifacts/GlowNavDiagnostics_0.5.0_arm64.dylib`. No `.deb` is produced.

## Facebook 580 test procedure

Device setup: use Facebook 580 with the exact tested Glow binary embedded at `Facebook.app/Frameworks/Glow.dylib`. In LiveContainer, enable only **GlowNavDiagnostics_0.5.0_arm64.dylib** in the tweak folder.

In PowerShell, start logging:

   ```powershell
   .\idevicesyslog.exe --match GlowNavDiag |
       Tee-Object -FilePath GlowNavDiag-facebook580-0.5.log
   ```

1. Fully terminate Facebook.
2. Start the logger.
3. Launch Facebook.
4. Wait until the `[LEGACY-IMP-MAP]` lines appear. No navbar interaction is required.
5. Stop logging.

Send the short log containing `[LEGACY-IMP-MAP]` and `[GLOW-IMP-MAP]` lines. The legacy IMP address will be mapped to the local Mach-O before function-level disassembly; no function analysis is performed by the diagnostic.
