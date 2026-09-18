#!/usr/bin/env bash

set -uo pipefail

CLI_NAME='monkey-watch-win'
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
PAYLOAD="${PAYLOAD:-$HERE/share/monkey-watch-win.ps1}"
TASK="${TASK:-monkey-watch-win}"
WIN_DIR="${WIN_DIR:-C:\\ProgramData\\monkey-watch-win}"
INTERVAL_MIN="${INTERVAL_MIN:-15}"
DEXTER_WIN=(ssh -o BatchMode=yes -o ConnectTimeout=20 -p 22 -i "$HOME/.ssh/id_dexter_win" zach@dexter.tail893f2c.ts.net)

usage() {
  cat >&2 <<'USAGE'
monkey-watch-win.sh -- install the second monkey watcher on dexter's WINDOWS
side, where WSL2 dying cannot take it with it (realisateur#782).

It puts share/monkey-watch-win.ps1 and a Windows Scheduled Task on dexter, so a
rebuilt host gets its watcher back from the tree and not from someone's memory.
--apply re-reads Get-ScheduledTask and the payload's sha256 rather than trusting
that Register-ScheduledTask exited 0.

It reaches dexter's WINDOWS sshd the way provision/monkey-wsl2/{etat,constate}.sh
do: port 22, key $HOME/.ssh/id_dexter_win. `ssh dexter` is the WSL2 side and is
deliberately not used. It declares no CRON_TAG and takes no row in
bin/lib/cron-invoked.tsv -- that registry is for cron callers, and cron-lock's
section B grades every row for cron_lock, which a schtasks trigger cannot take.
MultipleInstances IgnoreNew is the equivalent guard, set on the task itself.

usage:
  monkey-watch-win.sh --install-cadence          print the task definition, install nothing
  monkey-watch-win.sh --install-cadence --apply  deploy the payload, register the task, re-read it
  monkey-watch-win.sh --status                   what the task and its last run actually say
  monkey-watch-win.sh --test-alert               fire the alert path once, now

exit: 0 done  2 usage or a broken channel  1 installed but the re-read disagrees
USAGE
}

die() { printf '%s: FAIL: %s\n' "$CLI_NAME" "$*" >&2; exit 2; }

dexps() {
  local enc
  enc="$({ printf '$ProgressPreference = \x27SilentlyContinue\x27\n'; cat; } | iconv -f UTF-8 -t UTF-16LE | base64 -w0)" || return 2
  "${DEXTER_WIN[@]}" "powershell -NoProfile -NonInteractive -EncodedCommand $enc" 2>&1 | tr -d '\0\r'
}

MODE=''; APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --install-cadence) MODE=install ;;
    --apply)           APPLY=1 ;;
    --status)          MODE=status ;;
    --test-alert)      MODE=test-alert ;;
    -h|--help)         usage; exit 0 ;;
    *) printf '%s: unknown argument: %s\n' "$CLI_NAME" "$1" >&2; usage; exit 2 ;;
  esac
  shift
done
[ -n "$MODE" ] || { usage; exit 2; }

WIN_KEY="${DEXTER_WIN_KEY:-$HOME/.ssh/id_dexter_win}"
[ -r "$WIN_KEY" ] || die "no key at $WIN_KEY -- the Windows channel is not wired here.
  This is not dexter's sshd refusing: the key is absent on THIS host. Port 22 at
  dexter is OpenSSH_for_Windows and reads C:\\Users\\zach\\.ssh\\authorized_keys,
  which holds no key of ours (measured 2026-09-18). Until a pair exists, this
  installer cannot deploy, re-read or retire the task -- and hf7y/realisateur#1232
  carries the remedy, because placing the public half is a human's act on the
  Windows side."

PS_PATH="$WIN_DIR\\monkey-watch-win.ps1"
ACTION_ARGS="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"$PS_PATH\""

case "$MODE" in
status)
  dexps <<PS
schtasks /query /tn "$TASK" /fo LIST /v
Write-Output "--- last run ---"
Get-Content 'C:\ProgramData\monkey-watch-win\last-run' -ErrorAction SilentlyContinue
Get-EventLog -LogName Application -Source monkey-watch-win -Newest 5 -ErrorAction SilentlyContinue |
  ForEach-Object { "\$(\$_.TimeGenerated.ToUniversalTime().ToString('o'))  \$(\$_.EntryType)  \$(\$_.Message -replace "\`n",' | ')" }
PS
  ;;

test-alert)
  dexps <<PS
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PS_PATH" -Test
Write-Output "EXIT=\$LASTEXITCODE"
PS
  ;;

install)
  [ -r "$PAYLOAD" ] || die "no payload at $PAYLOAD -- this installs the copy in the tree, so there is no second copy to drift"
  if [ "$APPLY" != 1 ]; then
    printf '  would   write   %s\n' "$PS_PATH"
    printf '  would   register task \\%s\n' "$TASK"
    printf '            action    powershell.exe %s\n' "$ACTION_ARGS"
    printf '            trigger   every %s minutes, indefinitely\n' "$INTERVAL_MIN"
    printf '            principal SYSTEM / Highest -- a headless server has no logged-on Zach\n'
    printf '            settings  IgnoreNew, StartWhenAvailable, 10-minute limit\n'
    exit 0
  fi

  B64="$(base64 -w0 < "$PAYLOAD")" || die "could not encode $PAYLOAD"
  OUT="$(dexps <<PS
\$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path '$WIN_DIR' | Out-Null
[IO.File]::WriteAllBytes('$PS_PATH', [Convert]::FromBase64String('$B64'))
if (-not [Diagnostics.EventLog]::SourceExists('monkey-watch-win')) { New-EventLog -LogName Application -Source 'monkey-watch-win' }
\$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '$ACTION_ARGS'
\$trg = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $INTERVAL_MIN)
\$pri = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
\$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable \`
         -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName '$TASK' -Action \$act -Trigger \$trg -Principal \$pri -Settings \$set -Force | Out-Null
\$t = Get-ScheduledTask -TaskName '$TASK' -ErrorAction SilentlyContinue
if (-not \$t) { Write-Output 'READBACK: ABSENT'; exit 1 }
\$r = \$t.Triggers[0].Repetition
Write-Output "READBACK: state=\$(\$t.State) user=\$(\$t.Principal.UserId) run=\$(\$t.Principal.RunLevel) interval=\$(\$r.Interval) duration=\$(if (\$r.Duration) { \$r.Duration } else { 'indefinite' }) instances=\$(\$t.Settings.MultipleInstances)"
Write-Output "READBACK: sha256=\$((Get-FileHash '$PS_PATH' -Algorithm SHA256).Hash.ToLower())"
PS
)"
  printf '%s\n' "$OUT"
  want="$(sha256sum "$PAYLOAD" | cut -d' ' -f1)"
  case "$OUT" in
    *"sha256=$want"*) ;;
    *) printf '%s: BAD  the payload on dexter is NOT the one in this tree\n' "$CLI_NAME" >&2; exit 1 ;;
  esac
  case "$OUT" in
    *'interval=PT'"$INTERVAL_MIN"'M'*'duration=indefinite'*)
      printf '%s: OK   \\%s repeats every %sm indefinitely, and the payload matches the tree\n' "$CLI_NAME" "$TASK" "$INTERVAL_MIN" ;;
    *) printf '%s: BAD  the task did not read back as a %sm indefinite repeat -- nothing will watch monkey from Windows\n' "$CLI_NAME" "$INTERVAL_MIN" >&2; exit 1 ;;
  esac
  ;;
esac
