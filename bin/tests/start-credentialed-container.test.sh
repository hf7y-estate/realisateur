#!/usr/bin/env bash
# SUBJECT: agent/start-credentialed-container.sh. Hermetic -- `docker` is a
# stub on PATH that stands in for the real bind mount with a symlink under
# $T, so this suite needs no root, no real docker daemon and no dexter, and
# cannot pass because some host happens to hold the right file.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
harness_tmp
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
STARTER="$REPO/agent/start-credentialed-container.sh"

echo "start-credentialed-container.test.sh"

mkdir -p "$T/bin" "$T/creds-a" "$T/creds-b" "$T/run"

# Records every invocation, then fakes `docker run --rm --name NAME
# -v SRC:DST:ro IMAGE CMD...` by symlinking DST to SRC under $T and actually
# running CMD -- so a command that cats the mount point reads the real
# stand-in file, with no real container and no real mount.
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$T_LOG"
[ "${1:-}" = run ] || exit 0
shift
mount_spec=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rm)    shift ;;
    --name)  shift 2 ;;
    -v)      mount_spec="$2"; shift 2 ;;
    *)       break ;;
  esac
done
image="$1"; shift
src="${mount_spec%%:*}"
rest="${mount_spec#*:}"
dst="${rest%%:*}"
mkdir -p "$(dirname "$dst")"
ln -sf "$src" "$dst"
: "$image"   # the stub does not need the image name to stand in for one
exec "$@"
STUB
chmod +x "$T/bin/docker"

run() {  # run(name, cred-key, cred-dir, mount-root) -- cat's the mount point
  rm -f "$T/docker.log"; : > "$T/docker.log"
  PATH="$T/bin:$PATH" T_LOG="$T/docker.log" CRED_DIR="$3" MOUNT_ROOT="$4" \
    "$STARTER" "$1" "$2" stand-in-image -- cat "$4/$2" 2>&1
}
invocation() { cat "$T/docker.log" 2>/dev/null; }

section "A. the caller names a KEY; the starter resolves the path, not the caller"
printf 'ceiling-reads-token\n' > "$T/creds-a/baudin-ha-token"
out="$(run ipcam baudin-ha-token "$T/creds-a" "$T/run")"; rc="$?"
rc "exits 0" 0 "$rc"
eq "...and the container read the credential from inside" "$out" "ceiling-reads-token"
has "...docker got the resolved host path on -v, never from this test's own argv to the starter" \
  "$(invocation)" "-v $T/creds-a/baudin-ha-token:$T/run/baudin-ha-token:ro"
has "...the container stops itself" "$(invocation)" "--rm"

section "B. the same key resolves against whichever CRED_DIR it is handed -- a key, not a baked-in path"
printf 'other-token\n' > "$T/creds-b/baudin-ha-token"
out="$(run ipcam2 baudin-ha-token "$T/creds-b" "$T/run")"; rc "exits 0" 0 "$?"
eq "...reads the OTHER directory's file, same key" "$out" "other-token"

section "C. an unknown key starts nothing"
: > "$T/docker.log"
out="$(run ipcam3 no-such-key "$T/creds-a" "$T/run")"; rc="$?"
rc "exits nonzero" 3 "$rc"
has "...says which key and where it looked" "$out" "no-such-key"
has "...and docker" "$out" "under $T/creds-a"
eq "...docker was never invoked" "$(invocation)" ""

section "D. the command before -- is required"
out="$("$STARTER" ipcam4 baudin-ha-token stand-in-image cat /no/dash/dash 2>&1)"; rc="$?"
rc "exits nonzero" 2 "$rc"
has "...says so" "$out" "expected -- before the command"

summary
