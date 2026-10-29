#!/bin/bash
# Build the kernel with the same configuration the macOS workflow uses
# (ARM64 / SWEET / DEVELOPMENT), on Linux. Extra arguments go to make, e.g. `exporthdrs`.
#
# The build is expected to end with make's exit status 2 and the kernel already linked: the
# export check in config/Makefile runs after the link and cannot pass for any kernel (it
# asks for DriverKit RPC names that only iig output defines). What counts is the "built
# kernel at" line and the file itself; the workflow checks both.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
cd "$XNU_SRC" || exit 1
JOBS=${JOBS:-$(nproc)}
MACHINE=${MACHINE_CONFIG:-SWEET}
lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
echo "build: xnu=$XNU_SRC machine=$MACHINE config=$KERNEL_CONFIG jobs=$JOBS"
exec make \
	SDKROOT=iphoneos ARCH_CONFIGS=ARM64 MACHINE_CONFIGS="$MACHINE" KERNEL_CONFIGS="$KERNEL_CONFIG" \
	ARCH_STRING_FOR_CURRENT_MACHINE_CONFIG=arm64 BUILD_WERROR=0 BUILD_LTO=0 DO_CTFMERGE=0 \
	HOST_CC="clang -include $TOP/linux/hostinc/hostcompat.h -I$TOP/linux/hostinc -Wno-unused-command-line-argument -Wno-error=implicit-function-declaration" \
	HOST_FLEX=flex HOST_BISON=bison HOST_GM4=m4 \
	CC=xnu-clang CXX=xnu-clang++ LOGCOLORS=n \
	-j"$JOBS" "$@"
