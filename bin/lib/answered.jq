# answered.jq -- has a human answered this issue? THE one text (#568).
#   jq --arg owner hf7y --arg era 2026-08-14 --arg today 2026-10-04 \
#     "$(cat answered.jq)"'.[] | verdict'
#
# INPUT, per issue: what `gh issue list/view --json ...,labels,comments`
# produce. Two callers, two feeding styles, one text -- it lived THREE times
# and the copies disagreed on the era cutoff, the `answered` label, what
# `stamped` means, and whether the author mattered.
# FOUR VERDICTS, AND THE THIRD AND FOURTH ARE THE POINT:
#   answered     a human did, or the `answered` label says one did elsewhere
#   uncounted    a comment COULD be a human's and cannot be counted
#   stale        no human answered, but a date it named has already passed --
#                the question was answered by an EVENT, not a reply (#1406)
#   unanswered   there is nothing here, and nothing has made it moot either
# `uncounted` used to report as `unanswered`, with no line and no count. That
# is how Zach was asked chezz#4 twice, and how wtul#37 blocked nine days after
# being settled on wtul#34. An unknowable is not an answer -- but it is not a
# silence either. `stale` is the same shape of gap on the other side: a
# `needs-human` body that named a lock or deadline reads "unanswered" forever
# once the clock it named has run out, even though the event it was
# describing already happened (musc-2300#149 -- "Canvas 15026433 locks Mon
# 2026-09-28", closed four days later by a comment saying the window shut,
# not by Zach ruling on it).

# stamped: TRUE iff the body's LAST NON-BLANK LINE opens with `<!-- agent:`.
# The stricter of the two rules that merged here: `test("<!--\\s*agent:")`
# anywhere in the body also matched a body QUOTING the convention.
def stamped:
  (. // "") | split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))
  | if length == 0 then false else (.[-1] | test("^<!--\\s*agent:")) end;

# relayed: `<!-- decision-by: zach ... -->`. Zach answers OUT LOUD; without a
# relay marker every spoken call reads as never given.
def relayed: (. // "") | test("<!--\\s*decision-by:");

# The LATEST $owner comment that is unstamped or relaying. An older answer that
# WAS taken up does not excuse a newer one that was not.
#
# ONLY $owner. A comment from anyone else is a human's, but a human commenting
# is not the decider answering -- "any word on this?" from a third party is the
# case this filter exists for. A genuine outside answer (Chris's `APPROVED` on
# hf7y/front-door#4) is settled with the `answered` label below: typed and
# auditable, rather than inferred from the fact that somebody spoke.
def candidates:
  [ .comments[]?
    | select((.author.login // "") == $owner)
    | select(((.body | stamped) | not) or (.body | relayed)) ];

def latest: sort_by(.createdAt) | last;

# The `answered` label is an OVERRIDE, never the trigger. It is the one act
# that settles an answer living somewhere this predicate cannot see -- another
# issue, a conversation, a room. It needs a clock, so it borrows the latest
# comment's date.
def labelled: ((.labels // []) | any(.name == "answered"));

# `unsettled` is the mirror OVERRIDE (#705): the owner replied and the reply
# did not settle the question -- a contradiction, a non-answer, an answer to a
# different question. `candidates`/`latest` can only see THAT a comment
# exists, never whether it settled anything, so a typed label says what the
# predicate cannot. Checked before the comment branch, same precedence
# `answered` already has, so it wins over "there is a reply" rather than
# losing to it.
# IT MUST NAME WHAT REMAINS, as `UNSETTLED: <what is still open>` in the body;
# without it the override does not fire and the reply counts. Its verdict is
# `unanswered`, which decision-rot cannot count, so a bare label deleted
# baudin#29 from every survey for 13 days and re-asked an answered question.
def unsettled_labelled:
  ((.labels // []) | any(.name == "unsettled"))
  and ((.body // "") | test("(?im)^[ \\t]*UNSETTLED:[ \\t]*\\S"));

# stale: a date already past the clock in $today, named on the SAME LINE as
# a word for the kind of event that closes a window -- a bare date is an
# attribution ("Zach, 2026-08-29, #762"), never a deadline, so the keyword is
# required rather than optional. Body and comments both count: musc-2300#149
# named the lock in the body ("Canvas 15026433 locks Mon 2026-09-28") and the
# closing comment repeated it ("Lab 6 locked Mon 2026-09-28"); either alone
# is enough. A fenced block quotes output, not a live claim -- stripped first,
# same trap stale-paths.jq already names.
def stale_keyword_re: "(?i)\\b(?:lock|locks|locked|locking|deadline|due|expires|expired|expire|closes|closed|closing)\\b";
def stale_dates:
  ( [(.body // "")] + ( [.comments[]?] | map(.body // "") ) )
  | map(gsub("```(?s:.*?)```"; " "))
  | map(split("\n"))
  | flatten
  | map(select(test(stale_keyword_re)))
  | map([scan("[0-9]{4}-[0-9]{2}-[0-9]{2}")])
  | flatten;
def stale_passed: (stale_dates | map(select(. < $today)));
def stale: (stale_passed | length) > 0;

# ANSWERED-BY <owner>/<repo>#<n> (#568), extraction only -- see body-grammar.sh.
def answered_by:
  ( [ (.body // "") ]
    + ( [ .comments[]? ] | sort_by(.createdAt) | map(.body // "") )
    | join("\n") ) as $all
  | ($all | [scan("(?im)^\\s*ANSWERED-BY\\s+(\\S+/\\S+#[0-9]+)")]) as $m
  | if ($m | length) > 0 then $m[-1][0] else null end;

def verdict:
  . as $i
  | ($i | candidates | latest) as $a
  | if ($i | unsettled_labelled) then
      { verdict: "unanswered", at: null,
        why: "the `unsettled` label and the `UNSETTLED:` residual it names -- the owner replied and it did not settle that" }
    elif $a != null and ($a.createdAt[0:10] >= $era) then
      { verdict: "answered",   at: $a.createdAt,
        why: "an unstamped or relayed comment" }
    elif ($i | labelled) then
      { verdict: "answered",   at: ([$i.comments[]?] | latest | .createdAt),
        why: "the `answered` label -- a human answered somewhere this cannot see" }
    elif $a != null then
      { verdict: "uncounted",  at: $a.createdAt,
        why: "a comment from \($a.createdAt[0:10]) predates the stamp era (\($era)), so it cannot be told from an agent's" }
    elif ($i | stale) then
      ($i | stale_passed | sort | last) as $d
      | { verdict: "stale", at: $d,
          why: "a lock/deadline date (\($d)) in the body or a comment is already past today (\($today)) -- answered by an event, not a human" }
    else
      { verdict: "unanswered", at: null,
        why: "no comment that could be a human's" }
    end
  | . + { number: $i.number, answered_by: ($i | answered_by) };
