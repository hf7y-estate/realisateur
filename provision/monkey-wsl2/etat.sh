#!/usr/bin/env bash
set -uo pipefail

R=hf7y/realisateur
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DEXTER=(ssh -o BatchMode=yes -o ConnectTimeout=15 dexter)
WIN=(ssh -o BatchMode=yes -o ConnectTimeout=15 -p 22 -i "$HOME/.ssh/id_dexter_win" zach@dexter.tail893f2c.ts.net)
WSL=/mnt/c/Windows/System32/wsl.exe

done_=(); next_=(); div_=()
step() { # <verdict> <id> <text>
  case "$1" in
    DONE)     done_+=("  DONE      $2  $3") ;;
    PENDING)  next_+=("  PENDING   $2  $3") ;;
    BLOCKED)  next_+=("  BLOCKED   $2  $3") ;;
    DIVERGED) div_+=("  $2  $3") ;;
  esac
}
gh_ok() { command -v gh >/dev/null && gh auth status >/dev/null 2>&1; }

if ! gh_ok; then
  step DIVERGED "gh" "not authenticated -- every repo-side verdict below is BLIND, not false"
else
  s="$(gh pr view 745 --repo "$R" --json state --jq .state 2>/dev/null)"
  if [ "$s" = MERGED ]; then step DONE "1  seam" "PR #745 merged: vmhost.sh carries the wsl backend"
  else                       step PENDING "1  seam" "PR #745 is ${s:-unreadable}, not MERGED"; fi

  d="$(gh api "repos/$R/contents/bin/push-verb-build.sh" --jq .content 2>/dev/null | base64 -d | grep -cE '^[[:space:]]*--(host|here)\)')"
  if [ "${d:-0}" -ge 2 ]; then
    step DONE "2  delivery" "push-verb-build.sh carries --host and --here: a host is delivered without touching the release channel"
  else
    step PENDING "2  delivery" "push-verb-build.sh is missing --host or --here -- no route reaches a host off the release channel, whose cut is monthly"
  fi
fi

v="$HERE/../../bin/lib/vmhost.sh"
if [ -r "$v" ]; then
  miss=""
  for fn in vmhost_disk_raw vmhost_screenshot vmhost_logdir; do
    awk -v f="$fn" '$0 ~ "^"f"\\(\\)" {inf=1} inf && /^}/ {exit} inf && /^ *wsl\)/ {found=1} END{exit !found}' "$v" || miss="$miss $fn"
  done
  grep -q 'vmhost_backend' <(sed -n '/^vmhost_classify_disk/,/^}/p' "$v") && miss="$miss vmhost_classify_disk(still-backend-gated)"
  if [ -z "$miss" ]; then step DONE "3  wsl arms" "disk_raw/screenshot/logdir answer for wsl; classify_disk is pure"
  else                    step PENDING "3  wsl arms" "no wsl answer from:$miss"; fi
else
  step DIVERGED "3  wsl arms" "$v is missing from this checkout"
fi

if [ -x "$HERE/constate.sh" ]; then step DONE "4  witness" "constate.sh present"
else                                step PENDING "4  witness" "constate.sh missing"; fi
if [ -r "$HERE/before.tsv" ]; then
  step DONE "5  baseline" "before.tsv captured ($(awk -F'\t' '$1=="backend"{print $2}' "$HERE/before.tsv" 2>/dev/null))"
else
  step PENDING "5  baseline" "no before.tsv -- capture it BEFORE anything touches monkey"
fi
if [ -r "$HERE/runbook.1" ]; then step DONE "6  runbook" "runbook.1 present ($(MANWIDTH=200 man --nh --nj -l "$HERE/runbook.1" 2>/dev/null | wc -l) rendered lines)"
else                              step PENDING "6  runbook" "no runbook.1"; fi

step BLOCKED "7  cut approval" "a forced cut needs Zach: hf7y/verbs 'release' env, required_reviewers=[hf7y], can_admins_bypass=false"

distros="$(timeout 40 "${DEXTER[@]}" "$WSL -l -q 2>/dev/null | tr -d '\0\r'" 2>/dev/null)"
if [ -z "$distros" ]; then
  step DIVERGED "dexter" "no distro list came back -- BLIND on the host, not 'nothing there'"
else
  if printf '%s\n' "$distros" | grep -qx monkey-rehearsal; then
    step DONE "8  rehearsal" "distro monkey-rehearsal exists on dexter"
  elif [ -r "$HERE/rehearsal-verdict.tsv" ]; then
    step DONE "8  rehearsal" "rehearsal recorded and torn down (rehearsal-verdict.tsv)"
  else
    step PENDING "8  rehearsal" "no monkey-rehearsal distro and no recorded verdict"
  fi
  if printf '%s\n' "$distros" | grep -qx monkey; then
    step DONE "9  cutover" "distro 'monkey' is registered on dexter"
  else
    step PENDING "9  cutover" "monkey is not yet a distro"
  fi
  for d in $distros; do
    case "$d" in Ubuntu|hermes|docker-desktop|monkey|monkey-rehearsal) ;;
      *) step DIVERGED "dexter" "unexpected distro '$d' -- nothing in the plan put it there" ;;
    esac
  done
fi

free_c="$(timeout 40 "${DEXTER[@]}" 'df -BG --output=avail /mnt/c 2>/dev/null | tail -1' 2>/dev/null | tr -dc '0-9')"
vbox="$(timeout 40 "${DEXTER[@]}" 'ls "/mnt/c/Program Files/Oracle/VirtualBox/VBoxManage.exe" 2>/dev/null' 2>/dev/null | tr -d '\r')"
if [ -n "$free_c" ]; then
  step DONE "10 rollback" "retired (#827): no VirtualBox VM on dexter, ${free_c}G free on C:"
  if [ "$free_c" -lt 20 ] 2>/dev/null; then step DIVERGED "C:" "only ${free_c}G free on C:, where monkey's ext4.vhdx lives and grows"; fi
else
  step DIVERGED "C:" "could not measure C: free -- BLIND, not healthy"
fi
if [ -n "$vbox" ]; then step DIVERGED "dexter" "VBoxManage is on dexter again -- senechal#438 retired VirtualBox and #827 removed it"; fi

if [ -x "$HERE/constate.sh" ] && [ -r "$HERE/before.tsv" ]; then
  now="$("$HERE/constate.sh" 2>/dev/null)"
  if [ -n "$now" ]; then
    for k in long_readout soft_lockup; do
      a="$(awk -F'\t' -v k=$k '$1==k{print $2}' "$HERE/before.tsv")"
      b="$(printf '%s\n' "$now" | awk -F'\t' -v k=$k '$1==k{print $2}')"
      if [ "${b:-0}" -gt "${a:-0}" ] 2>/dev/null; then step DIVERGED "monkey" "$k rose ${a} -> ${b} since the baseline: the wedge is progressing"; fi
    done
    bk="$(printf '%s\n' "$now" | awk -F'\t' '$1=="backend"{print $2}')"
    if [ "$bk" != wsl ]; then step DIVERGED "monkey" "backend reads '${bk:-unreadable}', not 'wsl' -- the cutover has come undone and there is no rollback"; fi
  else
    step DIVERGED "monkey" "constate.sh returned nothing -- BLIND, not healthy"
  fi
fi

echo "monkey -> WSL2, as of $(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat <<'BANNER'
the order below is PROVISIONAL -- the rehearsal exists to change it.
DIVERGED is a finding to record in runbook.1 and act on, never a failure.
BANNER
echo; echo "DONE"
if [ ${#done_[@]} -eq 0 ]; then echo "  (nothing yet)"; else printf '%s\n' "${done_[@]}"; fi
echo; echo "NEXT"
if [ ${#next_[@]} -eq 0 ]; then echo "  (nothing outstanding)"; else printf '%s\n' "${next_[@]}"; fi
echo; echo "DIVERGED"
if [ ${#div_[@]} -eq 0 ]; then echo "  (nothing the plan did not predict)"; else printf '%s\n' "${div_[@]}"; fi
exit 0
