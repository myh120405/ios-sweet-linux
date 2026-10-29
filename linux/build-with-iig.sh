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

# iokit/DriverKit/Makefile's rule is
#     %.h : %.iig
#         $(IIG) --def $< --header $@ --impl $(patsubst %.h,%.iig.cpp,$@) ...
# so the implementation is written next to whatever .h it generated. In this build the generated
# headers end up in BUILD/obj/<config>/iokit/<KERNEL_CONFIG>/DriverKit/, one level below the
# object (BUILD/obj/<config>/iokit/<KERNEL_CONFIG>/OSObject.iig.cpo). Steps, in this order:
#   1. drop empty implementations an earlier iig run left behind (before copying the stub);
#   2. write the stub next to each generated OSObject.h and in the source tree, and touch it;
#   3. remove every DriverKit object in that layer so make compiles the stubs again.
install_stub() {
	local stub=$TOP/linux/iig-impl/OSObject.iig.cpp hdr d
	find "$XNU_SRC/BUILD/obj" -name '*.iig.cpp' -size -200c -print -delete 2>/dev/null |
		sed 's/^/build-with-iig: removed empty /'
	cp "$stub" "$XNU_SRC/iokit/DriverKit/OSObject.iig.cpp"
	touch "$XNU_SRC/iokit/DriverKit/OSObject.iig.cpp"
	while IFS= read -r hdr; do
		d=$(dirname "$hdr")
		cp "$stub" "$d/OSObject.iig.cpp"
		touch "$d/OSObject.iig.cpp"
		echo "build-with-iig: stub -> $d/OSObject.iig.cpp (next to its generated header)"
	done < <(find "$XNU_SRC/BUILD/obj" -name 'OSObject.h' 2>/dev/null)
	local objroot=$XNU_SRC/BUILD/obj/${KERNEL_CONFIG}_ARM64_${MACHINE_CONFIG} gd
	for gd in "$objroot/iokit/${KERNEL_CONFIG}" "$objroot/iokit"; do
		[ -d "$gd" ] || continue
		rm -f "$gd"/*.iig.cpo
		echo "build-with-iig: removed $gd/*.iig.cpo"
	done
	echo "build-with-iig: tree file now $(wc -c <"$XNU_SRC/iokit/DriverKit/OSObject.iig.cpp") bytes, $(grep -c '__iig_stub_' "$XNU_SRC/iokit/DriverKit/OSObject.iig.cpp") stubs"
}

# After a rebuild, say whether the objects that got compiled really carry the stubs.
show_stub_objects() {
	local f n missing=0
	for f in $(find "$XNU_SRC/BUILD/obj" -name '*.iig.cpp' 2>/dev/null); do
		n=$(grep -c 'kIOReturnUnsupported\|_Impl' "$f" || true)
		[ "$n" -gt 0 ] || { echo "STUB MISSING: $f"; missing=$((missing + 1)); }
	done
	echo "build-with-iig: stub files with content: $(find "$XNU_SRC/BUILD/obj" -name '*.iig.cpp' -exec grep -l 'kIOReturnUnsupported\|_Impl' {} + 2>/dev/null | wc -l), missing: $missing"
	for f in "$XNU_SRC"/BUILD/obj/${KERNEL_CONFIG}_ARM64_${MACHINE_CONFIG}/iokit/*/OSObject.iig.cpo \
		"$XNU_SRC"/BUILD/obj/${KERNEL_CONFIG}_ARM64_${MACHINE_CONFIG}/iokit/OSObject.iig.cpo; do
		[ -f "$f" ] || continue
		n=$(deps/host/bin/nm -g "$f" 2>/dev/null | wc -l)
		echo "build-with-iig: object $f: $n global symbols, $(deps/host/bin/nm "$f" 2>/dev/null | grep -c 'IOEventLink') IOEventLink, $(deps/host/bin/nm "$f" 2>/dev/null | grep -c 'IOUserServer') IOUserServer"
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
