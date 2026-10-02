# Glow late loader

This plain-C initializer is embedded in Facebook's existing arm64 executable as `__TEXT,__glow_code` plus one `__TEXT,__glow_init` `S_INIT_FUNC_OFFSETS` entry. It waits 500 ms, confirms `Glow.dylib` is mapped, resolves the Facebook image with `dladdr`, then loads the sibling `Frameworks/GlowCompat.dylib` with `RTLD_NOW | RTLD_LOCAL`.

GlowCompat must stay out of Facebook's launch load commands. In the tested LiveContainer/Facebook 580 setup, any second launch-loaded dylib caused Glow's initializer to abort; the internal reason remains unknown. `LC_ROUTINES_64` did not execute in that setup. The patcher therefore adds two section records in verified load-command padding and uses the already-proven init-offset mechanism, while leaving Facebook's original initializer table untouched.

The production object has no Objective-C, Foundation, UIKit, or C++ runtime dependency. It resolves APIs through the existing Facebook `dlsym` stub. `dladdr` is used because `_NSGetExecutablePath()` identifies LiveContainer, not the embedded Facebook image.

Build an arm64, iOS 15 object on macOS with:

```sh
xcrun --sdk iphoneos clang -target arm64-apple-ios15.0 -c -Oz -Wall -Wextra -Werror \
  -ffreestanding -fno-pic -fno-stack-protector -fno-builtin \
  -fno-unwind-tables -fno-asynchronous-unwind-tables \
  GlowLateLoader/GlowLateLoader.c -o GlowLateLoader.o
```

`GLOW_LATE_LOADER_DIAGNOSTICS` defaults to `0`. A diagnostic-only build can define it as `1` to write the existing small stage/error files under `TMPDIR`; the release workflow leaves those side effects compiled out.
