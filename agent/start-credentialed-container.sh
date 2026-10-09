#!/usr/bin/env bash
# start-credentialed-container.sh <name> <cred-key> <image> -- <cmd...> --
# starts a container holding ONE credential, mounted read-only, resolved from
# a KEY rather than a path the caller types (realisateur#1687: the only way an
# agent had to hand a container a credential was to copy the file itself, and
# that copy is what a session's permission classifier refuses as
# [Credential Leakage]). A caller that only knows the key "baudin-ha-token"
# never types, or sees, where that file lives on the host.
#
# This is the piece of #1687 buildable and provable from a container that
# cannot reach dexter or a live session's classifier: the starter itself, and
# its test (bin/tests/start-credentialed-container.test.sh). Reaching dexter,
# wiring a repo-to-credential map (#1656), and changing what the classifier
# allows are still open there.
#
# Credentials stay out of `docker inspect`, `ps` and shell history the same
# way agent/run-agent.sh's own mounts do: a `-v ... :ro` bind, never a path or
# a secret on a command line or in an env var.
set -euo pipefail

name="${1:?usage: start-credentialed-container.sh <name> <cred-key> <image> -- <cmd...>}"
cred_key="${2:?usage: start-credentialed-container.sh <name> <cred-key> <image> -- <cmd...>}"
image="${3:?usage: start-credentialed-container.sh <name> <cred-key> <image> -- <cmd...>}"
shift 3
[ "${1:-}" = "--" ] || { echo "start-credentialed-container.sh: expected -- before the command" >&2; exit 2; }
shift

# RESOLVED HERE, NOT TYPED BY THE CALLER. CRED_DIR defaults to the host-wide
# credential directory (#1656); a test overrides it so this never reads a
# real secret. The caller names the credential it wants, never the path it
# lives at.
CRED_DIR="${CRED_DIR:-/etc/selfdev}"
cred_path="$CRED_DIR/$cred_key"
[ -f "$cred_path" ] || { echo "start-credentialed-container.sh: no credential '$cred_key' under $CRED_DIR" >&2; exit 3; }

# MOUNT_ROOT defaults to the real in-container /run; a test overrides it so
# the stand-in credential lands under its own scratch directory instead of a
# path on the real filesystem the test does not own.
MOUNT_ROOT="${MOUNT_ROOT:-/run}"
mount_point="$MOUNT_ROOT/$cred_key"

# --rm: the container stops itself. No host mount but the one credential file.
exec docker run --rm --name "$name" \
  -v "$cred_path":"$mount_point":ro \
  "$image" "$@"
