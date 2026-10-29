#!/bin/bash
# Generate the DriverKit implementation stubs the kernel link needs.
#
# Apple's iig is closed source: it turns iokit/DriverKit/<Class>.iig into the RPC marshalling
# that is compiled into the kernel. There is no open implementation, so the wrappers are
# reconstructed from the linker's own list of undefined symbols:
#   * a method the kernel already implements (a *_Impl symbol that exists) is forwarded to it;
#   * everything else (RPC dispatch, user-space-only methods) returns kIOReturnUnsupported.
# Only DriverKit user-space RPC is affected; the platform, display, timer and touch code does
# not go through these wrappers.
#
# usage: linux/iig-stubs.sh <build.log> [kernel.syms]
#   kernel.syms is `nm -n` of a kernel that linked: with it, the wrappers that can be
#   forwarded are. Without it every wrapper is a stub (the first pass).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
LOG=${1:?usage: iig-stubs.sh <build.log> [kernel.syms]}
SYMS=${2:-}
OUT=$TOP/linux/iig-impl
mkdir -p "$OUT"

python3 - "$LOG" "$OUT/undefined.txt" <<'PY'
import re, sys
log, out = sys.argv[1], sys.argv[2]
syms, inblock = [], False
for line in open(log, errors='replace'):
    s = line.rstrip('\n')
    if s.startswith('Undefined symbols'):
        inblock = True
        continue
    if inblock:
        m = re.match(r'\s+"([^"]+)"', s)
        if m:
            syms.append(m.group(1))
            continue
        if not s.strip() or s.startswith('ld:'):
            inblock = False
syms = list(dict.fromkeys(syms))
open(out, 'w').write('\n'.join(syms) + '\n')
print('iig-stubs: %d undefined symbols in %s' % (len(syms), log))
PY

before=$(sha256sum "$OUT/OSObject.iig.cpp" 2>/dev/null | cut -d' ' -f1 || true)
python3 "$TOP/linux/gen-iig-stubs.py" "$OUT/undefined.txt" "$OUT" $SYMS
after=$(sha256sum "$OUT/OSObject.iig.cpp" | cut -d' ' -f1)
if [ "$before" = "$after" ]; then echo "iig-stubs: no change"; else echo "iig-stubs: regenerated $OUT/OSObject.iig.cpp"; fi
