#!/usr/bin/env bash
# selfdev-gh-app.sh -- mint a short-lived GitHub App installation token for a
# self-dev account, and prove GitHub answers to it.
#
# TRAPS (the rest of this header is in the vault):
# WHY THIS EXISTS. bin/wire-selfdev-git.sh gives a self-dev account per-repo
# deploy keys. Those grant ACCESS and confer no IDENTITY: a deploy-key push is
# attributed to whatever author string the commit carries, so agent work and
# human work are indistinguishable in `git log` and in the GitHub UI. Every
# rule in CLAUDE.md about a dirty tree, an unattributable push, or an
# autocommit adopting an agent's edit "under a human's name" is downstream of
# that one missing distinction. A GitHub App installation has its own actor --
# `<app-slug>[bot]` -- so the attribution is made by GitHub, not asserted by
# the committer, and cannot be spoofed by setting user.email.

set -uo pipefail

# GIT APPENDS AN OPERATION TO ITS CREDENTIAL HELPER, AND THIS PARSER USED TO
# DIE ON IT.
#
# `git config credential.helper "!<cmd>"` is invoked by git as
# `<cmd> <operation>`, where operation is `get`, `store` or `erase`. So the
# helper wired by `--wire` actually runs as:
#
#     selfdev-gh-app.sh --credential get
#
MODE="--check"; REPOS=""; ADOPT_ACCOUNT=""; ADOPT_KEY=""; ADOPT_ID=""; GIT_OP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check|--token|--identity|--credential|--wire|--jwt|--adopt) MODE="$1" ;;
    get|store|erase)
      # Accepted ONLY after --credential. A bare `get` with no mode is not a
      # git invocation at all, and treating it as one would make a typo mint a
      # token. The refusal below still catches it.
      [ "$MODE" = "--credential" ] || { echo "$0: '$1' is a git credential operation and is only accepted after --credential" >&2; exit 2; }
      GIT_OP="$1" ;;
    --repos) REPOS="${2:-}"; shift ;;
    --repos=*) REPOS="${1#--repos=}" ;;
    --account) ADOPT_ACCOUNT="${2:-}"; shift ;;
    --key)     ADOPT_KEY="${2:-}"; shift ;;
    --app-id)  ADOPT_ID="${2:-}"; shift ;;
    -h|--help) sed -n '2,/^set -/p' "$0" | sed 's/^# \{0,1\}//;$d'; exit 0 ;;
    *) echo "usage: $0 [--check|--token|--identity|--credential|--wire|--jwt] [--repos a,b]" >&2
       echo "       $0 --adopt --account <name> --key <file.pem> --app-id <id>" >&2; exit 2 ;;
  esac
  shift
done

_sd_lib="$(dirname "${BASH_SOURCE[0]}")/lib/selfdev-app-key.sh"
[ -r "$_sd_lib" ] || _sd_lib="$(dirname "${BASH_SOURCE[0]}")/selfdev-app-key.sh"
if [ -r "$_sd_lib" ]; then
  # shellcheck source=lib/selfdev-app-key.sh
  . "$_sd_lib"
  CONF="$(selfdev_app_conf)"
else
  # No lib beside us: fall back to the same host-wide default it declares,
  # rather than to a per-account path that no longer exists. Stated, not silent.
  CONF="${SELFDEV_APP_CONF:-/etc/selfdev/gh-app.conf}"
  SELFDEV_APP_PEM_DEFAULT=/etc/selfdev/app.pem
fi
# The environment is captured BEFORE the config file is sourced, because
# sourcing it would otherwise clobber the very variables it is supposed to
# default. Sourced-file-wins is the opposite of the documented contract and is
# invisible until a scheduler job carrying a different App silently runs as the
# one in the file -- with the right permissions on the wrong repos.
_env_app_id="${SELFDEV_APP_ID:-}"
_env_app_key="${SELFDEV_APP_KEY:-}"
_env_owner="${SELFDEV_GH_OWNER:-}"
# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"
APP_ID="${_env_app_id:-${SELFDEV_APP_ID:-}}"
APP_KEY="${_env_app_key:-${SELFDEV_APP_KEY:-${SELFDEV_APP_PEM_DEFAULT:-/etc/selfdev/app.pem}}}"
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/estate-set.sh"
OWNER="${_env_owner:-${SELFDEV_GH_OWNER:-$GH_ESTATE_OWNER}}"
API="${SELFDEV_GH_API:-https://api.github.com}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/selfdev-gh-app"

PASS=0; GAPS=0; BAD=0
ok()  { printf '  OK      %s\n' "$*"; PASS=$((PASS+1)); }
gap() { printf '  MISSING %s\n' "$*"; GAPS=$((GAPS+1)); }
bad() { printf '  BAD     %s\n' "$*"; BAD=$((BAD+1)); }
die() { printf '%s: FATAL: %s\n' "${0##*/}" "$*" >&2; exit 5; }

for _r in ${REPOS//,/ }; do  # bare names only: owner/repo 422s opaquely against access_tokens (#1069)
  case "${_r,,}" in
    "${OWNER,,}"/*) die "--repos entry '$_r' is owner-qualified -- drop the '${_r%%/*}/' prefix, GitHub wants bare repo names (e.g. '${_r#*/}')" ;;
  esac
done

# --- the JWT -----------------------------------------------------------------
# RS256 by hand rather than a library, because the whole point of this script is
# that a self-dev account can mint its own credential with nothing but openssl,
# curl and jq -- all three of which every host in this ecosystem already has,
# and none of which needs a package install on a fresh uid-3000 account.
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

app_jwt() {
  [ -n "$APP_ID" ] || die "SELFDEV_APP_ID is unset (looked in \$SELFDEV_APP_ID and $CONF)"
  [ -r "$APP_KEY" ] || die "private key not readable at $APP_KEY -- generate one on the App's settings page and save it there, chmod 600"
  local now hdr pay signing sig
  now="$(date +%s)"
  # iat backdated 60s: GitHub rejects a JWT whose iat is in ITS future, and
  # host clocks in this estate have drifted before.
  hdr='{"alg":"RS256","typ":"JWT"}'
  pay="{\"iat\":$((now - 60)),\"exp\":$((now + 540)),\"iss\":\"$APP_ID\"}"
  signing="$(printf '%s' "$hdr" | b64url).$(printf '%s' "$pay" | b64url)"
  sig="$(printf '%s' "$signing" | openssl dgst -sha256 -sign "$APP_KEY" -binary | b64url)" \
    || die "openssl could not sign with $APP_KEY -- is it the App's PKCS#1 .pem?"
  [ -n "$sig" ] || die "empty signature from openssl -- $APP_KEY is not a usable private key"
  printf '%s.%s' "$signing" "$sig"
}

# api <method> <path> <bearer> [body]  -- prints the response body, exits
# non-zero on HTTP >= 400 and says WHICH call failed with WHAT GitHub said. A
# silent 401 here is the defect this ecosystem keeps rediscovering:
# configuration is not capability.
api() {
  local method="$1" path="$2" auth="$3" body="${4:-}" out code
  out="$(curl -sS -w '\n%{http_code}' -X "$method" \
      -H "Authorization: Bearer $auth" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      ${body:+-d "$body"} \
      "$API$path")" || { echo "curl failed: $method $path" >&2; return 1; }
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  if [ "$code" -ge 400 ]; then
    printf 'github %s %s -> HTTP %s: %s\n' "$method" "$path" "$code" \
      "$(printf '%s' "$out" | jq -r '.message // .' 2>/dev/null || printf '%s' "$out")" >&2
    return 1
  fi
  printf '%s' "$out"
}

installation_id() {
  local jwt="$1" json
  json="$(api GET /app/installations "$jwt")" || return 1
  printf '%s' "$json" | jq -r --arg o "$OWNER" \
    '[.[] | select(.account.login | ascii_downcase == ($o | ascii_downcase))] | .[0].id // empty'
}

# --- the token, with a cache -------------------------------------------------
# Cached because git invokes a credential helper on EVERY remote operation, and
# minting per operation would turn one push into three round trips and three
mint_token() {
  local jwt inst body cache now exp
  cache="$CACHE_DIR/$(printf '%s|%s|%s' "$APP_ID" "$OWNER" "$REPOS" | openssl dgst -sha256 -hex | awk '{print $NF}').tok"
  if [ -r "$cache" ]; then
    now="$(date +%s)"; exp="$(head -1 "$cache")"
    case "$exp" in
      ''|*[!0-9]*) : ;;
      *) [ "$now" -lt $((exp - 300)) ] && { tail -n +2 "$cache"; return 0; } ;;
    esac
  fi
  jwt="$(app_jwt)" || return 1
  inst="$(installation_id "$jwt")" || return 1
  [ -n "$inst" ] || die "the App is not installed on '$OWNER' -- open the App's Install App tab and install it, then re-run --check"
  if [ -n "$REPOS" ]; then
    body="$(printf '%s' "$REPOS" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$";"")) | {repositories: .}')"
  else
    body=""
  fi
  local json tok
  json="$(api POST "/app/installations/$inst/access_tokens" "$jwt" "$body")" || return 1
  tok="$(printf '%s' "$json" | jq -r '.token // empty')"
  [ -n "$tok" ] || die "GitHub returned no token for installation $inst"
  exp="$(printf '%s' "$json" | jq -r '.expires_at // empty')"
  mkdir -p "$CACHE_DIR" && chmod 700 "$CACHE_DIR"
  # Written 600 BEFORE the secret goes in, not after: a world-readable instant
  # is still a leak, and this file is a bearer credential.
  ( umask 077; printf '%s\n%s' "$(date -d "$exp" +%s 2>/dev/null || echo 0)" "$tok" > "$cache" )
  printf '%s' "$tok"
}

# ============================================================================
# AUTHOR AND PUSHER ARE TWO LAYERS, AND --wire USED TO CONFLATE THEM
# ============================================================================
SELFDEV_EMAIL_DOMAIN="${SELFDEV_EMAIL_DOMAIN:-selfdev.invalid}"

account_identity() {
  local acct; acct="$(id -un)" || return 1
  [ -n "$acct" ] || return 1
  printf '%s\n%s@%s\n' "$acct" "$acct" "$SELFDEV_EMAIL_DOMAIN"
}

# --- the BOT identity: the PUSHER half, printed by --identity ----------------
# The actor GitHub attributes the PUSH to, never written into git's author
# fields. That email shape is the only one GitHub links back to the bot.
bot_identity() {
  local jwt slug uid
  jwt="$(app_jwt)" || return 1
  slug="$(api GET /app "$jwt" | jq -r '.slug // empty')" || return 1
  [ -n "$slug" ] || return 1
  uid="$(curl -sS -H "Accept: application/vnd.github+json" "$API/users/$slug%5Bbot%5D" | jq -r '.id // empty')"
  [ -n "$uid" ] || { echo "could not resolve the bot user id for ${slug}[bot]" >&2; return 1; }
  printf '%s[bot]\n%s+%s[bot]@users.noreply.github.com\n' "$slug" "$uid" "$slug"
}

case "$MODE" in
  --adopt)
    # Take a freshly downloaded .pem plus an App ID and produce a wired,
    # PROVEN account config. Exists because this runs once per self-dev
    # account and the hand version is four commands with two chances to leave
    # a bearer credential world-readable -- which the very first real key
    # already did (mode 664 out of the browser, 2026-08-07).
    [ -n "$ADOPT_ACCOUNT" ] || die "--adopt needs --account <name>"
    [ -n "$ADOPT_KEY" ]     || die "--adopt needs --key <file.pem>"
    [ -r "$ADOPT_KEY" ]     || die "cannot read key file: $ADOPT_KEY"
    [ -n "$ADOPT_ID" ]      || die "--adopt needs --app-id <id> (App ID or Client ID; both work as the JWT issuer)"

    # Prove it is a private key BEFORE moving it anywhere. A truncated or
    # HTML-error download is still a file, and every later failure would
    # present as a GitHub 401.
    openssl rsa -in "$ADOPT_KEY" -noout -check >/dev/null 2>&1 \
      || die "$ADOPT_KEY is not a valid RSA private key -- re-download it"
    fp="$(openssl rsa -in "$ADOPT_KEY" -pubout -outform DER 2>/dev/null | openssl sha256 -binary | openssl base64)"
    ok "key is a valid RSA private key"
    ok "fingerprint: $fp"
    echo "          ^ must equal the SHA256: shown on the App's settings page"

    # ADOPT INVENTS NO PATH: one App key under four names is what that cost.
    if [ "$(id -u)" -eq 0 ] && [ -x "$(dirname "${BASH_SOURCE[0]}")/selfdev-app-key.sh" ]; then
      "$(dirname "${BASH_SOURCE[0]}")/selfdev-app-key.sh" --apply --from "$ADOPT_KEY" --app-id "$ADOPT_ID" --owner "$OWNER" \
        || die "selfdev-app-key.sh --apply refused; the key was NOT installed"
      dir="$SELFDEV_APP_DIR"
    else
      die "adopting a key places it host-wide in ${SELFDEV_APP_DIR:-/etc/selfdev} and needs root:
    sudo bin/selfdev-app-key.sh --apply --from $ADOPT_KEY --app-id $ADOPT_ID"
    fi
    echo
    # Re-exec rather than duplicate the witness. A second copy of this logic
    # is a second thing to keep true.
    exec env SELFDEV_APP_CONF="${SELFDEV_APP_CONF_DEFAULT:-/etc/selfdev/gh-app.conf}" \
         SELFDEV_APP_ID= SELFDEV_APP_KEY= SELFDEV_GH_OWNER= "$0" --check
    ;;

  --jwt)
    # The App JWT, unexchanged. Exists because GitHub answers a malformed one
    # with a bare 401 that is indistinguishable from a revoked key -- with this
    # you can decode the payload and see which it is. Lives ~9 minutes and
    # grants nothing but the App-level endpoints; the test suite verifies its
    # signature against a throwaway public key through this mode.
    app_jwt || exit 5
    echo
    ;;

  --token)
    mint_token || exit 5
    echo
    ;;

  --identity)
    bot_identity || exit 5
    ;;

  --credential)
    # git credential protocol: read key=value lines on stdin, answer in kind.
    # Git's request is drained and ignored on purpose: the helper is configured
    # per-host in --wire, so there is nothing left to decide from the input, and
    # a helper that does not read its stdin leaves git writing into a closed pipe.
    while IFS= read -r line; do [ -z "$line" ] && break; done
    case "$GIT_OP" in
      store|erase)
        # NO-OPS BY DESIGN, and they must exit 0: nothing to store (the token is
        # minted on demand) or erase, and git ignores a helper's output here but
        # DOES notice a non-zero exit -- which would fail every push.
        exit 0 ;;
      get|'')
        # `''` is the hand-run form (`selfdev-gh-app.sh --credential`), kept
        # so an operator can still exercise the helper from a terminal exactly
        # as it was documented before git's operation argument was honoured.
        tok="$(mint_token)" || exit 5
        printf 'username=x-access-token\npassword=%s\n' "$tok"
        ;;
      *)
        # Unreachable through the parser above, and left loud anyway: a future
        # git operation this helper does not understand must not be answered
        # with a token.
        echo "$0: unknown git credential operation: $GIT_OP" >&2; exit 2 ;;
    esac
    ;;

  --wire)
    self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    # This --repos is the scope of every token the account mints; omitted, that
    # is the whole installation -- 53 repos, 2026-08-27. Never defaulted (#671).
    # The conf --wire was run against rides in the helper line, as --repos does:
    # at git time the helper otherwise reads the host-wide default, which names
    # the wrong installation for an account in a second org (#1225).
    want_helper="!${SELFDEV_APP_CONF:+env SELFDEV_APP_CONF='$SELFDEV_APP_CONF' }'$self'${REPOS:+ --repos '$REPOS'} --credential"
    git config --global --unset-all credential."https://github.com".helper 2>/dev/null
    git config --global --add credential."https://github.com".helper "$want_helper"
    git config --global credential."https://github.com".useHttpPath false
    got_helper="$(git config --global --get-all credential."https://github.com".helper)"
    if [ "$got_helper" = "$want_helper" ]; then
      if [ -n "$REPOS" ]; then
        ok "git credential helper -> $self --credential (scoped to: $REPOS)"
      else
        ok "git credential helper -> $self --credential (UNSCOPED -- mints a token for every repo the App is installed on; pass --repos to narrow it, #671)"
      fi
    else
      bad "git config accepted the helper write but re-reading gives '$got_helper'"
    fi

    if ident="$(account_identity)"; then
      want_name="$(printf '%s' "$ident" | sed -n 1p)"
      want_mail="$(printf '%s' "$ident" | sed -n 2p)"
      have_name="$(git config --global --get user.name  || true)"
      have_mail="$(git config --global --get user.email || true)"

      # DO NOT CLOBBER SILENTLY: the value --wire overwrote on ecosim@monkey
      # is unrecoverable, because the old version wrote without reading. The
      # previous value is now read, reported and preserved under selfdev.*
      # BEFORE any write, and written ONCE so a re-run cannot overwrite the
      # original with --wire's own value.
      if [ -n "$have_name$have_mail" ] && \
         { [ "$have_name" != "$want_name" ] || [ "$have_mail" != "$want_mail" ]; }; then
        if [ -z "$(git config --global --get selfdev.previousUserName || true)" ] && \
           [ -z "$(git config --global --get selfdev.previousUserEmail || true)" ]; then
          git config --global selfdev.previousUserName  "$have_name"
          git config --global selfdev.previousUserEmail "$have_mail"
          git config --global selfdev.previousUserSavedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          ok "preserved the previous identity: git config --global selfdev.previousUserName/Email"
        else
          ok "a previous identity was already preserved; not overwriting the backup"
        fi
        # Loud, and it names both values. A replacement an operator cannot see
        # in the output is a replacement they will find out about from a
        # `git log` six weeks later.
        gap "REPLACING the global git identity on $(id -un)@$(hostname -s 2>/dev/null || echo '?'):"
        gap "  was:  ${have_name:-<unset>} <${have_mail:-<unset>}>"
        gap "  now:  $want_name <$want_mail>"
        case "$have_name" in
          *'[bot]') gap "  the previous value was an App bot slug -- this is the fleet-identity"
                    gap "  bug being corrected: one App across ten accounts made every account"
                    gap "  author identically, so 'which agent did this' had no answer." ;;
        esac
        gap "  restore with: git config --global user.name \"\$(git config --global selfdev.previousUserName)\""
      fi

      git config --global user.name  "$want_name"
      git config --global user.email "$want_mail"
      # WITNESS: read it back out of git, not out of the variable just written.
      got_name="$(git config --global --get user.name  || true)"
      got_mail="$(git config --global --get user.email || true)"
      if [ "$got_name" = "$want_name" ] && [ "$got_mail" = "$want_mail" ]; then
        ok "git AUTHOR -> $got_name <$got_mail>   (the account: git log answers 'which agent')"
      else
        bad "git config accepted the write but re-reading gives '$got_name <$got_mail>'"
      fi
    else
      bad "could not resolve the account identity from \`id -un\` -- credential helper is wired, git author is NOT"
    fi

    # THE PUSHER HALF. Nothing to configure: GitHub attributes the push to the
    # App actor because of the CREDENTIAL, not because of any git setting.
    # Resolved here only so the operator can see both layers in one output and
    # confirm they are different on purpose.
    if bident="$(bot_identity 2>/dev/null)"; then
      ok "git PUSHER -> $(printf '%s' "$bident" | sed -n 1p)   (the App: GitHub attributes the push, no config needed)"
    else
      gap "git PUSHER -> could not resolve the App actor for display. This does NOT affect pushes: GitHub attributes them from the CREDENTIAL, not from any git setting, so the pusher layer is wired whether or not this line can name it."
    fi
    # url.insteadOf from wire-selfdev-git.sh rewrites github.com onto per-repo
    # ssh aliases. Where both are wired, ssh WINS and this helper is never
    # consulted -- silently. Say so rather than let it look wired.
    # REMOVED, NOT REPORTED: ssh wins over the helper otherwise (#171).
    removed=0
    while read -r sect; do
      [ -n "$sect" ] || continue
      git config --global --remove-section "$sect" 2>/dev/null && removed=$((removed + 1))
    done < <(git config --global --get-regexp '^url\..*github-.*\.insteadof$' \
             | awk '{print $1}' | sed 's/\.insteadof$//' | sort -u)
    [ "$removed" -gt 0 ] && ok "removed $removed deploy-key url.insteadOf rewrite(s) -- https now reaches the helper"

    for _d in "$HOME"/Documents/Projects/*/; do
      [ -d "$_d/.git" ] || continue
      _u="$(git -C "$_d" remote get-url origin 2>/dev/null)" || continue
      case "$_u" in
        git@github-*:*|git@github.com:*)
          _slug="${_u#*:}"; _slug="${_slug%.git}"
          git -C "$_d" remote set-url origin "https://github.com/$_slug.git" \
            && ok "$(basename "$_d") origin -> https://github.com/$_slug.git" ;;
      esac
    done
    printf '\nwired: %d ok, %d missing, %d bad\n' "$PASS" "$GAPS" "$BAD"
    [ "$BAD" -eq 0 ] || exit 5
    ;;

  --check)
    echo "== selfdev-gh-app --check -- $(id -un)@$(hostname -s 2>/dev/null || echo unknown) =="
    [ -r "$CONF" ] && ok "config $CONF" || gap "no config at $CONF (env vars may still supply it)"
    [ -n "$APP_ID" ] && ok "app id $APP_ID" || gap "SELFDEV_APP_ID unset -- the App ID is on the App's settings page"
    if [ -r "$APP_KEY" ]; then
      perm="$(stat -c %a "$APP_KEY" 2>/dev/null || echo '?')"
      keygrp="$(stat -c %G "$APP_KEY" 2>/dev/null || echo '?')"
      # 640/selfdev is not a looser rule than 600 -- it is the SAME property
      # (unreadable outside the intended readers) applied to the host-wide
      # key, which multiple accounts in the `selfdev` group must read by
      # design; per-account copies were retired in favour of it. World bits
      # must still be zero in every case, so 644/646/etc still fail below.
      case "$perm" in
        600|400) ok "private key $APP_KEY (mode $perm)" ;;
        640|440)
          if [ "$keygrp" = selfdev ]; then
            ok "private key $APP_KEY (mode $perm, group $keygrp -- host-wide key, readable only within the selfdev group)"
          else
            bad "private key $APP_KEY is mode $perm and group is '$keygrp', not selfdev -- group-readable is only correct for the shared host-wide key; a private key must be 600"
          fi
          ;;
        *) bad "private key $APP_KEY is mode $perm -- a bearer key must be 600 (or 640, group selfdev, for the shared host-wide key)" ;;
      esac
    else
      gap "no private key at $APP_KEY -- generate one on the App's settings page (Private keys -> Generate a private key) and save it there"
    fi
    for c in openssl curl jq; do
      command -v "$c" >/dev/null && ok "$c present" || bad "$c missing -- this script cannot mint without it"
    done

    # The witness. Everything above is a file on disk; this is GitHub answering.
    if [ -n "$APP_ID" ] && [ -r "$APP_KEY" ]; then
      if jwt="$(app_jwt 2>/dev/null)" && slug="$(api GET /app "$jwt" 2>/dev/null | jq -r '.slug // empty')" && [ -n "$slug" ]; then
        ok "WITNESS: GitHub authenticated the App as '$slug'"
        inst="$(installation_id "$jwt" 2>/dev/null)"
        if [ -n "$inst" ]; then
          ok "installed on $OWNER (installation $inst)"
          if tok="$(mint_token 2>/dev/null)" && [ -n "$tok" ]; then
            n="$(curl -sS -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json" \
                 "$API/installation/repositories?per_page=100" | jq -r '.total_count // 0')"
            ok "WITNESS: installation token minted, $n repo(s) in scope"
            if ident="$(bot_identity 2>/dev/null)"; then
              ok "bot identity: $(printf '%s' "$ident" | sed -n 1p) <$(printf '%s' "$ident" | sed -n 2p)>"
            else
              gap "bot user not resolvable yet -- normal until the App has been installed for a moment"
            fi
          else
            bad "WITNESS FAILED: App authenticates but no installation token could be minted"
          fi
        else
          gap "the App is not installed on '$OWNER' -- Install App tab, pick the repos, then re-run"
        fi
      else
        bad "WITNESS FAILED: GitHub did not accept the App JWT -- wrong App ID, wrong key, or a revoked key"
      fi
    fi

    printf '\ncheck only, nothing changed: %d ok, %d missing, %d bad\n' "$PASS" "$GAPS" "$BAD"
    [ "$GAPS" -eq 0 ] && [ "$BAD" -eq 0 ] && echo "wired. Next: $0 --wire (on the self-dev account)" \
      || echo "not wired yet -- clear the MISSING/BAD lines above."
    [ "$BAD" -eq 0 ] || exit 5
    ;;
esac
exit 0
