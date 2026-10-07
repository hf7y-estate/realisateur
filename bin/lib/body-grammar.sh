#!/usr/bin/env bash
# lib/body-grammar.sh -- the grammar of an agent-written issue or PR body.
# Sourced by bin/gh-sign.sh, which refuses a noncompliant body at the write.
# Pure bash: gh-sign runs under cron's PATH, where sed and grep were not found.
#
#   UNDECLARED          line 1 is neither DECISION: nor NO-DECISION:
#   NO-DECIDER          DECISION: named no @handle. NO-DECISION: is exempt (#419)
#   MISPLACED-DECISION  a declaration below line 1
#   UNLEDGERED          no <!-- DEFERRED --> block
#   MULTI-LEDGER        more than one
#   UNCLOSED            opened, never closed
#   EMPTY-LEDGER        no entries; write "- none"
#   NO-DESTINATION      an entry naming no issue and no URL
#   UNSHIPPED           no <!-- DELIVERS --> block
#   MULTI-SHIP          more than one
#   EMPTY-SHIP          no entries; write "- none"
#   UNTYPED-DELIVERY    an entry naming no <kind>:<value>
#   BAD-DEFAULT         a DEFAULT-AFTER line that is not `<n>d: <action>`
#   BAD-ANSWERED-BY     an ANSWERED-BY line that is not `<owner>/<repo>#<n>`
#   NO-DEFAULT          a DECISION: body carrying no DEFAULT-AFTER at all
#   BAD-POLICY          a POLICY: line that names no class and no "none yet"
#   NO-POLICY           a DECISION: body carrying no POLICY: line at all
#   NEGATED-CLOSE       a closing keyword + reference in a sentence DENYING it
#   PARTIAL-CLOSE       a closing keyword whose reference a qualifier SCOPES
#
# DEFAULT-AFTER -- MANDATORY ON A DECISION SINCE #680 (Zach, 2026-08-28),
# because 21 of 45 open `needs-human` blocked by omission. Past the window the
# owning account applies it, says so, and leaves the issue open to be
# reversed; `0d: block` keeps blocking forever legal once DECLARED. Only
# gh-sign's SIGNING path reaches this, so it binds agents, not Zach.
#
# POLICY: -- MANDATORY ON A DECISION SINCE #1621 (realisateur#1573, split from
# it). Zach, 2026-10-06: "the ruling is there should not be repo-specific
# requests being routed to me... this only surfaces to me if a policy doesn't
# yet exist for the general class. I can't touch each repo like this." A
# `DECISION:` line asks a repo-specific question; `POLICY:` names the general
# class it stands in for, so a reader (or a future check) can tell a genuinely
# new policy gap from the same class asked again. `POLICY: none yet` is the
# honest spelling when no such policy exists -- the same shape as
# `DEFAULT-AFTER 0d: block` declaring a forever-block instead of omitting it.
#
# NO-OWNER: is not a destination -- #327 lost two that way. `defere` files one.
#
# NEGATED-CLOSE -- the parser reads the KEYWORD, not the sentence. Under a
# heading titled "What this is not", hf7y/scheduler#180 said it did NOT close
# scheduler#79; GitHub shut the ROSTER consolidation anyway. A BARE reference
# shuts nothing, so the remedy is to drop the verb -- which is why this is NOT
# a ban (Zach 2026-08-04: batch agents shut shipped issues automatically).
#
# PARTIAL-CLOSE -- the same principle for a qualifier. "Closes the mount half
# of hf7y/crt#195" denies nothing, and GitHub shut the whole of #195 from it.
# The remedy is the same bare `#N`.

GRAMMAR_DECIDER_RE='@[A-Za-z0-9][-A-Za-z0-9_/]*'
GRAMMAR_CLOSING_WORDS=' close closes closed closing fix fixes fixed fixing resolve resolves resolved resolving '

GRAMMAR_SCOPING_WORDS=' half halves part parts partial partially partly portion some most '

_grammar_unquote() {  # <line> -- the line with its code spans dropped
  local text="$1" out=''
  while [ -n "$text" ]; do   # a code span is a quotation, not a close
    case "$text" in *'`'*) ;; *) out="$out$text"; break ;; esac
    out="$out${text%%'`'*}"; text="${text#*'`'}"
    case "$text" in
      *'`'*) text="${text#*'`'}" ;;
      *)     out="$out$text"; break ;;   # unterminated: it is literal text
    esac
  done
  printf '%s' "$out"
}

_grammar_is_ref() {
  case "$1" in
    '#'[0-9]*) ;;                                    # bare #79 -- with a verb
    *[a-zA-Z0-9]/[a-zA-Z0-9]*'#'[0-9]*) ;;           # hf7y/scheduler#79
    *://*/issues/[0-9]*|*://*/pull/[0-9]*) ;;        # the full URL
    *) return 1 ;;
  esac
}

grammar_negated_close() {  # <line> <heading-negates> -- print "<keyword> <ref>", 1 if clean
  local text="$1" heading_negates="$2" out words=() i w ref prefix=''
  local IFS=$' \t\n'

  out="$(_grammar_unquote "$text")"
  read -ra words <<<"$out"
  for ((i = 0; i < ${#words[@]} - 1; i++)); do
    w="${words[i],,}"; w="${w%:}"; w="${w%,}"
    case "$GRAMMAR_CLOSING_WORDS" in *" $w "*) ;; *) prefix="$prefix$w "; continue ;; esac
    ref="${words[i + 1]}"
    _grammar_is_ref "$ref" || { prefix="$prefix$w "; continue; }
    if [ "$heading_negates" -eq 1 ]; then :
    else case "$prefix" in   # `not ` covers "does not", "do not", "cannot"
        *'not '*|*"doesn't "*|*"don't "*|*"won't "*|*'never '*|*'without '*|\
        *'rather than '*|*'instead of '*|*'no longer '*) ;;
        *) prefix="$prefix$w "; continue ;;
      esac
    fi
    printf '%s %s\n' "$w" "$ref"
    return 0
  done
  return 1
}

grammar_partial_close() {  # <line> -- print "<keyword> ... <ref>", 1 if clean
  local out words=() i j w q ref prev=''
  local IFS=$' \t\n'

  out="$(_grammar_unquote "$1")"
  read -ra words <<<"$out"
  for ((i = 0; i < ${#words[@]} - 1; i++)); do
    w="${words[i],,}"; w="${w%:}"; w="${w%,}"
    case "$GRAMMAR_CLOSING_WORDS" in *" $w "*) ;; *) prev="$w"; continue ;; esac
    # "Partially fixes #5": the adverb right before the keyword scopes it.
    # "Closes the mount half of #195": a qualifier between keyword and ref does.
    q=" $prev "; prev="$w"
    for ((j = i + 1; j < ${#words[@]}; j++)); do
      ref="${words[j]%[.,;:)]}"
      if _grammar_is_ref "$ref"; then
        for w in $GRAMMAR_SCOPING_WORDS; do
          case "$q" in *" $w "*) printf '%s ... %s\n' "${words[i]}" "$ref"; return 0 ;; esac
        done
        break
      fi
      case "$GRAMMAR_CLOSING_WORDS" in *" ${words[j],,} "*) break ;; esac
      case "${words[j]}" in *[.,\;:]) break ;; esac
      q="$q ${words[j],,} "
    done
  done
  return 1
}

# grammar_landing_ref <text> -- print the first thing <text> names that a check
# could go and look at, 1 when it names none. gh-sign's `issue close` guard
# asks it of a close comment: closing having landed nothing is this estate's
# largest measured class (#752), and prose cannot be followed -- the same
# argument UNTYPED-DELIVERY makes about DELIVERS. Four shapes, all already
# written here daily: `#N`/`owner/repo#N`/an issue-pull-commit URL, a 7-40
# char hex commit, a typed <kind>:<value>, a `code span` naming a path. The
# span looks arbitrary and is not -- over 1,348 real closes, dropping it takes
# the guard from 49 refusals to 91, and all 42 it acquits are honest (#778).
grammar_landing_ref() {
  local text="$1" words=() w seg rest
  local IFS=$' \t\n'

  # `-d ''` IS LOAD-BEARING: bare `read -ra` stops at the first newline, which
  # is correct above only because grammar_check hands it one line at a time.
  read -rd '' -a words <<<"$text" || :
  for w in "${words[@]}"; do
    w="${w//\`/}"; w="${w%[.,;:)]}"
    case "$w" in
      '#'[0-9]*|*[a-zA-Z0-9]/[a-zA-Z0-9]*'#'[0-9]*) printf '%s\n' "$w"; return 0 ;;
      *://*/pull/[0-9]*|*://*/issues/[0-9]*|*://*/commit/*) printf '%s\n' "$w"; return 0 ;;
      *host:*|*path:*|*clock:*|*tag:*|*secret:*|*unit:*|*port:*|*repo:*) printf '%s\n' "$w"; return 0 ;;
    esac
    case "$w" in                      # a commit: hex only, and never all digits
      *[!0-9a-f]*) ;;
      *[a-f]*) [ "${#w}" -ge 7 ] && [ "${#w}" -le 40 ] && { printf '%s\n' "$w"; return 0; } ;;
    esac
  done

  rest="$text"                        # same walk as grammar_negated_close
  while :; do
    case "$rest" in *'`'*) ;; *) return 1 ;; esac
    rest="${rest#*\`}"
    case "$rest" in
      *'`'*) seg="${rest%%\`*}"; rest="${rest#*\`}" ;;
      *) return 1 ;;
    esac
    case "$seg" in
      *[A-Za-z0-9_-][/.][A-Za-z0-9_-]*) printf '%s\n' "$seg"; return 0 ;;
    esac
  done
}

# grammar_delivers <body> -- one DELIVERS entry per line, marker stripped and
# continuations joined; 1 when there are none. THE SAME WALK AS _judge_ship:
# atteste.sh grades what this emits, and a second parser is a second grammar.
grammar_delivers() {
  local body="$1" line stripped indent in_ship=0 ship='' n=0 fenced=0
  _gd_emit() { [ -n "$ship" ] || return 0; printf '%s\n' "$ship"; n=$((n + 1)); ship=''; }
  while IFS= read -r line; do
    case "$line" in '```'*) fenced=$((1 - fenced)); continue ;; esac
    [ "$fenced" -eq 1 ] && continue
    stripped="${line#"${line%%[![:space:]]*}"}"
    indent="${line%%[![:space:]]*}"
    if [ "${#indent}" -ge 4 ]; then      # indented four, a marker is an EXAMPLE
      case "$stripped" in *'<!--'*'DELIVERS'*'-->'*) continue ;; esac
    fi
    case "$stripped" in
      '<!-- DELIVERS -->'|'<!--DELIVERS-->')   in_ship=1; continue ;;
      '<!-- /DELIVERS -->'|'<!--/DELIVERS-->') _gd_emit; in_ship=0; continue ;;
    esac
    [ "$in_ship" -eq 1 ] || continue
    case "$stripped" in
      '- '*|'* '*|[0-9]*'. '*) _gd_emit; ship="${stripped#* }" ;;
      '')                      _gd_emit ;;
      *) [ -n "$ship" ] && ship="$ship $stripped" ;;
    esac
  done <<<"$body"
  _gd_emit
  [ "$n" -gt 0 ]
}

# grammar_header <body> -- print the body with fenced blocks, `>` quotes and
# <details> blocks removed: the lines a declaration can live in. #1324: a
# <details> block is how a body keeps an answered DECISION's original text
# readable while collapsed, and it is quoted history the same as a fence or a
# `>` quote -- grammar_default_after and grammar_answered_by must not read a
# live declaration out of one, or a demoted body's superseded default gets
# actuated as if it were still open. THE SAME WALK grammar_check makes over
# the raw body (it skips a fence and a quote inline, for line numbers), so a
# second parser here cannot drift from the first.
grammar_header() {
  local body="$1" line stripped fenced=0 details=0
  while IFS= read -r line; do
    case "$line" in '```'*) fenced=$((1 - fenced)); continue ;; esac
    [ "$fenced" -eq 1 ] && continue
    stripped="${line#"${line%%[![:space:]]*}"}"
    case "${stripped,,}" in
      '<details'*)  details=1; continue ;;
      '</details>'*) details=0; continue ;;
    esac
    [ "$details" -eq 1 ] && continue
    case "$stripped" in '>'*) continue ;; esac
    printf '%s\n' "$line"
  done <<<"$body"
}

# grammar_default_after <body> -- print "<days><TAB><action>" and return 0 when
# the body carries a well-formed DEFAULT-AFTER; return 1 when it carries none.
# Pure bash: this runs wherever gh-sign runs, and sed/grep were not on that PATH.
grammar_default_after() {
  local line stripped rest days action
  while IFS= read -r line; do
    stripped="${line#"${line%%[![:space:]]*}"}"
    case "$stripped" in
      [Dd][Ee][Ff][Aa][Uu][Ll][Tt]-[Aa][Ff][Tt][Ee][Rr]\ *) ;;
      *) continue ;;
    esac
    rest="${stripped#* }"                 # "14d: do the thing"
    days="${rest%%d:*}"
    case "$days" in ''|*[!0-9]*) continue ;; esac
    action="${rest#*d:}"
    action="${action#"${action%%[![:space:]]*}"}"
    [ -n "$action" ] || continue
    printf '%s\t%s\n' "$days" "$action"
    return 0
  done <<<"$(grammar_header "$1")"
  return 1
}

grammar_policy() {  # <body> -- print the general policy class (#1621), 1 if none; shape of grammar_default_after
  local line stripped rest class
  while IFS= read -r line; do
    stripped="${line#"${line%%[![:space:]]*}"}"
    case "$stripped" in
      [Pp][Oo][Ll][Ii][Cc][Yy]:*) ;;
      *) continue ;;
    esac
    rest="${stripped#*:}"
    class="${rest#"${rest%%[![:space:]]*}"}"
    [ -n "$class" ] || continue
    printf '%s\n' "$class"
    return 0
  done <<<"$(grammar_header "$1")"
  return 1
}

grammar_answered_by() {  # <body> -- print the ref (#568), 1 if none; shape of grammar_default_after
  local line stripped rest ref
  while IFS= read -r line; do
    stripped="${line#"${line%%[![:space:]]*}"}"
    case "$stripped" in
      [Aa][Nn][Ss][Ww][Ee][Rr][Ee][Dd]-[Bb][Yy]\ *) ;;
      *) continue ;;
    esac
    rest="${stripped#* }"
    ref="${rest%% *}"
    case "$ref" in
      */*'#'[0-9]*) ;;
      *) continue ;;
    esac
    case "${ref#*'#'}" in ''|*[!0-9]*) continue ;; esac
    printf '%s\n' "$ref"
    return 0
  done <<<"$(grammar_header "$1")"
  return 1
}

# PLACEHOLDERS: a truncated fence must not read as another repo's ledger (#627).
grammar_template() {
  cat <<'EOF'
DECISION: @hf7y -- may a verb build claim /usr/local/bin/gh on monkey?
NO-DECISION: @hf7y asked for this exact change; tests green, nothing to weigh

...and on a DECISION, say what general policy class this repo-specific
question stands in for -- REQUIRED, so an unanswered policy gap surfaces
once, not as a fresh repo-specific ask each time it recurs. If none exists
yet, say so: `POLICY: none yet`.

POLICY: which verb builds may claim a host-wide binary path

...and say what happens if nobody answers. REQUIRED, because an
unanswered question brakes the repo that asked. To block forever, declare it:
`DEFAULT-AFTER 0d: block -- irreversible, no default`.

DEFAULT-AFTER 14d: ship it unsigned and open a follow-up; reverse by saying so

<!-- DEFERRED -->
- none
<!-- /DEFERRED -->

<!-- DELIVERS -->
- none
<!-- /DELIVERS -->

...or one line each, every one naming an issue. `defere` files them:

<!-- DEFERRED -->
- hf7y/<repo>#<n> -- <what was left behind, in a few words>
- hf7y/<repo>#<n> -- <and the next one>
EOF
}

# decision | no-decision | none, from the first non-empty line. The word must
# OPEN the line, or a body quoting the convention exempts itself.
grammar_declaration() {
  local line stripped
  while IFS= read -r line; do
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    stripped="${line#"${line%%[![:space:]#>*_-]*}"}"
    case "$stripped" in
      [Nn][Oo]-[Dd][Ee][Cc][Ii][Ss][Ii][Oo][Nn]:*) printf 'no-decision\n'; return ;;
      [Dd][Ee][Cc][Ii][Ss][Ii][Oo][Nn]:*)          printf 'decision\n';    return ;;
    esac
    printf 'none\n'; return
  done <<<"$1"
  printf 'none\n'
}

# Prints `CODE  message` per violation; returns the count. Never exits.
grammar_check() {
  local body="$1" line stripped n=0 lineno=0 first_seen=0
  local open=0 in_block=0 entries=0 entry='' fenced=0 details=0
  local sopen=0 in_ship=0 ships=0 ship='' indent=''
  local has_default=0 has_policy=0 head_neg=0 nc=''

  _find() { printf '%s  %s\n' "$1" "$2"; n=$((n + 1)); }

  # A bullet plus its continuations, judged when the next bullet or / arrives.
  _judge_entry() {
    [ -n "$entry" ] || return 0
    entries=$((entries + 1))
    case "$entry" in
      *[a-zA-Z0-9_.-]/[a-zA-Z0-9_.-]*'#'[0-9]*) entry=''; return 0 ;;
      *http*://*)                               entry=''; return 0 ;;
      '- none'|'- none.'|'-none')               entry=''; return 0 ;;
    esac
    case "$entry" in
      *NO-OWNER:*|*'NO OWNER:'*)
        _find NO-DESTINATION "\`NO-OWNER:\` is not a destination -- \`defere\` it, cite the number: ${entry:0:60}" ;;
      *)
        _find NO-DESTINATION "names no issue and no URL: ${entry:0:70}" ;;
    esac
    entry=''
  }

  # A claim names WHERE the change takes effect, so a check can go and look.
  # Untyped prose cannot be, which is how "merged" became the finish line for
  # changes that never landed anywhere.
  _judge_ship() {
    [ -n "$ship" ] || return 0
    ships=$((ships + 1))
    case "$ship" in
      '- none'|'- none.'|'-none')                       ship=''; return 0 ;;
      *host:*|*path:*|*clock:*|*tag:*|*secret:*|*unit:*|*port:*|*repo:*) ship=''; return 0 ;;
    esac
    _find UNTYPED-DELIVERY "names no <kind>:<value> a check could look for: ${ship:0:60}"
    ship=''
  }

  while IFS= read -r line; do
    lineno=$((lineno + 1))
    case "$line" in '```'*) fenced=$((1 - fenced)); continue ;; esac
    [ "$fenced" -eq 1 ] && continue
    # <details> IS A QUOTE, THE SAME AS `>` -- #1324: it is how a body keeps an
    # answered DECISION's original text readable, collapsed, beside the answer
    # that supersedes it. Ungated, the DECISION and DEFAULT-AFTER inside read as
    # live and the write was refused MISPLACED-DECISION / BAD-DEFAULT -- the
    # archive of an answered question could not sit next to its answer.
    case "${line,,}" in
      '<details'*)   details=1; continue ;;
      '</details>'*) details=0; continue ;;
    esac
    [ "$details" -eq 1 ] && continue

    stripped="${line#"${line%%[![:space:]]*}"}"

    # A heading scopes the denial over every line under it, until the next one.
    case "$stripped" in
      '# '*|'## '*|'### '*|'#### '*|'##### '*|'###### '*)
        case "${stripped,,}" in
          *'is not'*|*'does not'*|*'not in scope'*|*'out of scope'*|*non-goal*|*'not doing'*)
            head_neg=1 ;;
          *) head_neg=0 ;;
        esac ;;
    esac
    if nc="$(grammar_negated_close "$stripped" "$head_neg")"; then
      _find NEGATED-CLOSE "line $lineno: \`$nc\` in a sentence that denies it -- GitHub closes the issue from the keyword alone. Use a bare \`#N\` to reference without closing, or move the closing keyword to its own line: ${stripped:0:70}"
    elif nc="$(grammar_partial_close "$stripped")"; then
      _find PARTIAL-CLOSE "line $lineno: \`$nc\` scopes the close to part of the issue -- GitHub closes the whole issue from the keyword alone. Use a bare \`#N\` to reference without closing: ${stripped:0:70}"
    fi

    # Indented four spaces, a marker is an EXAMPLE, not a second block.
    indent="${line%%[![:space:]]*}"
    if [ "${#indent}" -ge 4 ]; then
      case "$stripped" in *'<!--'*'DEFERRED'*'-->'*|*'<!--'*'DELIVERS'*'-->'*) continue ;; esac
    fi
    case "$stripped" in
      '<!-- DEFERRED -->'|'<!--DEFERRED-->')   open=$((open + 1)); in_block=1; continue ;;
      '<!-- /DEFERRED -->'|'<!--/DEFERRED-->') _judge_entry; in_block=0; continue ;;
      '<!-- DELIVERS -->'|'<!--DELIVERS-->')   sopen=$((sopen + 1)); in_ship=1; continue ;;
      '<!-- /DELIVERS -->'|'<!--/DELIVERS-->') _judge_ship; in_ship=0; continue ;;
    esac

    if [ "$in_ship" -eq 1 ]; then
      case "$stripped" in
        '- '*|'* '*|[0-9]*'. '*) _judge_ship; ship="$stripped" ;;
        '')                      _judge_ship ;;
        *) [ -n "$ship" ] && ship="$ship $stripped" ;;
      esac
      continue
    fi

    if [ "$in_block" -eq 1 ]; then
      case "$stripped" in
        '- '*|'* '*|[0-9]*'. '*) _judge_entry; entry="$stripped" ;;
        '')                      _judge_entry ;;
        *) [ -n "$entry" ] && entry="$entry $stripped" ;;
      esac
      continue
    fi

    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    [ "$sopen" -gt 0 ] && [ "$first_seen" -eq 0 ] && first_seen=0
    # `>` IS NOT DECORATION, unlike # * _ -: a blockquote is how a body carries a
    # SUPERSEDED declaration beside its replacement. Stripping it read quoted
    # history as a live declaration, so a demoted DECISION could not keep its own
    # original text -- the `DEFAULT-AFTER 14d:` inside the quote still counted
    # (two refused writes on hf7y/wtul#346, same shape again on #356). A fenced
    # block is already skipped above; a quote is the same kind of thing.
    case "$stripped" in '>'*) continue ;; esac
    local decl="${stripped#"${stripped%%[![:space:]#*_-]*}"}"
    case "$decl" in
      [Nn][Oo]-[Dd][Ee][Cc][Ii][Ss][Ii][Oo][Nn]:*)
        [ "$first_seen" -eq 1 ] && _find MISPLACED-DECISION \
          "line $lineno declares, but line 1 did not. The convention reads line 1 only." ;;
      [Dd][Ee][Cc][Ii][Ss][Ii][Oo][Nn]:*)
        if [ "$first_seen" -eq 1 ]; then
          _find MISPLACED-DECISION "line $lineno declares, but line 1 did not. The convention reads line 1 only."
        else
          [[ $decl =~ $GRAMMAR_DECIDER_RE ]] || _find NO-DECIDER \
            'the declaration names no decider. Line 1: "DECISION: @who -- <the call>".'
        fi ;;
      [Dd][Ee][Ff][Aa][Uu][Ll][Tt]-[Aa][Ff][Tt][Ee][Rr]*)
        # A malformed default is worse than none: it reads as a timer to a
        # human and is invisible to grammar_default_after, so the issue looks
        # self-resolving and blocks forever.
        _da_rest="${decl#*[Rr] }"
        _da_days="${_da_rest%%d:*}"
        _da_act="${_da_rest#*d:}"
        _da_act="${_da_act#"${_da_act%%[![:space:]]*}"}"
        case "$_da_days" in
          ''|*[!0-9]*) _find BAD-DEFAULT \
            "line $lineno: DEFAULT-AFTER needs a day count -- \`DEFAULT-AFTER 14d: <reversible action>\`." ;;
          *) case "$_da_days:$_da_act" in
               [1-9]*:[Nn]one|[1-9]*:[Nn]one[!a-zA-Z]*|[1-9]*:[Nn]o\ default*) _find BAD-DEFAULT \
                 "line $lineno: DEFAULT-AFTER with a window and the action \`none\` is a question that waits forever (senechal#941). Name what the asker does, or declare \`0d: block\`." ;;
               *:?*) has_default=1 ;;
               *) _find BAD-DEFAULT \
                 "line $lineno: DEFAULT-AFTER names a window but no action. Say what happens when nobody answers." ;;
             esac ;;
        esac
        [ "$first_seen" -eq 0 ] && [ "$open" -eq 0 ] && [ "$sopen" -eq 0 ] && _find UNDECLARED \
          'line 1 is neither `DECISION:` nor `NO-DECISION:`. Every body declares one.' ;;
      [Aa][Nn][Ss][Ww][Ee][Rr][Ee][Dd]-[Bb][Yy]*)
        _ab_ref="${decl#* }"  # malformed reads as settled to a human, unresolved to grammar_answered_by
        _ab_ref="${_ab_ref%% *}"
        case "$_ab_ref" in
          */*'#'[0-9]*) case "${_ab_ref#*'#'}" in
              ''|*[!0-9]*) _find BAD-ANSWERED-BY \
                "line $lineno: ANSWERED-BY needs \`<owner>/<repo>#<n>\` -- got: ${decl:0:60}" ;;
            esac ;;
          *) _find BAD-ANSWERED-BY \
               "line $lineno: ANSWERED-BY needs \`<owner>/<repo>#<n>\` -- got: ${decl:0:60}" ;;
        esac
        [ "$first_seen" -eq 0 ] && [ "$open" -eq 0 ] && [ "$sopen" -eq 0 ] && _find UNDECLARED \
          'line 1 is neither `DECISION:` nor `NO-DECISION:`. Every body declares one.' ;;
      [Pp][Oo][Ll][Ii][Cc][Yy]:*)
        # A malformed POLICY is worse than none: it reads as named to a human
        # and is invisible to grammar_policy, so a repo-specific question
        # looks like it named its general class when it did not.
        _po_class="${decl#*:}"
        _po_class="${_po_class#"${_po_class%%[![:space:]]*}"}"
        if [ -n "$_po_class" ]; then has_policy=1
        else _find BAD-POLICY \
          "line $lineno: POLICY: names no class -- say what general policy this asks about, or \`POLICY: none yet\` if none exists."
        fi
        [ "$first_seen" -eq 0 ] && [ "$open" -eq 0 ] && [ "$sopen" -eq 0 ] && _find UNDECLARED \
          'line 1 is neither `DECISION:` nor `NO-DECISION:`. Every body declares one.' ;;
      *) [ "$first_seen" -eq 0 ] && [ "$open" -eq 0 ] && [ "$sopen" -eq 0 ] && _find UNDECLARED \
           'line 1 is neither `DECISION:` nor `NO-DECISION:`. Every body declares one.' ;;
    esac
    first_seen=1
  done <<<"$body"

  # A body that is entirely a ledger never reached the check above.
  [ "$first_seen" -eq 0 ] && _find UNDECLARED 'no first line to declare on.'

  [ "$has_default" -eq 0 ] && [ "$(grammar_declaration "$body")" = decision ] && _find NO-DEFAULT \
    'a DECISION needs `DEFAULT-AFTER <n>d: <action>`. To block forever, declare it: `DEFAULT-AFTER 0d: block -- irreversible, no default`.'

  [ "$has_policy" -eq 0 ] && [ "$(grammar_declaration "$body")" = decision ] && _find NO-POLICY \
    'a DECISION needs `POLICY: <the general class this asks about>`. If none exists yet, say so: `POLICY: none yet`.'

  [ "$in_block" -eq 1 ] && { _judge_entry; _find UNCLOSED 'the DEFERRED block is never closed.'; }
  [ "$open" -eq 0 ] && _find UNLEDGERED 'no <!-- DEFERRED --> block. Say what was left behind, or "- none".'
  [ "$open" -gt 1 ] && _find MULTI-LEDGER "$open DEFERRED blocks -- a reader cannot tell which is current."
  [ "$open" -ge 1 ] && [ "$entries" -eq 0 ] && _find EMPTY-LEDGER 'the DEFERRED block is empty. Write "- none".'

  [ "$in_ship" -eq 1 ] && { _judge_ship; _find UNCLOSED 'the DELIVERS block is never closed.'; }
  [ "$sopen" -eq 0 ] && _find UNSHIPPED 'no <!-- DELIVERS --> block. Say where this takes effect outside the repo, or "- none".'
  [ "$sopen" -gt 1 ] && _find MULTI-SHIP "$sopen DELIVERS blocks -- a reader cannot tell which is current."
  [ "$sopen" -ge 1 ] && [ "$ships" -eq 0 ] && _find EMPTY-SHIP 'the DELIVERS block is empty. Write "- none".'

  [ "$n" -gt 125 ] && n=125
  return "$n"
}

# grammar_rewrite_on_ruling <body> <ruling> -- given a DECISION: body and the
# ruling text that answers it, print a NO-DECISION: body: line 1 is the
# ruling, the original DECISION: line and its prose are preserved as a `>`
# quote (so the question stays legible beside its answer, per #1324's
# convention), and the DEFERRED/DELIVERS blocks carry through unchanged. #1434
# builds the mechanism only -- nothing calls this yet; the caller decides how
# a ruling is detected.
#
# `>` IS LOAD-BEARING: grammar_check and grammar_header both skip a quoted
# line before parsing a declaration out of it, so the quoted original
# DECISION:/DEFAULT-AFTER cannot be read as still live (#1324).
grammar_rewrite_on_ruling() {
  local body="$1" ruling="${2//$'\n'/ }" line stripped header='' blocks='' in_blocks=0

  while IFS= read -r line; do
    stripped="${line#"${line%%[![:space:]]*}"}"
    if [ "$in_blocks" -eq 0 ]; then
      case "$stripped" in
        '<!-- DEFERRED -->'|'<!--DEFERRED-->') in_blocks=1 ;;
      esac
    fi
    if [ "$in_blocks" -eq 1 ]; then
      blocks="$blocks$line"$'\n'
    else
      header="$header$line"$'\n'
    fi
  done <<<"$body"

  # Trailing blank lines in the header would quote as bare `>` for nothing.
  while [ "${header: -2}" = $'\n\n' ]; do header="${header%$'\n'}"; done
  header="${header%$'\n'}"

  printf 'NO-DECISION: %s\n\n' "$ruling"
  printf 'The question this answers, quoted below as it was asked:\n\n'
  while IFS= read -r line; do
    [ -n "$line" ] && printf '> %s\n' "$line" || printf '>\n'
  done <<<"$header"
  printf '\n'
  printf '%s' "$blocks"
}
