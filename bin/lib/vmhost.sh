#!/usr/bin/env bash
VMHOST_VBOX="${VMHOST_VBOX:-/mnt/c/Program Files/Oracle/VirtualBox/VBoxManage.exe}"  # vmhost.sh: backend-neutral VM-host vocabulary (#563) -- VMHOST_BACKEND=hyperv swaps the driver, not every call site
VMHOST_WSL="${VMHOST_WSL:-/mnt/c/Windows/System32/wsl.exe}"  # the wsl backend's driver: monkey is decided to become a WSL2 distro on dexter, so the vocabulary has to survive VirtualBox being deleted

VMHOST_REG="${VMHOST_REG:-/mnt/c/Windows/System32/reg.exe}"  # the wsl backend keeps a distro's disk location in the registry, not in any wsl.exe subcommand

_VMHOST_WSL_DISTROS=""
_vmhost_wsl_has() {  # <name> -- is there a WSL distro by that name? one launch per process, then cached
  [ -x "$VMHOST_WSL" ] || return 1
  [ -n "$_VMHOST_WSL_DISTROS" ] || _VMHOST_WSL_DISTROS="$(_wsl -l -q)"
  printf '%s\n' "$_VMHOST_WSL_DISTROS" | grep -qx "$1"
}

vmhost_backend() {  # [vm] -> "virtualbox" | "wsl" | "unknown", from $VMHOST_BACKEND or detected from the drivers present
  local vm="${1:-}"
  if [ -n "${VMHOST_BACKEND:-}" ]; then
    printf '%s\n' "$VMHOST_BACKEND"
  elif [ -n "$vm" ] && [ -x "$VMHOST_VBOX" ] && [ -x "$VMHOST_WSL" ] && _vmhost_wsl_has "$vm"; then
    printf 'wsl\n'   # both drivers installed is the migration window: a live distro by that name wins over a VirtualBox registration that may be a leftover
  elif [ -x "$VMHOST_VBOX" ]; then
    printf 'virtualbox\n'
  elif [ -x "$VMHOST_WSL" ]; then
    printf 'wsl\n'
  else
    printf 'unknown\n'
  fi
}

_vmhost_require_vbox() {
  [ -x "$VMHOST_VBOX" ] && return 0
  printf 'vmhost: VBoxManage not at %s\n' "$VMHOST_VBOX" >&2
  return 2
}

_vmhost_require_wsl() {
  [ -x "$VMHOST_WSL" ] && return 0
  printf 'vmhost: wsl.exe not at %s\n' "$VMHOST_WSL" >&2
  return 2
}

vmhost_require() {  # [vm] -- 0 if the active backend can be driven, else 2 and a reason on stderr
  case "$(vmhost_backend "${1:-}")" in
    virtualbox) _vmhost_require_vbox ;;
    wsl) _vmhost_require_wsl ;;
    unknown) printf 'vmhost: no VM host driver here (no VBoxManage at %s, no wsl.exe at %s)\n' "$VMHOST_VBOX" "$VMHOST_WSL" >&2; return 2 ;;
    *) printf 'vmhost: backend "%s" has no driver\n' "$(vmhost_backend)" >&2; return 2 ;;
  esac
}

_vbm() { "$VMHOST_VBOX" "$@" < /dev/null 2>&1 | tr -d '\0\r'; }
# HOW LONG THE WINDOW IS, measured on dexter 2026-09-18 (#1226): sampling every
# 12s for 7 minutes, 6 of 20 calls printed `ERROR: UtilAcceptVsock:273: accept4
# failed 110` where the answer goes and still exited 0. 110 is ETIMEDOUT and
# accept4 waits it out, so a LOST CALL COSTS ~40s and the window outlives it --
# rows 32s apart both failed, the next one answered. One immediate retry lands
# inside the same window: it saved 4 of those 6 and monkey-watch published
# DEGRADED for the other 2, on a host every guest probe said was up.
VMHOST_WSL_TRIES="${VMHOST_WSL_TRIES:-3}"
VMHOST_WSL_RETRY_S="${VMHOST_WSL_RETRY_S:-5}"
_wsl() {  # a lost call must not be read as an answer: try again, with a gap, while the window is open
  local out i
  for i in $(seq 1 "$VMHOST_WSL_TRIES"); do
    out="$("$VMHOST_WSL" "$@" < /dev/null 2>&1 | tr -d '\0\r')"
    case "$out" in *'ERROR: '*) ;; *) break ;; esac
    [ "$i" -lt "$VMHOST_WSL_TRIES" ] && sleep "$VMHOST_WSL_RETRY_S"
  done
  printf '%s\n' "$out"
}
_reg() { "$VMHOST_REG" "$@" < /dev/null 2>/dev/null | tr -d '\0\r'; }

_vmhost_wsl_basepath() {  # <distro> -> where the distro's ext4.vhdx lives, in Windows coordinates
  _reg query 'HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss' /s | awk -v want="$1" '
    /^HKEY_/               { base=""; name=""; next }
    $1=="BasePath"         { $1=""; $2=""; sub(/^[ \t]+/,""); base=$0 }
    $1=="DistributionName" { $1=""; $2=""; sub(/^[ \t]+/,""); name=$0 }
    name==want && base!="" { print base; exit }
  '
}

vmhost_state() {  # <vm> -> running | poweroff | paused | unknown
  local vm="$1" s
  case "$(vmhost_backend "$vm")" in
    virtualbox)
      _vmhost_require_vbox || return 2
      s="$(_vbm showvminfo "$vm" --machinereadable | grep '^VMState=' | cut -d'"' -f2)"
      printf '%s\n' "${s:-unknown}"
      ;;
    wsl)
      _vmhost_require_wsl || return 2
      s="$(_wsl -l -q --running)"  # a stopped distro holds no RAM, so --running answers the only question this vocabulary asks
      case "$s" in
        *'ERROR: '*) printf 'unknown\n' ;;  # the driver did not answer. NEVER poweroff: monkey-watch alarms on that, and it alerted Zach at 2026-09-06T00:30Z for a distro that was up 5 days
        *) if printf '%s\n' "$s" | grep -qx "$vm"; then printf 'running\n'; else printf 'poweroff\n'; fi ;;
      esac
      ;;
    *) printf 'vmhost: backend "%s" has no driver\n' "$(vmhost_backend)" >&2; return 2 ;;
  esac
}

vmhost_disk_raw() {  # <vm> -> the backend's own disk descriptor, published as-is
  local vm="$1"
  case "$(vmhost_backend "$vm")" in
    virtualbox)
      _vmhost_require_vbox || return 2
      _vbm showvminfo "$vm" --machinereadable | grep '^"SATA-0-0"=' | cut -d'"' -f4
      ;;
    wsl)
      _vmhost_require_wsl || return 2
      _vmhost_wsl_basepath "$vm"
      ;;
    *) printf 'vmhost: backend "%s" has no driver\n' "$(vmhost_backend)" >&2; return 2 ;;
  esac
}

vmhost_classify_disk() {  # <raw> -> internal | EXTERNAL-USB | unknown -- pure, no host round-trip
  local d="${1#\\\\?\\}"   # the drive letter IS the classification, so asking which backend produced it bought nothing -- and cost: asked with no vm name it classed every WSL disk virtualbox. A wsl BasePath may arrive as \\?\C:\... ; VirtualBox never does
  case "$d" in
    [Cc]:*) printf 'internal\n' ;;
    [Dd]:*) printf 'EXTERNAL-USB\n' ;;
    *)      printf 'unknown\n' ;;
  esac
}

vmhost_disk() {  # <vm> -> vmhost_disk_raw, then vmhost_classify_disk
  local vm="$1" d
  d="$(vmhost_disk_raw "$vm")" || return 2
  vmhost_classify_disk "$d"
}

vmhost_screenshot() {  # <vm> <path> -- capture the VM console to <path> as a PNG
  local vm="$1" path="$2"
  case "$(vmhost_backend "$vm")" in
    virtualbox)
      _vmhost_require_vbox || return 2
      _vbm controlvm "$vm" screenshotpng "$path" >/dev/null
      ;;
    wsl)
      return 4   # GAP, not a driver error: a distro has no framebuffer. Silent, because monkey-watch asks every 10 minutes and stderr here lands in cron mail
      ;;
    *) printf 'vmhost: backend "%s" has no driver\n' "$(vmhost_backend)" >&2; return 2 ;;
  esac
}

vmhost_save() {  # <vm> -- suspend to disk and free the host's RAM. savestate, not acpipowerbutton: #704 measured the VM still `running` 60s after an ACPI request
  local vm="$1"
  case "$(vmhost_backend "$vm")" in
    virtualbox)
      _vmhost_require_vbox || return 2
      _vbm controlvm "$vm" savestate >/dev/null
      ;;
    wsl)
      _vmhost_require_wsl || return 2
      _wsl --terminate "$vm" >/dev/null  # --terminate, NEVER --shutdown: --shutdown stops EVERY distro including dexter's own Ubuntu, the route in; terminating one distro is what returns its RAM to the host
      ;;
    *) printf 'vmhost: backend "%s" has no driver\n' "$(vmhost_backend)" >&2; return 2 ;;
  esac
}

vmhost_save_cmd() {  # <vm> -- the exact command vmhost_save would run, so a dry run can print it rather than describe it
  local vm="$1"
  case "$(vmhost_backend "$vm")" in
    virtualbox) printf '%s controlvm %s savestate\n' "$VMHOST_VBOX" "$vm" ;;
    wsl)        printf '%s --terminate %s\n' "$VMHOST_WSL" "$vm" ;;
    *) printf 'vmhost: backend "%s" has no driver\n' "$(vmhost_backend)" >&2; return 2 ;;
  esac
}

vmhost_start_cmd() {  # <vm> -- the mirror of vmhost_save_cmd, for a caller that must run the start on the VM HOST rather than here
  local vm="$1"
  case "$(vmhost_backend "$vm")" in
    virtualbox) printf '%s startvm %s --type %s\n' "$VMHOST_VBOX" "$vm" "${VMHOST_START_TYPE:-headless}" ;;
    wsl)        printf '%s -d %s --exec /bin/true\n' "$VMHOST_WSL" "$vm" ;;
    *) printf 'vmhost: backend "%s" has no driver\n' "$(vmhost_backend)" >&2; return 2 ;;
  esac
}

vmhost_sparse_cmd() {  # <vm> -- make the distro's disk sparse, so space freed INSIDE it returns to the host. wsl only: a VirtualBox VDI reclaims by compacting a medium, which is a different act with a different risk, and pretending one command covers both is how a driver difference becomes an outage
  local vm="$1"
  case "$(vmhost_backend "$vm")" in
    wsl) printf '%s --manage %s --set-sparse true\n' "$VMHOST_WSL" "$vm" ;;
    *) printf 'vmhost: --set-sparse is a wsl notion; backend "%s" has no equivalent here\n' "$(vmhost_backend)" >&2; return 2 ;;
  esac
}

vmhost_running_vms_cmd() {  # -> the command that lists running VM names, one per line, on the VM HOST -- for a payload that runs THERE and so cannot source this file. Every driver present answers: detection picks one ACTUATOR, because savestate and --terminate are exclusive, and a read-only listing is not
  printf '%s\n' "{ [ -x \"$VMHOST_VBOX\" ] && \"$VMHOST_VBOX\" list runningvms | sed 's/\" .*//;s/\"//'; [ -x \"$VMHOST_WSL\" ] && \"$VMHOST_WSL\" -l -q --running; } 2>/dev/null | tr -d '\\0\\r'"
}

vmhost_start() {  # <vm> -- resume from a saved state or cold-boot; $VMHOST_START_TYPE overrides the default headless launch
  local vm="$1"
  case "$(vmhost_backend "$vm")" in
    virtualbox)
      _vmhost_require_vbox || return 2
      _vbm startvm "$vm" --type "${VMHOST_START_TYPE:-headless}" >/dev/null
      ;;
    wsl)
      _vmhost_require_wsl || return 2
      _wsl -d "$vm" --exec /bin/true >/dev/null  # a distro boots by being run in; $VMHOST_START_TYPE is a VirtualBox notion and does not apply
      ;;
    *) printf 'vmhost: backend "%s" has no driver\n' "$(vmhost_backend)" >&2; return 2 ;;
  esac
}

vmhost_logdir() {  # <vm> -> the VM's log directory, as a path THIS host can read
  # The backend answers in its own coordinates -- VirtualBox on a Windows host
  # says `C:\Users\...`, which is not a path dexter's WSL side can open. The
  # translation is as backend-specific as the query, so it lives here with it
  # rather than at the call site (#639's clock probe was the call site).
  local vm="$1" d
  case "$(vmhost_backend "$vm")" in
    virtualbox)
      _vmhost_require_vbox || return 2
      d="$(_vbm showvminfo "$vm" --machinereadable | grep '^LogFldr=' | cut -d'"' -f2)"
      [ -n "$d" ] || return 0
      printf '%s\n' "$d" | sed 's|\\|/|g; s|^\([A-Za-z]\):|/mnt/\L\1|'
      ;;
    wsl)
      return 0   # a distro has no VMM and so no VMM log; empty is the honest answer, and it is what the virtualbox arm already returns when LogFldr is empty
      ;;
    *) printf 'vmhost: backend "%s" has no driver\n' "$(vmhost_backend)" >&2; return 2 ;;
  esac
}
