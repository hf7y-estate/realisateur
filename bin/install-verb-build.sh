#!/usr/bin/env bash
# install-verb-build.sh -- install a pinned verb build from the meta-repo,
# so every user path runs the SAME verbs and none of them move while agents
# merge the next ones.
#
# TRAPS (the rest of this header is in the vault):
# WHY `current` IS A SYMLINK: adopting or rolling back repoints ONE link, so the
# verb set changes all at once or not at all. N `git pull`s half-succeed and
# leave a set that never existed as a whole. And an unreachable remote is BLIND
# (exit 6), never "up to date": that would make "nothing pending" read as proof.

set -uo pipefail

CLI_NAME='install-verb-build.sh'
CLI_SUMMARY='install a pinned verb build from the meta-repo and switch to it atomically'
CLI_USAGE='  install-verb-build.sh --check              is a newer build available?
  install-verb-build.sh --latest --apply    install the newest build and switch
  install-verb-build.sh --build <id> --apply  install one build by id
  install-verb-build.sh --list              builds on this host
  install-verb-build.sh --rollback <id>     switch back to a build already here'
CLI_FLAGS='--check --latest --build --apply --link --list --rollback --build-root --remote'
CLI_POSITIONAL=any   # flag VALUES (--build <id>) read as positionals to cli-guard;
                     # the arg loop below rejects anything genuinely unknown.
CLI_EXITS='  0  done, or --check found you current
  1  refused: incomplete, unverifiable, or --check found a newer build
  2  usage error
  6  BLIND: could not reach the meta-repo. This is not "up to date".'
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
cli_guard "$@"

BUILD_ROOT="${VERB_BUILD_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/verb-builds}"
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/estate-set.sh"
REMOTE="${VERB_BUILD_REMOTE:-https://github.com/$GH_ESTATE_OWNER/verbs.git}"
BIN="${INSTALLE_BIN:-$HOME/.local/bin}"
CMD_DEST="${CMD_DEST:-$HOME/.claude/commands}"
HOOK_DEST="${HOOK_DEST:-$HOME/.claude/hooks}"
# HOST-WIDE, not $HOME-scoped: these are the probes ausculte composes on the
# machine, and `ssh <host> ausculte` sees no $HOME path (realisateur#264).
LIBEXEC_DEST="${SELFDEV_LIBEXEC:-/usr/local/libexec/selfdev}"
REPO="$BUILD_ROOT/repo"
BUILD_ID=''; APPLY=0; LINK=0; LIST=0; CHECK=0; LATEST=0; ROLLBACK=''

while [ $# -gt 0 ]; do
  case "$1" in
    --build)      BUILD_ID="${2:?--build needs an id}"; shift ;;
    --rollback)   ROLLBACK="${2:?--rollback needs an id}"; shift ;;
    --build-root) BUILD_ROOT="${2:?--build-root needs a value}"; REPO="$BUILD_ROOT/repo"; shift ;;
    --remote)     REMOTE="${2:?--remote needs a value}"; shift ;;
    --latest)     LATEST=1 ;;
    --check)      CHECK=1 ;;
    --apply)      APPLY=1 ;;
    --link)       LINK=1 ;;
    --list)       LIST=1 ;;
    *) printf '%s: unknown argument: %s\n' "$CLI_NAME" "$1" >&2; exit 2 ;;
  esac
  shift
done

say()  { printf '%s\n' "$*" >&2; }
die()  { printf '%s: %s\n' "$CLI_NAME" "$*" >&2; exit 1; }
blind(){ printf '%s: BLIND -- %s. This is not "up to date".\n' "$CLI_NAME" "$*" >&2; exit 6; }
row()  { printf '  %-8s %-18s %s\n' "$1" "$2" "${3:-}" >&2; }

current_id() { readlink "$BUILD_ROOT/current" 2>/dev/null || true; }

# --- purely local modes -------------------------------------------------
if [ "$LIST" -eq 1 ]; then
  [ -d "$BUILD_ROOT" ] || die "no builds on this host ($BUILD_ROOT does not exist)"
  cur="$(current_id)"
  found=0
  for d in "$BUILD_ROOT"/*/; do
    d="${d%/}"; id="$(basename "$d")"
    [ "$id" = repo ] && continue
    [ -f "$d/manifest.tsv" ] || continue
    found=1
    n="$(grep -cv '^#' "$d/manifest.tsv" 2>/dev/null || echo 0)"
    mark='  '; [ "$id" = "$cur" ] && mark='->'
    printf '%s %-24s %s verb(s)\n' "$mark" "$id" "$n"
  done
  [ "$found" -eq 1 ] || say "no builds installed yet"
  exit 0
fi

# Rollback deliberately does NOT touch the network. The build is already
# here and was verified when it was installed; making recovery depend on
# the remote would make it fail in exactly the situation you need it.
if [ -n "$ROLLBACK" ]; then
  [ -f "$BUILD_ROOT/$ROLLBACK/manifest.tsv" ] || die "no installed build '$ROLLBACK' on this host (see --list)"
  ln -sfn "$ROLLBACK" "$BUILD_ROOT/current.tmp" || die "cannot write $BUILD_ROOT/current.tmp"
  mv -Tf "$BUILD_ROOT/current.tmp" "$BUILD_ROOT/current" || die 'cannot move current into place'
  say "current -> $ROLLBACK"
  exit 0
fi

# --- fetch the meta-repo ------------------------------------------------
# BOUNDED, because this runs unattended: against an unroutable host the
# kernel's TCP retry runs for minutes before giving up.
NET_TIMEOUT="${VERB_BUILD_NET_TIMEOUT:-45}"
export GIT_TERMINAL_PROMPT=0
mkdir -p "$BUILD_ROOT" || die "cannot create $BUILD_ROOT"
if [ -d "$REPO/.git" ]; then
  timeout "$NET_TIMEOUT" git -C "$REPO" fetch -q --tags --prune origin 2>/dev/null \
    || blind "cannot fetch $REMOTE within ${NET_TIMEOUT}s"
else
  rm -rf "$REPO"
  timeout "$NET_TIMEOUT" git clone -q --bare "$REMOTE" "$REPO/.git" 2>/dev/null \
    || blind "cannot clone $REMOTE within ${NET_TIMEOUT}s"
  git -C "$REPO" config core.bare false 2>/dev/null || true
  timeout "$NET_TIMEOUT" git -C "$REPO" fetch -q --tags origin 2>/dev/null || true
fi

# NEWEST APPROVED, not newest: the cron is ungated, so `build/*` appears nightly
# with nobody asked. Only `approved/<id>`, from the reviewer-gated
# promote-verb-build.yml, is adopted. Ids sort chronologically.
approved_ids="$(git -C "$REPO" tag --list 'approved/*' --sort=-refname 2>/dev/null | sed 's|^approved/||')"
latest_tag=''
for _id in $approved_ids; do
  if git -C "$REPO" rev-parse -q --verify "refs/tags/build/$_id" >/dev/null 2>&1; then
    latest_tag="build/$_id"; break
  fi
done
if [ -z "$latest_tag" ]; then
  if [ -n "$(git -C "$REPO" tag --list 'build/*' 2>/dev/null | head -1)" ]; then
    blind "builds exist but NONE is approved -- a cut is not a release. Approve one by running promote-verb-build.yml in the meta-repo; until then a host holds the build it has."
  fi
  blind "the meta-repo has no build/* tags -- nothing has been built yet, or the fetch was partial"
fi
latest_id="${latest_tag#build/}"

if [ "$CHECK" -eq 1 ]; then
  cur="$(current_id)"
  if [ "$cur" = "$latest_id" ]; then
    printf 'verbs: up to date (build %s)\n' "$cur"
    exit 0
  fi
  # AHEAD IS NOT BEHIND (#1278 ss1). This compared for INEQUALITY, so a host
  # holding a build the channel has never approved -- which is what
  # push-verb-build.sh --cut --host writes to a proving ground -- read as
  # stale. `--apply` then adopted an id eleven days OLDER and bin/ went from
  # 15 entries to 11, on an operation named refresh. Ids are timestamps and
  # sort chronologically, so the comparison that answers the question is >.
  if [ -n "$cur" ] && [ "$cur" \> "$latest_id" ]; then
    printf 'verbs: AHEAD of the channel (nothing to adopt)\n  yours:           %s\n  newest approved: %s\n' \
           "$cur" "$latest_id"
    printf '  adopting that would move you BACKWARD. To do it anyway: --build %s\n' "$latest_id"
    exit 0
  fi
  n="$(git -C "$REPO" show "$latest_tag:manifest.tsv" 2>/dev/null | grep -cv '^#' || echo '?')"
  printf 'verbs: a newer build is available\n  yours:  %s\n  latest: %s (%s verbs)\n' \
         "${cur:-<none installed>}" "$latest_id" "$n"
  printf '  adopt it with: install-verb-build.sh --latest --apply\n'
  exit 1
fi

[ "$LATEST" -eq 1 ] && BUILD_ID="$latest_id"
# The same guard on the adoption path: --check is advisory, and a host is one
# `--latest --apply` away from the backward switch with or without it.
# `--build <id>` and `--rollback <id>` still go backward -- deliberately, by id.
if [ "$LATEST" -eq 1 ]; then
  _cur="$(current_id)"
  if [ -n "$_cur" ] && [ "$_cur" \> "$BUILD_ID" ]; then
    die "--latest would move you BACKWARD: you are on $_cur, newest approved is $BUILD_ID. Nothing switched. To do it on purpose: --build $BUILD_ID"
  fi
fi
[ -n "$BUILD_ID" ] || { printf '%s: need --check, --latest, --build <id>, --list or --rollback <id>\n' "$CLI_NAME" >&2; exit 2; }

tag="build/$BUILD_ID"
git -C "$REPO" rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1 \
  || die "no such build in the meta-repo: $BUILD_ID (newest is $latest_id)"

approved_ok=0   # the gate binds --build too, not just --latest (#962)
for _id in $approved_ids; do   # a walk, not a `case`: this list is NEWLINE-separated
  [ "$_id" = "$BUILD_ID" ] && { approved_ok=1; break; }
done
[ "$approved_ok" -eq 1 ] || die "build $BUILD_ID exists but is NOT approved -- a cut is not a release.
       Approve it by running promote-verb-build.yml in the meta-repo, or name an
       approved id. Approved here: $(printf '%s ' $approved_ids)"

# --- extract ------------------------------------------------------------
# `git archive` rather than a checkout: the result is a plain tree with no
# .git, so a build cannot be edited in place and then keep claiming to be
# that build.
DEST="$BUILD_ROOT/$BUILD_ID"
if [ ! -f "$DEST/manifest.tsv" ]; then
  rm -rf "$DEST"; mkdir -p "$DEST" || die "cannot create $DEST"
  git -C "$REPO" archive "$tag" | tar -x -C "$DEST" \
    || { rm -rf "$DEST"; die "could not extract $tag"; }
fi
[ -f "$DEST/manifest.tsv" ] || { rm -rf "$DEST"; die "$tag carries no manifest.tsv -- refusing"; }

# --- verify every verb the manifest promised ----------------------------
# Against the manifest, not against what happened to land. A build is a
# promise about a SET; verifying only what is present cannot notice a verb
say "== build $BUILD_ID =="
missing=0
while IFS=$'\t' read -r project verb sha _; do
  [ -n "${verb:-}" ] || continue
  f="$DEST/$project/bin/$verb"
  if   [ ! -f "$f" ]; then row MISSING "$verb" "$project has no bin/$verb"; missing=$((missing+1))
  elif [ ! -x "$f" ]; then row BAD     "$verb" "not executable"; missing=$((missing+1))
  fi
done < <(grep -v '^#' "$DEST/manifest.tsv")

total="$(grep -cv '^#' "$DEST/manifest.tsv")"
[ "$total" -gt 0 ] || { rm -rf "$DEST"; die 'manifest has no rows -- refusing to install an empty verb set'; }
if [ "$missing" -gt 0 ]; then
  rm -rf "$DEST"
  die "build $BUILD_ID is INCOMPLETE ($missing bad/missing verb(s)). Discarded, and current is unchanged."
fi
say "verified: $total verb(s), all present and executable"

if [ "$APPLY" -eq 0 ]; then
  say "check only, nothing switched. Re-run with --apply to make this build current."
  exit 0
fi

# --- switch, atomically -------------------------------------------------
# ln -sfn then mv -T: a plain `ln -sfn` over an existing symlink-TO-A-
# DIRECTORY creates the new link INSIDE the old target instead of replacing
# it, leaving current pointing at the old build while this script reports
# success.
ln -sfn "$BUILD_ID" "$BUILD_ROOT/current.tmp" || die "cannot write $BUILD_ROOT/current.tmp"
mv -Tf "$BUILD_ROOT/current.tmp" "$BUILD_ROOT/current" || die 'cannot move current into place'
say "current -> $BUILD_ID"

# --- the ~/.local/bin links, written once -------------------------------
# Off by default: `installe` (senechal) owns ~/.local/bin and its manifest.
if [ "$LINK" -eq 1 ]; then
  mkdir -p "$BIN"
  linked=0; skipped=0
  while IFS=$'\t' read -r project verb _ _; do
    [ -n "${verb:-}" ] || continue
    want="$BUILD_ROOT/current/$project/bin/$verb"
    have="$BIN/$verb"
    if [ -e "$have" ] || [ -L "$have" ]; then
      tgt="$(readlink "$have" 2>/dev/null || true)"
      case "$tgt" in
        "$BUILD_ROOT/current/"*) continue ;;   # already ours; `current` moved for us
        *) row SKIP "$verb" "not ours -> ${tgt:-<real file>}"; skipped=$((skipped+1)); continue ;;
      esac
    fi
    ln -sfn "$want" "$have" && linked=$((linked + 1))
  done < <(grep -v '^#' "$DEST/manifest.tsv")
  say "linked $linked verb(s) into $BIN; $skipped left alone"
  [ "$skipped" -eq 0 ] || say 'the skipped ones are installe-owned -- reconcile deliberately, not by clobbering.'

  # --- drop links for verbs this build no longer promises ---------------
  wanted="$(grep -v '^#' "$DEST/manifest.tsv" | cut -f2)"
  dropped=0
  for have in "$BIN"/*; do
    [ -L "$have" ] || continue
    tgt="$(readlink "$have" 2>/dev/null || true)"
    case "$tgt" in
      "$BUILD_ROOT/current/"*) : ;;
      *) continue ;;
    esac
    verb="$(basename "$have")"
    printf '%s\n' "$wanted" | grep -Fxq "$verb" && continue
    rm -f "$have" && { row DROP "$verb" "no longer in build $BUILD_ID's manifest"; dropped=$((dropped+1)); }
  done
  say "dropped $dropped verb(s) no longer in this build"

  # --- the one honest count: manifest rows vs links pointing in here -----
  # "N verbs in the manifest, N links on the host" is the comparison an
  # operator actually reaches for. Report it loudly rather than let a link
  # this loop should have made or removed drift the two apart silently.
  ours=0
  for have in "$BIN"/*; do
    [ -L "$have" ] || continue
    tgt="$(readlink "$have" 2>/dev/null || true)"
    case "$tgt" in "$BUILD_ROOT/current/"*) ours=$((ours + 1)) ;; esac
  done
  if [ "$ours" -ne "$total" ]; then
    say "COUNT MISMATCH: manifest promises $total verb(s), but $ours link(s) in $BIN point into this build root"
  fi

  # A slash command is a FILE Claude Code reads, so it can never be a verb
  # (#389). COPIED, not symlinked: a dangling link into a rolled-back build
  # reads as a CORRUPT command file, not an absent one.
  #
  # libexec JOINED THIS LOOP for #517: host tools reached a machine only when a
  # human ran wire-release-channel.sh --host --apply, so a fix to one of
  # ausculte's probes sat on main indefinitely -- a decision-rot that could not
  # load its roster walked zero repos, exited 0, and rendered `rot OK` over 48
  # rotting decisions (#512). carries.tsv carries them; this installs them.
  installed=0
  for src_dir in commands hooks libexec; do
    from="$BUILD_ROOT/current/realisateur/$src_dir"
    [ -d "$from" ] || continue
    case "$src_dir" in
      commands) to="$CMD_DEST"; mode=644 ;;
      hooks)    to="$HOOK_DEST"; mode=755 ;;
      libexec)  to="$LIBEXEC_DEST"; mode=755 ;;
    esac
    # A destination this account cannot create is a FINDING, not a silent skip:
    # libexec is root-owned, and a --link run without the privilege for it
    # would otherwise report "installed 0" and read as up to date.
    mkdir -p "$to" 2>/dev/null || { row SKIP "$src_dir" "cannot create $to -- not installed"; continue; }
    for f in "$from"/*; do
      [ -f "$f" ] || continue
      dst="$to/$(basename "$f")"
      # A symlink here is never ours; cp would write THROUGH it.
      [ -L "$dst" ] && { row SKIP "$(basename "$f")" "symlink -> $(readlink "$dst")"; continue; }
      cmp -s "$f" "$dst" && continue
      # ATOMIC, because a destination here can be EXECUTING. bash re-reads its
      # script by offset, so `cp` over a running one (cp truncates in place,
      # same inode) corrupts it mid-run. Rename gives the new content a new
      # inode and leaves the running process on the old one.
      tmp="$to/.$(basename "$f").new.$$"
      if cp "$f" "$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$dst"; then
        installed=$((installed + 1))
      else
        rm -f "$tmp"; row SKIP "$(basename "$f")" "could not install into $to"
      fi
    done
  done
  say "installed $installed command/hook/libexec file(s) from this build"
fi
exit 0
