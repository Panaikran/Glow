# GlowNavDiagnostics 0.6.0

Standalone, read-only runtime probe for Facebook 580 with Glow 1.3.1. It records runtime ownership and signatures for `_viewControllerForAncestor`, waits for real navbar item views to finish layout, then invokes the selector once per actual item only when it has an object return and no explicit arguments. The query is exception-caught and does not present a controller or change Facebook behavior.

## Build

Build from an ext4 WSL directory with the existing Theos installation:

```sh
THEOS=/home/panaikran/theos make ARCHS=arm64 FINALPACKAGE=1 clean all
```

The project uses `library.mk`, arm64, an iOS 15.0 deployment target, and no Logos or Substrate linkage. The raw LiveContainer artifact is `artifacts/GlowNavDiagnostics_0.6.0_arm64.dylib`; no `.deb` is produced.

## Device test

Use Facebook 580 with the exact tested Glow 1.3.1 dylib embedded at `Facebook.app/Frameworks/Glow.dylib`. In LiveContainer, enable only **GlowNavDiagnostics_0.6.0_arm64.dylib** in the extra tweak folder.

In PowerShell, start filtered logging:

```powershell
.\idevicesyslog.exe --match GlowNavDiag |
    Tee-Object -FilePath GlowNavDiag-facebook580-0.6.log
```

1. Fully terminate Facebook.
2. Start the logger.
3. Launch Facebook and wait for the floating navbar to appear.
4. Wait for item frames to become non-zero and for `[GlowNavDiag][ANCESTOR-RESULT]` lines.
5. No long press or other interaction is required.
6. Stop logging.

Send the `[GlowNavDiag][ANCESTOR-SELECTOR]` and `[GlowNavDiag][ANCESTOR-RESULT]` lines. The selector report includes class-chain owner, method encoding, IMP, and IMP image; item results include the returned object class, whether it is a `UIViewController`, and whether its view is already in a window. The probe does not force-load a controller's view.
