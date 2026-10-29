# ios-sweet-linux: the SWEET kernel on an Ubuntu runner

`.github/workflows/xnu-linux.yml` builds the kernel that
[`myh982516/ios-sweet-umi`](https://github.com/myh982516/ios-sweet-umi) builds on a macOS
runner, on `ubuntu-24.04` (what `ubuntu-latest` is today; 26.04 is not used because `libxml2`
has no candidate there). Same source tag, same patch series, same `ARM64_BOARD_CONFIG_SWEET`
configuration. The macOS pools have been queuing with zero steps since 2026-10-29 15:00.

## What is pinned

| what | value | why |
|---|---|---|
| xnu tag | `xnu-8796.141.3` (`1b191cb…`) | `MACOS_VERSION=13.5` in `xnu.yml` -> `distribution-macOS` `macos-135` `release.json` -> this tag |
| patches | `myh982516/ios-sweet-umi@2e60980` (149 `.patch` + 3 `.sh`) | the same series the macOS build applies, taken at a commit so a moving `main` cannot change a build |
| theos toolchain | `L1ghtmann/llvm-project@test-210562a` (`iOSToolchain-x86_64`) | cctools: `ld64`, `nm`, `strip`, `libtool` that understand Mach-O |
| SDK | `theos/sdks@master-146e41f` `iPhoneOS16.5.sdk` | the kernel compiles against iOS 16.5 |
| DriverKit headers | `MacOSX13.3.sdk` `Kernel.framework/Headers/DriverKit` | what Apple's closed `iig` would generate for the xnu-8796 family |

## The steps, and why each exists

1. **theos + toolchain + SDK.** Linux clang compiles; `ld64` from theos links Mach-O. Stock
   `ld` produces ELF and would fail at the first link.
2. **Patches at the pinned commit**, count checked (149). A different number means the pin is
   not what this workflow was written for.
3. **`linux/apply-xnu.sh`**: fetch the one xnu tag, check its SHA, run the `patches/*.sh` stage
   scripts from the tree root (they stage libpthread-514.100.2, BearSSL and hfs-627.100.6 into
   the tree), then apply **every** `*.patch` in name order. A patch that does not apply stops
   the run with the patch name, the files it touches and the per-hunk `patch --dry-run` result;
   the applied count must equal the file count. Nothing is skipped.
4. **`linux/setup-deps.sh --stage1`**: builds `mig` (a glibc port of Apple's bootstrap_cmds),
   `unifdef`, `tcsh` (XNU's `doconf` is a csh script), links the cctools next to them, and
   builds the SDK overlay: symlinks to `iPhoneOS16.5.sdk`, `usr/local/include/kernel` headers
   from libdispatch (firehose), `availability.pl`.
5. **`exporthdrs`**: the kernel's exported headers; the firehose library compiles against them.
6. **`linux/setup-deps.sh --stage2`**: `libfirehose_kernel.a` (libdispatch's os_log buffer code
   is open source but not in XNU; Apple links it from its internal SDK).
7. **`linux/build.sh -k`**: `make SDKROOT=iphoneos ARCH_CONFIGS=ARM64 MACHINE_CONFIGS=SWEET
   KERNEL_CONFIGS=DEVELOPMENT BUILD_WERROR=0 BUILD_LTO=0 DO_CTFMERGE=0 CC=xnu-clang …`, with
   `xnu-clang` forcing `-target arm64-apple-ios16.5` and `--ld-path=ld64` and dropping flags
   only Apple's clang knows. `-k` because `config/Makefile`'s export check can never pass (it
   asks for DriverKit RPC names that only iig output defines) and runs after the link.
8. **Check**: `built kernel at` in the log, the file exists, `file` says Mach-O arm64, and
   `umi_touch_init` (patch 0158) is in the symbol table. Then the kernel is uploaded as
   `kernel.development.sweet` with a `SHA256SUMS`.

## DriverKit (`iig`) on Linux

Apple's `iig` is closed source. The build needs two things from it:

- **headers** (`iokit/DriverKit/*.h`) — taken pre-generated from the macOS 13.3 SDK;
- **implementations** (`iokit/DriverKit/*.iig.cpp`) — not shipped anywhere. They are generated
  as stubs by `linux/gen-iig-stubs.py` from the linker's undefined-symbol list. Methods that
  the kernel itself defines are forwarded to their `_Impl`; the rest return
  `kIOReturnUnsupported`. This only affects DriverKit user-space RPC, which this kernel does
  not use; it does not affect the platform, display, timer or touch code.

## Local use

```sh
git clone https://github.com/myh120405/ios-sweet-linux && cd ios-sweet-linux
git init patches-src && git -C patches-src fetch --depth 1 https://github.com/myh982516/ios-sweet-umi.git 2e60980a9d8725da5fddca67ff9bdb1e85f2b43a && git -C patches-src checkout FETCH_HEAD
THEOS=$PWD/theos ...   # or let the workflow do it; see .github/workflows/xnu-linux.yml
./linux/apply-xnu.sh && ./linux/setup-deps.sh --stage1 && ./linux/build.sh exporthdrs && ./linux/setup-deps.sh --stage2
./linux/build.sh -k
```

## Credit

`linux/setup-deps.sh`, `linux/bin/xcrun`, `linux/bin/xnu-clang`, `linux/hostinc/hostcompat.h`
and `linux/gen-iig-stubs.py` are adapted from
[`ls9875/hackios-umi`](https://github.com/ls9875/hackios-umi) (`xnu-deps/`), which established
that XNU builds on `ubuntu-latest` with theos and stock clang. See `NOTICE`.
