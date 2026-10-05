#!/usr/bin/env bash
# Run as root in a disposable Linux VM; creates only a fresh /var/tmp fixture.
# Usage: sudo bash scripts/repro-shared-tracker.sh /absolute/path/to/br
# Exit status is the second user's claim status (currently 7); keeps evidence.
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run in a disposable VM as root.' >&2; exit 1; }
br_bin=$(realpath "${1:?Pass the br executable path}")
[[ -x $br_bin ]] || { echo 'br is not executable.' >&2; exit 1; }
for tool in setpriv jq install find; do command -v "$tool" >/dev/null; done
umask 0007

fixture=$(mktemp -d /var/tmp/br-shared-tracker.XXXXXX)
chmod 0711 "$fixture"
install -d -o 1000 -g 989 -m 2750 "$fixture/project"
cd "$fixture/project"
beads_dir=$PWD/.beads
printf 'Retained fixture: %s\n' "$fixture"
"$br_bin" --version

as_uid() {
    local run_uid=$1
    shift
    setpriv --reuid="$run_uid" --regid=989 --clear-groups \
        env -i PATH=/usr/bin:/bin RUST_LOG=error BEADS_DIR="$beads_dir" "$br_bin" "$@"
}

as_uid 1000 init --prefix qa --actor repro/operator
issue_id=$(as_uid 1000 create 'Shared tracker fixture' --type task \
    --actor repro/operator --json | jq -er '.id')
# Make the entire database family writable by the shared group, not by others.
find "$beads_dir" -type d -exec chmod 2770 {} +
find "$beads_dir" -type f -exec chmod 0660 {} +
as_uid 1000 show "$issue_id" --json >/dev/null

# Verify the kernel permits the second user to access the database and lock.
setpriv --reuid=999 --regid=989 --clear-groups /bin/sh -c \
    'for p do test -r "$p" && test -w "$p" || exit 1; done' sh \
    "$beads_dir/beads.db" "$beads_dir/beads.db-fsqlite-ns-gate"
stat -c 'uid=%u gid=%g mode=%a %n' \
    "$beads_dir/beads.db" "$beads_dir/beads.db-fsqlite-ns-gate"

printf '\nUID 999 claims the issue (same GID 989, sequential access):\n'
if as_uid 999 update "$issue_id" --claim --actor repro/broker --json; then
    # A successful claim must not make the original owner lose access.
    as_uid 1000 show "$issue_id" --json >/dev/null
    as_uid 999 show "$issue_id" --json >/dev/null
    echo 'Claim succeeded; both users can still read the tracker.'
else
    claim_status=$?
    printf 'Claim exit status: %s\n' "$claim_status" >&2
    exit "$claim_status"
fi
