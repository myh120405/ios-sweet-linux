#!/bin/bash
# make the kernel, and if the link is short of DriverKit symbols, let linux/iig-stubs.sh
# reconstruct them from the linker's list and link again.
#
# make's exit status is not the answer: config/Makefile's export check runs after the link and
# fails for any kernel, so the build is run with -k and judged by the kernel file and XNU's
# "built kernel at" line. Two rounds of stubs are possible:
#   1. link fails with undefined symbols -> generate every wrapper as kIOReturnUnsupported;
#   2. the kernel links -> regenerate, forwarding the wrappers whose _Impl the kernel has,
#      and relink. That is the shape the iig-generated code would have.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
LOG=$TOP/build.log
K=$XNU_SRC/BUILD/obj/${KERNEL_CONFIG}_ARM64_${MACHINE_CONFIG}/mach.$(echo "$KERNEL_CONFIG" | tr 'A-Z' 'a-z').$(echo "$MACHINE_CONFIG" | tr 'A-Z' 'a-z')
: >"$LOG"

run() {
	bash "$TOP/linux/build.sh" -k 2>&1 | tee -a "$LOG"
}

# The generated OSObject.iig.cpp is a *source* file in the tree; make compiles it into
# BUILD/obj/<config>/iokit/<KERNEL_CONFIG>/OSObject.iig.cpo. Copying the stub over the source and
# removing that object is what makes make compile it: the iig rule itself only runs when its .h
# is out of date, and deleting the .h would just regenerate an empty implementation.
install_stub() {
	local objdir=$XNU_SRC/BUILD/obj/${KERNEL_CONFIG}_ARM64_${MACHINE_CONFIG}
	cp "$TOP/linux/iig-impl/OSObject.iig.cpp" "$XNU_SRC/iokit/DriverKit/OSObject.iig.cpp"
	rm -f "$objdir"/iokit/*/OSObject.iig.cpo "$objdir"/iokit/OSObject.iig.cpo
	echo "build-with-iig: OSObject.iig.cpp replaced with the generated stubs; its object removed"
	echo "build-with-iig: tree file now $(wc -c <"$XNU_SRC/iokit/DriverKit/OSObject.iig.cpp") bytes, $(grep -c '__iig_stub_' "$XNU_SRC/iokit/DriverKit/OSObject.iig.cpp") stubs"
}

# After a rebuild, say whether the object that just got compiled really carries the stubs.
show_stub_objects() {
	local f n
	for f in "$XNU_SRC"/BUILD/obj/${KERNEL_CONFIG}_ARM64_${MACHINE_CONFIG}/iokit/*/OSObject.iig.cpo \
		"$XNU_SRC"/BUILD/obj/${KERNEL_CONFIG}_ARM64_${MACHINE_CONFIG}/iokit/OSObject.iig.cpo; do
		[ -f "$f" ] || continue
		n=$(deps/host/bin/nm "$f" 2>/dev/null | wc -l)
		echo "build-with-iig: object $f: $n symbols, $(deps/host/bin/nm "$f" 2>/dev/null | grep -c 'IOEventLink') IOEventLink, $(deps/host/bin/nm "$f" 2>/dev/null | grep -c 'IOUserServer') IOUserServer"
	done
}

echo "build-with-iig: kernel will be $K"
run
for attempt in 1 2 3; do
	[ -s "$K" ] && break
	if ! grep -q 'Undefined symbols' "$LOG"; then
		echo "build-with-iig: no kernel and the linker did not report undefined symbols; see $LOG"
		exit 1
	fi
	echo "build-with-iig: generating DriverKit stubs from $LOG (attempt $attempt)"
	bash "$TOP/linux/iig-stubs.sh" "$LOG" || exit 1
	install_stub
	run
	show_stub_objects
done
[ -s "$K" ] || { echo "build-with-iig: still no kernel after $attempt stub rounds; see $LOG"; exit 1; }

# second pass: with the kernel's own symbols known, forward the wrappers that have an _Impl
if deps/host/bin/nm -n "$K" >"$TOP/kernel.syms" 2>/dev/null && [ -s "$TOP/kernel.syms" ]; then
	before=$(sha256sum "$TOP/linux/iig-impl/OSObject.iig.cpp" 2>/dev/null | cut -d' ' -f1)
	bash "$TOP/linux/iig-stubs.sh" "$LOG" "$TOP/kernel.syms" || true
	after=$(sha256sum "$TOP/linux/iig-impl/OSObject.iig.cpp" 2>/dev/null | cut -d' ' -f1)
	if [ "$before" != "$after" ]; then
		echo "build-with-iig: relinking with the wrappers that forward to their _Impl"
		install_stub
		run
	fi
fi

grep -q 'built kernel at' "$LOG" || { echo "build-with-iig: XNU never printed 'built kernel at'"; exit 1; }
grep 'built kernel at' "$LOG" | tail -1
ls -la "$K"
