# Common environment for the Linux build. Source this; do not run it.
# Everything is found relative to the repository, so a checkout is all a runner needs.
TOP=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export TOP

# The xnu release the macOS build uses: .github/workflows/xnu.yml builds with
# MACOS_VERSION=13.5, and blacktop/darwin-xnu-build maps 13.5 to release.json macos-135,
# whose xnu project tag is xnu-8796.141.3 (Apple's tag, commit checked below).
export XNU_TAG=${XNU_TAG:-xnu-8796.141.3}
export XNU_TAG_SHA=${XNU_TAG_SHA:-1b191cb58250d0705d8a51287127505aa4bc0789}
export XNU_SRC=${XNU_SRC:-$TOP/xnu-src/$XNU_TAG}

# theos: cctools (ld64, nm, strip, libtool...) and the iOS SDK the kernel is compiled against
export THEOS=${THEOS:-$TOP/theos}
export CCTOOLS=$THEOS/toolchain/linux/iphone/bin
export IOS_SDK=$THEOS/sdks/iPhoneOS16.5.sdk

# what this repository fetches and builds (host tools, vendor sources, the SDK overlay)
export DEPS=${DEPS:-$TOP/deps}
export XNU_SDK_PATH=$DEPS/sdk/iPhoneOS16.5.xnu.sdk
export XNU_SDK_VERSION=16.5
export XNU_PLATFORM_PATH=$DEPS/sdk/Platforms/iPhoneOS.platform

# what the macOS workflow passes as env to darwin-xnu-build's patch stage
export MACHINE_CONFIG=${MACHINE_CONFIG:-SWEET}
export MACOS_VERSION=${MACOS_VERSION:-13.5}
export KERNEL_CONFIG=${KERNEL_CONFIG:-DEVELOPMENT}

# patches come from the kernel repository (default: the pinned commit of ours)
export PATCHES_DIR=${PATCHES_DIR:-$TOP/patches-src/xnu/patches}

export PATH=$TOP/linux/bin:$DEPS/host/bin:$PATH
