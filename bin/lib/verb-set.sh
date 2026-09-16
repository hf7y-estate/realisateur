#!/usr/bin/env bash
# verb-set.sh -- what verbs the ecosystem DECLARES, in one place.
#
# TRAPS (the rest of this header is in the vault):
# The generator answered the second with `command -v <verb>` -- the HOST'S
# PATH. That is host state, and the declarations are repo state, so the two
# disagree whenever a verb is declared but not yet installed -- and a verb
# nobody installed can be assigned to two projects at once. Only one can own
# the name, and
# unreachable. The report for that pass says "all verbs confirmed unclaimed on
# PATH before assignment", which was true and still produced a collision --
# PATH was the wrong thing to confirm against.

_verb_set_owner() { printf '%s' "${VERB_SET_OWNER:-${GH_ESTATE_OWNER:-hf7y}}"; }  # #1043: was a checkout scan (host state); now the estate's own GitHub answer

_verb_set_is_linked_worktree() {  # a bashified worktree shares its repo's refs; VERB_SET_LOCAL_ROOT (tests only) must skip it or it double-declares -- a real repo list has no worktrees
  local d="$1" gd gc
  gd="$(git -C "$d" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || return 1
  gc="$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ "$gd" != "$gc" ]
}

_verb_set_repos() {  # every repo to consider; VERB_SET_LOCAL_ROOT (tests only) scans local git dirs in place of `gh repo list`
  if [ -n "${VERB_SET_LOCAL_ROOT:-}" ]; then
    local root="$VERB_SET_LOCAL_ROOT" d
    [ -d "$root" ] || return 0
    for d in "$root"/*/; do
      d="${d%/}"
      [ -d "$d" ] || continue
      git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || continue
      _verb_set_is_linked_worktree "$d" && continue
      basename "$d"
    done
    return 0
  fi
  "${VERB_SET_GH:-gh}" repo list "$(_verb_set_owner)" --limit 200 --no-archived \
    --json name -q '.[].name'
}

_verb_set_remote_url() {  # a github.com clone URL, or a VERB_SET_LOCAL_ROOT path for tests
  if [ -n "${VERB_SET_LOCAL_ROOT:-}" ]; then
    printf '%s/%s' "$VERB_SET_LOCAL_ROOT" "$1"
  else
    printf 'https://github.com/%s/%s.git' "$(_verb_set_owner)" "$1"
  fi
}

_verb_set_remote_sha() {  # the sha `bashified` points to, empty if no such branch; `git ls-remote` needs no clone
  git ls-remote "$(_verb_set_remote_url "$1")" refs/heads/bashified 2>/dev/null \
    | awk 'NR==1{print $1}'
}

_verb_set_remote_tree() {  # "<mode> <path>" for the WHOLE tree at that sha -- empty means the read failed, not that bin/ is absent (#891's VERBLESS-IS-NOT-BLIND lesson)
  local repo="$1" sha="$2"
  if [ -n "${VERB_SET_LOCAL_ROOT:-}" ]; then
    git -C "$VERB_SET_LOCAL_ROOT/$repo" ls-tree -r "$sha" 2>/dev/null | awk '{print $1, $4}'
    return 0
  fi
  "${VERB_SET_GH:-gh}" api "repos/$(_verb_set_owner)/$repo/git/trees/$sha?recursive=1" \
    -q '.tree[] | "\(.mode) \(.path)"' 2>/dev/null
}

_verb_set_ref() {
  local d="$1" c
  for c in bashified origin/bashified; do
    git -C "$d" rev-parse --verify -q "$c^{commit}" >/dev/null 2>&1 && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# verb_set_is_exempt <project> <name> -- true if bin/lib/not-a-verb.tsv names it.
_verb_set_not_a_verb_file() { printf '%s' "${VERB_NOT_A_VERB_FILE:-$(dirname "${BASH_SOURCE[0]}")/not-a-verb.tsv}"; }
verb_set_is_exempt() {
  local f p="$1" n="$2"
  f="$(_verb_set_not_a_verb_file)"
  [ -f "$f" ] || return 1
  awk -F'\t' -v p="$p" -v n="$n" \
    '!/^[[:space:]]*#/ && $1 == p && $2 == n { found = 1; exit } END { exit !found }' "$f"
}

# verb_set_verbs_of <repo> <ref> -- an executable bin/<n> declares a verb,
# man/<n>.1 optional (#891), filtered through the same opt-out as every caller.
verb_set_verbs_of() {
  local repo="$1" ref="$2" project v url
  # THE REMOTE NAMES THE PROJECT; THE DIRECTORY IS NOT OBLIGED TO (#1194).
  # `project` keys not-a-verb.tsv, whose rows carry REPO names. Under the
  # estate's own agent layout the checkout is `hf7y__realisateur`, no row
  # matched, every exemption was silently lost, and this suite has been red in
  # every spawn checkout and green in CI -- so the only readers who saw the
  # failure were the ones for whom it was false. The lookup never failed; it
  # missed, which is why no message could name the reason.
  # Fall back to the basename: the suite's fixture repos have no remote.
  url="$(git -C "$repo" remote get-url origin 2>/dev/null)"
  [ -n "$url" ] && project="$(basename "${url%.git}")"
  [ -n "$project" ] || project="$(basename "$repo")"
  git -C "$repo" ls-tree -r "$ref" -- bin/ 2>/dev/null | awk '
    $1 == "100755" && $2 == "blob" && $4 ~ /^bin\/[^\/]+$/ { print substr($4, 5) }
  ' | sort | while IFS= read -r v; do
    [ -n "$v" ] || continue
    verb_set_is_exempt "$project" "$v" && continue
    printf '%s\n' "$v"
  done
}

# verb_set_ref_of <repo> -- print the bashified ref this repo declares from.
verb_set_ref_of() { _verb_set_ref "$1"; }

_VERB_SET_CACHE_KEY=""      # (owner, VERB_SET_LOCAL_ROOT) this sweep answered for
_VERB_SET_CACHE_RAW=""      # unfiltered by not-a-verb.tsv -- an exemption-file edit needs no re-sweep
_VERB_SET_CACHE_BLIND=0

_verb_set_fetch_raw() {  # one sweep of every repo; BLIND (a tree that did not read) is counted, never folded into "declares nothing"
  local owner="$1" repos repo sha tree v
  _VERB_SET_CACHE_KEY="$owner|${VERB_SET_LOCAL_ROOT:-}"
  _VERB_SET_CACHE_RAW=""
  _VERB_SET_CACHE_BLIND=0
  if ! repos="$(_verb_set_repos)" || [ -z "$repos" ]; then
    printf 'verb-set: BLIND -- cannot list %s'"'"'s repositories\n' "$owner" >&2
    _VERB_SET_CACHE_BLIND=1
    return 1
  fi
  local rows=""
  for repo in $repos; do
    sha="$(_verb_set_remote_sha "$repo")"
    [ -n "$sha" ] || continue   # no bashified branch -- a normal answer, most repos have none
    tree="$(_verb_set_remote_tree "$repo" "$sha")"
    if [ -z "$tree" ]; then
      printf 'verb-set: BLIND -- %s: bashified is %s but its tree did not read\n' "$repo" "$sha" >&2
      _VERB_SET_CACHE_BLIND=$((_VERB_SET_CACHE_BLIND + 1))
      continue
    fi
    while IFS= read -r v; do
      [ -n "$v" ] || continue
      rows="$rows$repo	$v"$'\n'
    done < <(printf '%s\n' "$tree" | awk '$1 == "100755" && $2 ~ /^bin\/[^\/]+$/ { print substr($2, 5) }' | sort)
  done
  _VERB_SET_CACHE_RAW="$(printf '%s' "$rows" | sort)"
  [ "$_VERB_SET_CACHE_BLIND" -eq 0 ]
}

# verb_set_declared -- every declaration, as <project>\t<verb>, sorted. Non-zero rc means BLIND: short by an unknown amount, see stderr.
verb_set_declared() {
  local owner project v rc=0 key
  owner="$(_verb_set_owner)"
  key="$owner|${VERB_SET_LOCAL_ROOT:-}"
  if [ "$_VERB_SET_CACHE_KEY" != "$key" ]; then
    _verb_set_fetch_raw "$owner" || rc=1
  elif [ "$_VERB_SET_CACHE_BLIND" -ne 0 ]; then
    rc=1
  fi
  [ -n "$_VERB_SET_CACHE_RAW" ] || return "$rc"
  while IFS=$'\t' read -r project v; do
    [ -n "$v" ] || continue
    verb_set_is_exempt "$project" "$v" && continue
    printf '%s\t%s\n' "$project" "$v"
  done <<< "$_VERB_SET_CACHE_RAW"
  return "$rc"
}

# verb_set_claimants <verb> -- which projects already declare this name.
# Empty output means unclaimed. This is the check `command -v` was standing in
# for, and unlike `command -v` it is true on a host where nothing is installed.
verb_set_claimants() {
  local want="$1"
  verb_set_declared | awk -F'\t' -v w="$want" '$2 == w {print $1}'
}

# verb_set_worktree_of <repo> -- where bashified is checked out, if anywhere.
# The same lookup `installe` does, so the two agree on a verb's target.
verb_set_worktree_of() {
  git -C "$1" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{w=$2} /^branch refs\/heads\/bashified$/{print w; exit}'
}
