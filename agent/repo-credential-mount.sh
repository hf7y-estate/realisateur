#!/usr/bin/env bash
# repo-credential-mount.sh <owner/repo> -- prints the one extra `-v SRC:DST:ro`
# mount spec run-agent.sh's own pass container gets for its repo, or nothing
# (#1656: a container is handed the two credentials every pass gets, claude
# -token and gh-token, and nothing a repo's own work needs).
#
# The map is bin/lib/repo-credentials.tsv, THE ONE PLACE a repo is tied to a
# credential key. This script only reads it; a second repo gets its own
# token by a second line there, never a second case here or in run-agent.sh.
#
# RESOLVED BY KEY, same as agent/start-credentialed-container.sh (#1687): the
# mount lands at MOUNT_ROOT/<key>, never a path typed anywhere upstream of
# this script, so a baudin pass finds its token at the same stated path
# whichever of the two starts its container.
#
# No row, or a row whose file is not yet on this host (CRED_DIR, default
# /etc/selfdev), prints nothing and exits 0 -- same outcome either way. This
# is advisory: a pass runs without its extra credential rather than refusing
# to run at all, because the GH mint is the one credential that does refuse.
set -euo pipefail

target="${1:?usage: repo-credential-mount.sh <owner/repo>}"
CRED_DIR="${CRED_DIR:-/etc/selfdev}"
MOUNT_ROOT="${MOUNT_ROOT:-/run}"
map="${REPO_CREDENTIALS_TSV:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../bin/lib/repo-credentials.tsv}"

[ -f "$map" ] || exit 0

cred_key="$(awk -F'\t' -v r="$target" '$0 !~ /^#/ && $1==r {print $2; exit}' "$map")"
[ -n "$cred_key" ] || exit 0

cred_path="$CRED_DIR/$cred_key"
# /etc/selfdev is 700 root and run-agent.sh calls this as zach, so a bare
# [ -f ] said "not on this host" for a file that was (hf7y-estate/baudin#189,
# 2026-10-10: the first baudin pass found no /run/baudin-ha-token). Ask the
# way run-agent.sh reaches everything else in that directory.
[ -f "$cred_path" ] || sudo -n test -f "$cred_path" 2>/dev/null || exit 0

printf '%s:%s:ro\n' "$cred_path" "$MOUNT_ROOT/$cred_key"
