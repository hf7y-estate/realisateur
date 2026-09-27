#!/usr/bin/env bash
# lib/registry-set.sh -- which repos is this estate answerable for? #932.
# TRAP: the registry names REPOS, ROSTER names PROJECTS, and `apms` is
#   `apms-2173` (#916) -- the roster half resolves through conf REPO_URL.
# TRAP: every function returns 6, never empty, when it could not look.

[ -n "${REGISTRY_SET_LIB:-}" ] && return 0
REGISTRY_SET_LIB=1

. "${BASH_SOURCE[0]%/*}/estate-set.sh"
. "${BASH_SOURCE[0]%/*}/arming.sh"

REGISTRY_MARKER="${REGISTRY_MARKER:-.agent-project}"
REGISTRY_GH="${REGISTRY_GH:-${GH_BIN:-gh}}"
REGISTRY_SCHED_REPO="${REGISTRY_SCHED_REPO:-scheduler}"
# CALL time: cut-verb-build.sh's --owner would not reach it otherwise.
registry_owner() { printf '%s' "${REGISTRY_OWNER:-$GH_ESTATE_OWNER}"; }

# THE OWNER IS AN ORGANIZATION SINCE 2026-09-24 (#672). `user(login:"hf7y-estate")`
# resolves to null, so this query returned nothing and every marker-derived
# sweep read the whole estate as absent -- could-not-look reported as a healthy
# empty registry, the one failure shape this lib returns 6 to prevent.
# `ownerAffiliations` is a user-only argument and is dropped with the change.
REGISTRY_SELECT='.data.organization.repositories.nodes[] | select(.marker != null and .isArchived == false)'

# registry_query [extra-node-fields]; registry-standup.sh passes that argument.
# shellcheck disable=SC2120
registry_query() {
  printf 'query($owner:String!){ organization(login:$owner){ repositories(first:100, isFork:false){ nodes{ name isArchived isPrivate marker: object(expression:"HEAD:%s"){ __typename } %s } } } }' \
    "$REGISTRY_MARKER" "${1:-}"
}

# registry_repos -- marker-carrying, non-archived repo names.
registry_repos() {
  local out
  out="$("$REGISTRY_GH" api graphql -F owner="$(registry_owner)" -f query="$(registry_query)" \
           --jq "$REGISTRY_SELECT | .name" 2>/dev/null)" || return 6
  [ -n "$out" ] || return 6
  printf '%s\n' "$out" | sort -u
}

# roster_projects -- "<project>\t<repo>\t<state>"; `_` confs are not projects.
roster_projects() {
  local q raw
  arming_load || return 6
  q='query($owner:String!,$repo:String!){ repository(owner:$owner,name:$repo){
       object(expression:"HEAD:schedule"){ ... on Tree { entries { name
         object { ... on Blob { text } } } } } } }'
  # REPO_URL comes out in jq: a tab record would lose the body's line breaks.
  raw="$("$REGISTRY_GH" api graphql -F owner="$(registry_owner)" -F repo="$REGISTRY_SCHED_REPO" -f query="$q" \
           --jq '.data.repository.object.entries[]?
                 | select(.name | endswith(".conf"))
                 | select(.name | startswith("_") | not)
                 | (.name | sub("\\.conf$"; "")) as $p
                 | ((.object.text // "") | [splits("\n")]
                    | map(select(startswith("REPO_URL="))) | last // "") as $u
                 | "\($p)\t\($u)"' 2>/dev/null)" || return 6
  [ -n "$raw" ] || return 6
  printf '%s\n' "$raw" | while IFS=$'\t' read -r p u; do
    [ -n "$p" ] || continue
    u="${u#REPO_URL=}"; u="${u%\"}"; u="${u#\"}"; u="${u%.git}"; u="${u##*/}"
    [ -n "$u" ] || u="$p"    # no REPO_URL: the project name is the best claim we have
    printf '%s\t%s\t%s\n' "$p" "$u" "$(arming_state "$p")"
  done | sort -u
}

# frame_repos -- marked or merely rostered. #800 step 1.
frame_repos() {
  local reg ros
  reg="$(registry_repos)" || return 6
  ros="$(roster_projects)" || return 6
  { printf '%s\n' "$reg"; printf '%s\n' "$ros" | cut -f2; } | grep . | sort -u
}

# frame_unenrolled -- rostered, dispatched to, and invisible to marker sweeps.
frame_unenrolled() {
  local reg ros
  reg="$(registry_repos)" || return 6
  ros="$(roster_projects)" || return 6
  comm -13 <(printf '%s\n' "$reg") <(printf '%s\n' "$ros" | cut -f2 | sort -u)
}
