#!/usr/bin/env bash
# Plan step 2: can the lapis guest mount a virtio-fs share inside shared storage?
# Static checks only (no boot): the kernel config, and the vendor SELinux policy.
#
#   dev/probe-guest.sh     (run after prepare.sh; needs python3, lz4, erofs-utils, setools)
# Env: GBOS_STATE (default: the repository), GBOS_RAW.
# Exit 0 = virtio-fs path; 1 = USB fallback; 2 = could not probe.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/lib.sh"
RAW="${GBOS_RAW:-$STATE/android-desktop_signed_recovery_image.bin}"
KERNEL="$STATE/firmware/kernel"
for f in "$RAW" "$KERNEL" "$STATE/firmware/gpt.json"; do
  [ -f "$f" ] || { echo "missing $f; run ./prepare.sh first" >&2; exit 2; }
done
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# (a) kernel: the bzImage payload is LZ4 (legacy frame); its config is embedded (IKCONFIG).
python3 -I - "$KERNEL" "$TMP/vmlinux" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
i = d.find(b'\x02\x21\x4c\x18')
if i < 0:
    sys.exit('kernel payload is not LZ4; extend the probe for this compression')
open(sys.argv[2] + '.lz4', 'wb').write(d[i:])
PY
lz4 -dc "$TMP/vmlinux.lz4" > "$TMP/vmlinux" 2>/dev/null || true
python3 -I - "$TMP/vmlinux" "$TMP/kconfig" <<'PY'
import gzip, sys
d = open(sys.argv[1], 'rb').read()
i = d.find(b'IKCFG_ST')
if i < 0:
    sys.exit('kernel has no embedded config (IKCONFIG)')
open(sys.argv[2], 'w').write(gzip.decompress(d[i + 8:d.find(b'IKCFG_ED', i)]).decode())
PY
kconf() { grep -E "^(# )?$1[= ]" "$TMP/kconfig" || echo "$1 absent"; }
echo "== (a) kernel"
for k in CONFIG_VIRTIO_FS CONFIG_FUSE_FS CONFIG_SND_VIRTIO CONFIG_USB_STORAGE CONFIG_EXFAT_FS; do kconf "$k"; done
KERNEL_OK=0; grep -qx 'CONFIG_VIRTIO_FS=y' "$TMP/kconfig" && KERNEL_OK=1

# (b) policy: the precompiled policy init loads, from vendor_a in super.
echo "== (b) vendor SELinux policy"
python3 -I - "$HERE" "$RAW" "$STATE/firmware/gpt.json" "$TMP/sepolicy" <<'PY'
import json, subprocess, sys
sys.path.insert(0, sys.argv[1])
import lp_tools
raw, gpt, out = sys.argv[2], json.load(open(sys.argv[3])), sys.argv[4]
(off, _), = lp_tools.Super(raw, gpt['super'][0]).layout('vendor_a')
data = subprocess.run(['dump.erofs', f'--offset={off}', '--path=/etc/selinux/precompiled_sepolicy',
                       '--cat', raw], capture_output=True, check=True).stdout
open(out, 'wb').write(data)
print(f'vendor_a at {off}; precompiled_sepolicy {len(data)} bytes')
PY
P="$TMP/sepolicy"
echo "-- genfscon for virtiofs:"
GENFS=$(seinfo --genfscon "$P" | grep -w virtiofs || true)
echo "${GENFS:-(none)}"
VTYPE=$(printf '%s\n' "$GENFS" | grep -oE 'u:object_r:[a-z0-9_]+' | head -1 | cut -d: -f3 || true)
echo "virtiofs label: ${VTYPE:-(none: files would be unlabeled)}"
ALLOW() { sesearch -A -s "$1" -t "$2" -c "$3" -p "$4" "$P"; }
POLICY_OK=1
check() {  # check DESCRIPTION SRC TGT CLASS PERM
  local r; r=$(ALLOW "$2" "$3" "$4" "$5" || true)
  if [ -n "$r" ]; then echo "ok   $1"; else echo "MISS $1"; POLICY_OK=0; fi
}
TGT=${VTYPE:-unlabeled}
check "init may mount the virtiofs fs"               init "$TGT" filesystem mount
check "init may relabel from the virtiofs label"     init "$TGT" filesystem relabelfrom
check "init may relabel to media_rw_data_file"       init media_rw_data_file filesystem relabelto
check "media_rw_data_file may live on that fs"       media_rw_data_file media_rw_data_file filesystem associate
check "init may mount on media_rw_data_file dirs"    init media_rw_data_file dir mounton

echo "== result"
if [ "$KERNEL_OK" = 1 ] && [ "$POLICY_OK" = 1 ]; then
  echo "virtio-fs: kernel and policy both allow it (plan step 4a)"; exit 0
fi
echo "USB fallback: kernel_ok=$KERNEL_OK policy_ok=$POLICY_OK (plan step 4b)"; exit 1
