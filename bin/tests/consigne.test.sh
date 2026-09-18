#!/usr/bin/env bash
# consigne.test.sh -- the two doors must be one implementation. The end-to-end
# run is not here: it needs bibliothecaire installed, so it cannot be hermetic.
# Case D is the piece that can be -- the resolver finding the mechanism.

set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
CONSIGNE="$REPO/bin/consigne"

check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# A PATH with nothing on it but coreutils. Without this, a host that has
# `fonde` or `installe` installed would let the resolver find the REAL
# mechanism, and every case below would be testing mandark instead of this
# tree. Case D puts its own fixture `fonde` back on it, deliberately.
mkdir -p "$TMP/emptybin"
BASE_PATH="$TMP/emptybin:/usr/bin:/bin"

echo "consigne.test.sh"
echo

# ===========================================================================
echo "-- A. THE ARGUMENT CONTRACT --------------------------------------------"
# ===========================================================================
OUT="$(PATH="$BASE_PATH" "$CONSIGNE" --help 2>&1)"; rc=$?
check "--help exits 0" "$rc" "0"
has   "--help names the old door it replaces" "$OUT" "fonde consign"
has   "--help names the status mode"          "$OUT" "consigne status"
has   "--help publishes the exit contract"    "$OUT" "7  refused"
has   "--help says it never pushes"           "$OUT" "NEVER PUSHES"

OUT="$(PATH="$BASE_PATH" "$CONSIGNE" 2>&1)"; rc=$?
check "no arguments is a usage error (2), not a silent no-op" "$rc" "2"

OUT="$(PATH="$BASE_PATH" "$CONSIGNE" --not-a-real-flag 2>&1)"; rc=$?
check "an unknown flag exits 2" "$rc" "2"
has   "...and names what it rejected" "$OUT" "--not-a-real-flag"

OUT="$(PATH="$BASE_PATH" "$CONSIGNE" -s foo 2>&1)"; rc=$?
check "-s exits 2 rather than being ignored" "$rc" "2"
has   "...and names the flag it rejected" "$OUT" "-s"

# The retirement, held: --summon was a flag this verb accepted and it is gone.
# Asserted rather than merely deleted, so re-adding it fails a test.
OUT="$(PATH="$BASE_PATH" "$CONSIGNE" --summon DOC.md 2>&1)"; rc=$?
check "--summon is a retired flag: unknown, exit 2" "$rc" "2"

# ===========================================================================
echo
echo '-- B. ONE IMPLEMENTATION: the call shape `fonde consign` makes ---------'
# ===========================================================================
# The recording stub IS the assertion. It writes its own argv to a file and
# exits 0. `bin/fonde` runs `bash "$impl" "$VAULT" "$@"`; if this records
# anything else, the two doors are two behaviours.
cat > "$TMP/rec-impl.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ARGV_LOG"
exit "${STUB_RC:-0}"
STUB
export ARGV_LOG="$TMP/argv.log"

VAULTDIR="$TMP/vault-b"; mkdir -p "$VAULTDIR"
OUT="$(PATH="$BASE_PATH" CONSIGNE_IMPL="$TMP/rec-impl.sh" BIBLIOTHECAIRE_VAULT="$VAULTDIR" \
       "$CONSIGNE" DOC.md docs/two.md 2>&1)"; rc=$?
check "a plain deposit forwards and succeeds" "$rc" "0"

GOT="$(cat "$ARGV_LOG" 2>/dev/null)"
WANT="$(printf '%s\n%s\n%s' "$VAULTDIR" "DOC.md" "docs/two.md")"
check "the mechanism is invoked as \`<impl> \$VAULT \$@\` -- fonde's own call shape" \
      "$GOT" "$WANT"

# The vault variable, not a new one. A `consigne` that invented CONSIGNE_VAULT
# would deposit somewhere else than `fonde consign` for the same caller.
check "the vault comes from BIBLIOTHECAIRE_VAULT, the variable fonde reads" \
      "$(head -1 "$ARGV_LOG")" "$VAULTDIR"

# Paths with spaces are one argument, not two. The old door passes "$@"; a
# front door that re-split them would corrupt exactly the filenames a prose
# reaping pass produces.
: > "$ARGV_LOG"
PATH="$BASE_PATH" CONSIGNE_IMPL="$TMP/rec-impl.sh" BIBLIOTHECAIRE_VAULT="$VAULTDIR" \
  "$CONSIGNE" "a file with spaces.md" >/dev/null 2>&1
check "a path with spaces stays one argument" \
      "$(sed -n '2p' "$ARGV_LOG")" "a file with spaces.md"

# ===========================================================================
echo
echo "-- C. THE EXIT CONTRACT, unwrapped -------------------------------------"
# ===========================================================================
# fonde publishes `0 kept  2 usage  5 broken  6 blind  7 refused`. Each is the
# mechanism's own code and must arrive at the caller unchanged -- a front door
# that collapsed 7 (refused, nothing was destroyed) into 5 (broken) would
# teach a caller to distrust the loudest code the vocabulary has.
for want in 0 2 5 6 7; do
  PATH="$BASE_PATH" CONSIGNE_IMPL="$TMP/rec-impl.sh" BIBLIOTHECAIRE_VAULT="$VAULTDIR" \
    STUB_RC="$want" "$CONSIGNE" DOC.md >/dev/null 2>&1
  check "exit $want reaches the caller unchanged" "$?" "$want"
done

# ===========================================================================
echo
echo "-- D. RESOLUTION: it finds the mechanism where fonde carries it --------"
# ===========================================================================
# A fixture shaped exactly like an installed verb build: bin/fonde on PATH,
# lib/consign-prose.sh one directory up from it. This is the layout
# `installe` produces and the one `bin/fonde` itself resolves against.
BUILD="$TMP/build/bibliothecaire"
mkdir -p "$BUILD/bin" "$BUILD/lib"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BUILD/bin/fonde"; chmod +x "$BUILD/bin/fonde"
cp "$TMP/rec-impl.sh" "$BUILD/lib/consign-prose.sh"
: > "$ARGV_LOG"
OUT="$(PATH="$BUILD/bin:$BASE_PATH" BIBLIOTHECAIRE_VAULT="$VAULTDIR" \
       "$CONSIGNE" DOC.md 2>&1)"; rc=$?
check "with no CONSIGNE_IMPL it resolves through the installed fonde's tree" "$rc" "0"
check "...and reaches the mechanism that tree carries" \
      "$(sed -n '2p' "$ARGV_LOG")" "DOC.md"

# A missing mechanism is BLIND (6) and LOUD. This is the row that matters most
# in an estate whose recurring defect is the exit-0 no-op: a front door that
# could not find its own implementation must not report success.
OUT="$(PATH="$BASE_PATH" INSTALLE_PROJECTS="$TMP/no-such-projects" \
       BIBLIOTHECAIRE_VAULT="$VAULTDIR" "$CONSIGNE" DOC.md 2>&1)"; rc=$?
check "no mechanism anywhere is BLIND (6), not a silent success" "$rc" "6"
has   "...and names what it looked for" "$OUT" "consign-prose.sh"
has   "...and says nothing was deposited" "$OUT" "Nothing was deposited"

OUT="$(PATH="$BASE_PATH" CONSIGNE_IMPL="$TMP/does-not-exist.sh" \
       BIBLIOTHECAIRE_VAULT="$VAULTDIR" "$CONSIGNE" DOC.md 2>&1)"; rc=$?
check "an unreadable CONSIGNE_IMPL is BLIND (6), not ignored" "$rc" "6"

# ===========================================================================
echo
echo "-- E. STATUS: the half nothing consumed (hf7y/scheduler#86) ------------"
# ===========================================================================
# A fixture repo and a fixture vault, with one file in each of the three
# states the report distinguishes. The notes carry the same frontmatter the
# real mechanism writes, because that frontmatter is what `status` reads.
SRC="$TMP/src/scheduler"; mkdir -p "$SRC/docs"
VS="$TMP/vault-e/scheduler"; mkdir -p "$VS/docs"

note() { # <notefile> <repo> <relpath> <sha>
  { printf -- '---\n'
    printf 'source_repo: %s\n'   "$2"
    printf 'source_path: %s\n'   "$3"
    printf 'source_commit: %s\n' "0000000000000000000000000000000000000000"
    printf 'source_sha256: %s\n' "$4"
    printf 'consigned: 2026-08-01\n'
    printf 'project: scheduler\n'
    printf -- '---\n'
  } > "$1"
}

printf 'still here\nand unchanged\nthird line\n' > "$SRC/DESIGN-NOTES.md"
note "$VS/DESIGN-NOTES.md" "$SRC" "DESIGN-NOTES.md" \
     "$(sha256sum "$SRC/DESIGN-NOTES.md" | cut -d' ' -f1)"

printf 'edited since the deposit\n' > "$SRC/BLOCKERS.md"
note "$VS/BLOCKERS.md" "$SRC" "BLOCKERS.md" \
     "0000000000000000000000000000000000000000000000000000000000000000"

note "$VS/docs/gone.md" "$SRC" "docs/gone.md" \
     "1111111111111111111111111111111111111111111111111111111111111111"

printf 'not a note\n' > "$VS/no-frontmatter.md"

OUT="$(PATH="$BASE_PATH" BIBLIOTHECAIRE_VAULT="$TMP/vault-e" "$CONSIGNE" status 2>&1)"; rc=$?
check "status exits 0 when it could read everything" "$rc" "0"
has   "a file present and byte-identical is DUPLICATED" "$OUT" "DUPLICATED  scheduler/DESIGN-NOTES.md"
has   "...counted in lines, so the queue has a size"    "$OUT" "(3 lines)"
has   "a file present and changed is DIVERGED"          "$OUT" "DIVERGED    scheduler/BLOCKERS.md"
has   "...and says the vault copy is a stale fork"      "$OUT" "stale fork"
has   "a note with no usable provenance is UNREADABLE"  "$OUT" "UNREADABLE  scheduler/no-frontmatter.md"
has   "the counts are printed"                          "$OUT" "1 DUPLICATED (3 lines in both places), 1 DIVERGED, 1 REAPED, 1 UNREADABLE"
has   "...and prompted, not just counted"               "$OUT" "STILL IN THE REPO"
has   "the prompt names the judgement rather than making it" "$OUT" "PROSE-REAPING.md"

# THE ROW THAT KEEPS THIS FROM BECOMING A DELETER. scheduler#86 asks for the
# queue to be visible, not drained. Nothing may vanish.
if [ -f "$SRC/DESIGN-NOTES.md" ] && [ -f "$VS/DESIGN-NOTES.md" ] && [ -f "$SRC/BLOCKERS.md" ]; then
  ok "status removed nothing -- both copies of every row are still on disk"
else
  bad "status removed nothing" "a file is missing after a status run"
fi
hasnt "status offers no flag that would remove anything" \
      "$(PATH="$BASE_PATH" "$CONSIGNE" --help 2>&1)" "--remove"

# Scoping to one project, and a project that is not there.
OUT="$(PATH="$BASE_PATH" BIBLIOTHECAIRE_VAULT="$TMP/vault-e" "$CONSIGNE" status scheduler 2>&1)"; rc=$?
check "status takes a project name" "$rc" "0"
has   "...and reports it"           "$OUT" "DUPLICATED  scheduler/DESIGN-NOTES.md"

OUT="$(PATH="$BASE_PATH" BIBLIOTHECAIRE_VAULT="$TMP/vault-e" "$CONSIGNE" status nosuchproj 2>&1)"
has "a project absent from the vault is named, not silently skipped" "$OUT" "UNREADABLE  nosuchproj"

OUT="$(PATH="$BASE_PATH" BIBLIOTHECAIRE_VAULT="$TMP/no-such-vault" "$CONSIGNE" status 2>&1)"; rc=$?
check "status with no vault is BLIND (6), never 'nothing to report'" "$rc" "6"
has "...and names the path it looked at, not just 'no vault' (#1061)" "$OUT" "$TMP/no-such-vault"
has "...and names where the vault is going, so BLIND is actionable (#1164)" "$OUT" "realisateur#1164"
# #1061 asked this message to say CLONE. #742 then found a clone in a home
# directory, put there by someone following exactly that advice. The message
# must not hand the next reader the same shovel.
hasnt "...and does NOT advise cloning one here -- that is how a read door opened (#742)" "$OUT" "clone it to"

# A vault whose projects are all clean must SAY so, not print an empty report
# that reads as "checked, nothing found" the same way a broken read does.
mkdir -p "$TMP/vault-clean/wtul"
note "$TMP/vault-clean/wtul/OLD.md" "$SRC" "docs/gone.md" \
     "2222222222222222222222222222222222222222222222222222222222222222"
OUT="$(PATH="$BASE_PATH" BIBLIOTHECAIRE_VAULT="$TMP/vault-clean" "$CONSIGNE" status 2>&1)"
has "a clean vault says so in words" "$OUT" "Nothing is sitting in both places"

OUT="$(PATH="$BASE_PATH" BIBLIOTHECAIRE_VAULT="$TMP/vault-e" "$CONSIGNE" status --diverged 2>&1)"; rc=$?
check "status --diverged exits 0 (#1061 gap 2: a list a run can act on)" "$rc" "0"
check "...and prints exactly the diverged path" "$OUT" "scheduler/BLOCKERS.md"
hasnt "...no DUPLICATED row"                    "$OUT" "DUPLICATED"
hasnt "...no UNREADABLE row"                    "$OUT" "UNREADABLE"
hasnt "...no header"                            "$OUT" "consigne status"
hasnt "...no counts or prompt"                  "$OUT" "STILL IN THE REPO"

OUT="$(PATH="$BASE_PATH" "$CONSIGNE" --diverged DOC.md 2>&1)"; rc=$?
check "--diverged outside \`status\` is a usage error (2)" "$rc" "2"

# ===========================================================================
echo
echo "-- F. IT IS NOT A SECOND IMPLEMENTATION --------------------------------"
# ===========================================================================
# The defect this verb was rewritten to avoid, asserted against its own source.
SRC_TEXT="$(grep -v '^[[:space:]]*#' "$CONSIGNE")"
hasnt "it does not run git push"   "$SRC_TEXT" "git push"
hasnt "it does not run git commit" "$SRC_TEXT" "git commit"
hasnt "it does not copy files into the vault itself" "$SRC_TEXT" 'cp -- "$src"'
has   "it forwards to the mechanism instead"         "$SRC_TEXT" 'bash "$IMPL" "$VAULT"'
# One vault variable across both doors, and no second name for the same fact.
hasnt "it invents no second name for the vault" "$SRC_TEXT" "CONSIGNE_VAULT"
# propagation-set.sh reserves resolving the pin path to two layout-owning
# scripts; this asks `fonde` and `installe` where they are instead.
hasnt "it does not re-derive the verb-build layout" "$SRC_TEXT" "verb-builds/current"

# --- the vault knob: flag beats env beats default ---------------------------
# Three sources for one fact, so the ORDER is the thing to assert. It was one
# hardcoded home until 2026-08-12; a knob whose precedence nobody checked would
# be the same defect wearing a flag.
: > "$ARGV_LOG"
VAULT_F="$TMP/vault-flag"; mkdir -p "$VAULT_F"
PATH="$BASE_PATH" CONSIGNE_IMPL="$TMP/rec-impl.sh" BIBLIOTHECAIRE_VAULT="$VAULTDIR" \
  "$CONSIGNE" --vault "$VAULT_F" DOC.md >/dev/null 2>&1
check "--vault beats BIBLIOTHECAIRE_VAULT" "$(head -1 "$ARGV_LOG")" "$VAULT_F"

: > "$ARGV_LOG"
PATH="$BASE_PATH" CONSIGNE_IMPL="$TMP/rec-impl.sh" BIBLIOTHECAIRE_VAULT="$VAULTDIR" \
  "$CONSIGNE" --vault="$VAULT_F" DOC.md >/dev/null 2>&1
check "--vault=PATH is the same knob" "$(head -1 "$ARGV_LOG")" "$VAULT_F"

OUT="$(PATH="$BASE_PATH" CONSIGNE_IMPL="$TMP/rec-impl.sh" "$CONSIGNE" --vault DOC.md 2>&1)"; rc=$?
check "--vault with no path is a usage error, not a silent deposit" "$rc" "2"

# The default is the FHS location, not a home directory. Asserted against the
# source rather than by running with a clean env, because running it would
# depend on whether this machine happens to have /srv/ecosystem1-vault.
has   "the default vault is /srv/ecosystem1-vault" "$SRC_TEXT" "VAULT_DEFAULT=/srv/ecosystem1-vault"
hasnt "no vault path under a home directory remains" "$SRC_TEXT" 'ecosystem1/ecosystem1'

# ===========================================================================
echo
echo "-- G. PUSH STATUS: is the clone actually the vault (hf7y/realisateur#212)"
# ===========================================================================
# The failure this closes: a vault CLONE sitting commits-ahead-of-origin or
# with uncommitted paths, silently -- measured on mandark as 19 ahead with 9
# uncommitted paths, every consignment since 2026-08-02 in exactly one place.
# All local: a bare repo standing in for the GitHub remote, no network.
if command -v git >/dev/null 2>&1; then
  mk_pushed_vault() { # <vault-dir> -- a clean clone, in sync with its "origin"
    local vault="$1" origin="$TMP/origin-g-$$-$RANDOM.git"
    git init --quiet --bare "$origin"
    git init --quiet "$vault"
    git -C "$vault" config user.email test@example.com
    git -C "$vault" config user.name  Test
    mkdir -p "$vault/proj"
    printf 'hello\n' > "$vault/proj/NOTE.md"
    git -C "$vault" add proj/NOTE.md
    git -C "$vault" commit --quiet -m seed
    git -C "$vault" remote add origin "$origin"
    git -C "$vault" push --quiet -u origin HEAD:main
  }

  VG="$TMP/vault-g-clean"; mk_pushed_vault "$VG"
  OUT="$(PATH="$BASE_PATH" BIBLIOTHECAIRE_VAULT="$VG" "$CONSIGNE" status 2>&1)"
  hasnt "a clean, fully-pushed vault prints no push-status line" "$OUT" "NOT PUSHED"

  VG="$TMP/vault-g-dirty"; mk_pushed_vault "$VG"
  printf 'uncommitted\n' > "$VG/proj/SCRATCH.md"
  OUT="$(PATH="$BASE_PATH" BIBLIOTHECAIRE_VAULT="$VG" "$CONSIGNE" status 2>&1)"
  has "an uncommitted path is reported" "$OUT" "NOT PUSHED"
  has "...with a nonzero uncommitted count" "$OUT" "1 uncommitted path(s)"
  has "...naming the consequence, not just the count" "$OUT" \
      "not in the vault until it is committed and pushed"

  VG="$TMP/vault-g-ahead"; mk_pushed_vault "$VG"
  printf 'second commit\n' > "$VG/proj/SECOND.md"
  git -C "$VG" add proj/SECOND.md
  git -C "$VG" commit --quiet -m second
  OUT="$(PATH="$BASE_PATH" BIBLIOTHECAIRE_VAULT="$VG" "$CONSIGNE" status 2>&1)"
  has "a commit not yet pushed is reported ahead" "$OUT" "1 ahead of"

  # A plain deposit (not `status`) reports it too, but only when the deposit
  # itself was kept (0) -- a refused/broken/blind deposit says nothing about
  # push status because nothing was written to report.
  VG="$TMP/vault-g-deposit"; mk_pushed_vault "$VG"
  printf 'uncommitted\n' > "$VG/proj/SCRATCH.md"
  OUT="$(PATH="$BASE_PATH" CONSIGNE_IMPL="$TMP/rec-impl.sh" STUB_RC=0 \
         BIBLIOTHECAIRE_VAULT="$VG" "$CONSIGNE" DOC.md 2>&1)"
  has "a kept deposit is followed by the push-status line" "$OUT" "NOT PUSHED"

  OUT="$(PATH="$BASE_PATH" CONSIGNE_IMPL="$TMP/rec-impl.sh" STUB_RC=7 \
         BIBLIOTHECAIRE_VAULT="$VG" "$CONSIGNE" DOC.md 2>&1)"
  hasnt "a refused deposit is not followed by the push-status line" "$OUT" "NOT PUSHED"

  # A vault clone that is not a git working tree at all (the case every other
  # test above already exercises against non-git fixture dirs) must not error
  # -- the check is additive, never a new way for `status` to go BLIND.
  VG="$TMP/vault-g-nongit"; mkdir -p "$VG/proj"
  note "$VG/proj/N.md" "$SRC" "DESIGN-NOTES.md" \
       "$(sha256sum "$SRC/DESIGN-NOTES.md" | cut -d' ' -f1)"
  OUT="$(PATH="$BASE_PATH" BIBLIOTHECAIRE_VAULT="$VG" "$CONSIGNE" status 2>&1)"; rc=$?
  check "a non-git vault still reports status cleanly" "$rc" "0"
  hasnt "...and is silent about push state it cannot know" "$OUT" "NOT PUSHED"
else
  echo "  (skipped: no git on PATH)"
fi

# ===========================================================================
echo
echo "-- H. LOCK: serializing the vault's 13 writers (hf7y/realisateur#213) --"
# ===========================================================================
if command -v flock >/dev/null 2>&1; then
  VL="$TMP/vault-lock"; mkdir -p "$VL"

  # BIBLIOTHECAIRE_VAULT set explicitly on every case below, even the ones
  # that don't reach vault_locked's directory check (the usage-error cases) --
  OUT="$(PATH="$BASE_PATH" BIBLIOTHECAIRE_VAULT="$VL" "$CONSIGNE" lock -- echo hello world 2>&1)"; rc=$?
  check "lock runs the wrapped command" "$rc" "0"
  has   "...and its stdout reaches the caller" "$OUT" "hello world"

  OUT="$(PATH="$BASE_PATH" BIBLIOTHECAIRE_VAULT="$VL" "$CONSIGNE" lock -- sh -c 'exit 3' 2>&1)"; rc=$?
  check "lock exits with the wrapped command's own code" "$rc" "3"

  OUT="$(PATH="$BASE_PATH" BIBLIOTHECAIRE_VAULT="$VL" "$CONSIGNE" lock 2>&1)"; rc=$?
  check "lock with no -- is a usage error (2)" "$rc" "2"

  OUT="$(PATH="$BASE_PATH" BIBLIOTHECAIRE_VAULT="$VL" "$CONSIGNE" lock -- 2>&1)"; rc=$?
  check "lock -- with no command is a usage error (2)" "$rc" "2"

  OUT="$(PATH="$BASE_PATH" "$CONSIGNE" lock --vault "$VL" -- echo hi 2>&1)"; rc=$?
  check "lock accepts --vault before --, same knob as a deposit" "$rc" "0"
  [ -f "$VL/.consigne.lock" ] \
    && ok "...and the lock file lands inside that vault" \
    || bad "...and the lock file lands inside that vault" "no $VL/.consigne.lock"

  OUT="$(PATH="$BASE_PATH" "$CONSIGNE" lock --vault=/no/such/dir -- echo hi 2>&1)"; rc=$?
  check "lock --vault of a missing dir is BLIND (6), not a silent lock" "$rc" "6"

  # hf7y/realisateur#338: --vault BEFORE the subcommand must resolve to the
  # same vault as --vault after it, not misparse "lock" as a positional and
  # then die on the "--" naming the wrong token as the offender.
  OUT="$(PATH="$BASE_PATH" "$CONSIGNE" --vault "$VL" lock -- echo hi 2>&1)"; rc=$?
  check "--vault before lock is accepted, not misread as '--' rejected" "$rc" "0"
  has   "...and runs the wrapped command" "$OUT" "hi"

  OUT="$(PATH="$BASE_PATH" "$CONSIGNE" --vault="$VL" lock -- echo hi 2>&1)"; rc=$?
  check "--vault=PATH before lock is the same knob" "$rc" "0"

  # Contention: hold the lock in a background process, then confirm a second
  # caller times out distinctly rather than hanging or silently proceeding.
  # `flock <file> <command>` (no `--`) is the same command-variant syntax
  # `vault_locked` itself uses, so the holder is the real mechanism, not a
  # fixture standing in for it.
  VC="$TMP/vault-contend"; mkdir -p "$VC"
  flock "$VC/.consigne.lock" sleep 4 &
  HOLDER=$!
  # Give the holder a moment to actually acquire before racing it.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    flock -n "$VC/.consigne.lock" true 2>/dev/null && { sleep 0.2; continue; }
    break
  done

  OUT="$(PATH="$BASE_PATH" CONSIGNE_LOCK_TIMEOUT=1 "$CONSIGNE" lock --vault "$VC" -- echo should-not-run 2>&1)"
  rc=$?
  check "a contended lock times out at 66, not the wrapped command's own code" "$rc" "66"
  hasnt "...and the wrapped command never ran" "$OUT" "should-not-run"
  has   "...and says another writer held it" "$OUT" "another writer held the vault lock"

  OUT="$(PATH="$BASE_PATH" CONSIGNE_IMPL="$TMP/rec-impl.sh" CONSIGNE_LOCK_TIMEOUT=1 \
         BIBLIOTHECAIRE_VAULT="$VC" "$CONSIGNE" DOC.md 2>&1)"
  rc=$?
  check "a contended lock folds into the deposit's own 6 (blind), not a raw 66" "$rc" "6"

  wait "$HOLDER" 2>/dev/null
else
  echo "  (skipped: no flock on PATH)"
fi

# ===========================================================================
echo
echo "-- I. THE SPOOL: depositing into a vault this account cannot read (#742)"
# ===========================================================================
if [ "$(id -u)" -eq 0 ]; then
  echo "  (skipped: running as root, which can read a 0700 directory)"
else
  VS="$TMP/vault-shut"; mkdir -p "$VS"; chmod 0700 "$VS"; chmod 0000 "$VS"
  SPOOL="$TMP/spool"; mkdir -p "$SPOOL"
  echo "hello" > "$TMP/DOC.md"

  OUT="$(PATH="$BASE_PATH" CONSIGNE_IMPL="$TMP/rec-impl.sh" \
         BIBLIOTHECAIRE_VAULT="$VS" CONSIGNE_SPOOL="$SPOOL" \
         "$CONSIGNE" "$TMP/DOC.md" 2>&1)"; rc=$?
  check "an unreadable vault spools instead of blinding" "$rc" "0"
  has   "and says SPOOLED, not DEPOSITED"      "$OUT" "SPOOLED"
  has   "and says the OPPOSITE of the impl's safe-to-remove report" "$OUT" "NOTHING is safe to remove"
  has   "and says the deposit has NOT happened yet"   "$OUT" "NOT yet deposited"

  n="$(find "$SPOOL" -maxdepth 1 -type f -name 'req-*' | wc -l | tr -d ' ')"
  check "one request landed in the spool" "$n" "1"
  REQ="$(find "$SPOOL" -maxdepth 1 -type f -name 'req-*' | head -1)"
  has "the request names the absolute source path" "$(cat "$REQ")" "$TMP/DOC.md"
  has "the request names the depositing account"   "$(cat "$REQ")" "$(id -un)"
  hasnt "the request carries no prose -- only a pointer" "$(cat "$REQ")" "hello"

  if [ -f "$ARGV_LOG" ]; then
    hasnt "consign-prose was not run against the closed vault" "$(cat "$ARGV_LOG")" "$VS"
  fi

  OUT="$(PATH="$BASE_PATH" CONSIGNE_IMPL="$TMP/rec-impl.sh" \
         BIBLIOTHECAIRE_VAULT="$VS" CONSIGNE_SPOOL="$TMP/no-such-spool" \
         "$CONSIGNE" "$TMP/DOC.md" 2>&1)"; rc=$?
  check "a closed vault with NO spool is BLIND, never a silent success" "$rc" "6"
  has   "and names the provisioner as the remedy" "$OUT" "vault-group-provision"

  OUT="$(PATH="$BASE_PATH" CONSIGNE_IMPL="$TMP/rec-impl.sh" \
         BIBLIOTHECAIRE_VAULT="$VS" CONSIGNE_SPOOL="$SPOOL" \
         "$CONSIGNE" "$TMP/no-such-doc.md" 2>&1)"; rc=$?
  check "a source that does not exist is caught HERE, not at 03:00 in the drainer" "$rc" "2"

  chmod 0755 "$VS"
fi

has "the spool default is the FHS location beside the vault" "$SRC_TEXT" "CONSIGNE_SPOOL_DEFAULT=/srv/vault-spool"

echo
summary
