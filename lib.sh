# shellcheck shell=bash
# Sourced by the scripts; the caller sets HERE (where the code is) first.
# STATE is where every output goes; the default keeps a checkout behaving as before.
STATE="${GBOS_STATE:-$HERE}"

# verify FILE: FILE must match its entry in checksums.sha256 (paths relative to STATE).
# A mismatch, a missing entry or a missing checksums file fails; GBOS_UNVERIFIED=1 bypasses.
verify() {
  local rel="${1#"$STATE"/}"
  if [ "${GBOS_UNVERIFIED:-0}" = 1 ]; then
    echo "warning: GBOS_UNVERIFIED=1, not checking $1" >&2
    return 0
  fi
  if ! (cd "$STATE" && awk -v f="$rel" '{h=$1; sub(/^[^ ]+  /,"")} $0==f{print h "  " f}' "$HERE/checksums.sha256" 2>/dev/null \
        | sha256sum -c --status 2>/dev/null); then
    echo "error: checksum mismatch or unpinned: $1" >&2
    return 1
  fi
}
