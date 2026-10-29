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
| SDK | `MacOSX13.3.sdk` (joseluisq/macosx-sdks `13.3`) | the macOS build compiles with `SDKROOT=macosx`; that is what makes `XNU_TARGET_OS_OSX` / `TARGET_OS_IPHONE` — and the HFS, DriverKit and kext headers — what the patch series expects. 13.3 is the published SDK closest to xnu-8796.141.3 |

## The steps, and why each exists

1. **theos + toolchain + macOS SDK.** Linux clang compiles; `ld64` from theos links Mach-O.
   Stock `ld` produces ELF and would fail at the first link.
2. **Patches at the pinned commit**, count checked (149). A different number means the pin is
   not what this workflow was written for.
3. **`linux/apply-xnu.sh`**: fetch the one xnu tag, check its SHA, run the `patches/*.sh` stage
   scripts from the tree root (they stage libpthread-514.100.2, BearSSL and hfs-627.100.6 into
   the tree), then apply **every** `*.patch` in name order. A patch that does not apply stops
   the run with the patch name, the files it touches and the per-hunk `patch --dry-run` result;
   the applied count must equal the file count. Nothing is skipped.
4. **`linux/setup-deps.sh --stage1`**: builds `mig` (a glibc port of Apple's bootstrap_cmds),
   `unifdef`, `tcsh` (XNU's `doconf` is a csh script), links the cctools next to them, and
   builds the SDK overlay: symlinks to `MacOSX13.3.sdk`, `usr/local/include/kernel` headers
   from libdispatch (firehose), `availability.pl`.
5. **`exporthdrs`**: the kernel's exported headers; the firehose library compiles against them.
6. **`linux/setup-deps.sh --stage2`**: `libfirehose_kernel.a` (libdispatch's os_log buffer code
   is open source but not in XNU; Apple links it from its internal SDK).
7. **`linux/build.sh -k`**: `make SDKROOT=macosx ARCH_CONFIGS=ARM64 MACHINE_CONFIGS=SWEET
   KERNEL_CONFIGS=DEVELOPMENT BUILD_WERROR=0 BUILD_LTO=0 DO_CTFMERGE=0 CC=xnu-clang …`, with
   `xnu-clang` forcing `-target arm64-apple-macos13.3` and `--ld-path=ld64` and dropping flags
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

## Fixes on top of the series (`linux/fixes/`)

These do not change `xnu/patches`; they are applied after the series and reported so they can
be folded into it:

- `0001-kalloc-stock-clang-void-ptr.patch` — `osfmk/kern/kalloc.h`,
  `KALLOC_TYPE_IS_COMPATIBLE_PTR` (the `_Static_assert` in `KALLOC_TYPE_ASSERT_COMPATIBLE_POINTER`,
  used by `IOFreeType`/`IOMallocType` in `iokit/IOKit/IOLib.h`): it dereferences the pointer it
  checks, which for a `void *` is the warning `-Wvoid-ptr-dereference` on Apple's clang but a
  hard error on stock clang. With `XNU_NO_TYPE_BUILTINS` (`linux/hostinc/xnu_clang_compat.h`)
  there is no signature to compare, so the check becomes `1`.
- `0002-sweet-rpmh-vreg-set-prototype.patch` — `bsd/dev/sweet_rpmh.c`: 0161 (fixed upstream in
  `ea725494`) writes `sweet_rpmh_vreg_enable()` calling `sweet_rpmh_vreg_set()` before its
  definition. Apple's clang 15 only warns about the implicit declaration; stock clang 18 makes
  it an error. One forward declaration fixes it; it belongs in 0161.
- `0003-corecrypto-sha256-asm-operands.patch` — `osfmk/arm64/corecrypto/sha256_compress_arm64.s`:
  the SHA256 instructions are written with bare register numbers (`SHA256SU0 0, 1`), which
  Apple's assembler accepts and stock clang's does not (`invalid operand for instruction`).
  Rewritten to the canonical forms (`sha256su0 v0.4s, v1.4s`, `sha256h q18, q19, v4.4s`).

The series itself is taken at the pinned commit and applied unmodified, except that CRLF line
endings are stripped from a temporary copy (`0161`/`0162` were committed with CRLF, which
`git apply` cannot match on Linux). That is a byte-level normalisation, not a content change.

The newest patches (0158-0162) have never been through a compiler: the last successful macOS
run was `40831765215` at `b57ab716`, before they were added. This Linux route is therefore the
first build of the current series, and the fixes above are what it found.
