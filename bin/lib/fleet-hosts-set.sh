#!/usr/bin/env bash
# fleet-hosts-set.sh -- WHICH HOSTS bin/ausculte.sh's fleet probe(s) read. One
# list, one file, the same shape as roster-set.sh/estate-set.sh (hf7y/realisateur#1139).
#
# THE DEFECT THIS CLOSES: ausculte.sh's fleet probe read
# `ssh ${AUSCULTE_FLEET_HOST:-monkey}` -- a single default, not a set. A second
# host (vaporwave) was therefore never asked, and its silence read as health --
# this estate's signature defect, at the scale of a whole host. See
# uid-band comments in bin/monkey-status-collect.py for why the SAME shape let
# svc-vaporwave run undetected for weeks; unrelated code, same lesson.
#
# A host in this set that cannot be reached must read BLIND, never be folded
# silently into an OK -- ausculte.sh's fleet probe enforces that, this file
# only says who is asked.

[ -n "${FLEET_HOSTS_SET_LIB:-}" ] && return 0
FLEET_HOSTS_SET_LIB=1

. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/estate-set.sh"

# AUSCULTE_FLEET_HOSTS: space-separated override (tests, and any host not yet
# ready to be asked in production). Unset means the estate's real fleet.
if [ -n "${AUSCULTE_FLEET_HOSTS:-}" ]; then
  # shellcheck disable=SC2206  # deliberate word-split: a space-separated host list, not a path
  FLEET_HOSTS=(${AUSCULTE_FLEET_HOSTS})
else
  # monkey: the estate's original self-dev host. vaporwave: the second one
  # media-arts-collective projects (wavebucks, inventory-app) land on
  # (hf7y/realisateur#1130/#1131/#1132) -- added here so ausculte cannot go on
  # reading vaporwave's silence as health once accounts exist there.
  FLEET_HOSTS=(monkey vaporwave)
fi

# --- AND WHICH PORT REACHES EACH ---------------------------------------------
# Same file because it is the same question: naming a host is useless if the
# name does not select it. dexter, monkey and vaporwave are WSL2 distros sharing
# ONE network namespace, and Windows sshd holds 22 -- so at dexter's address the
# PORT, not the hostname, selects the machine. An ssh_config Host block that
# omits Port therefore does not fail. It reaches a REAL sshd on the WRONG host,
# whose authorized_keys is a different file, and the refusal reads as a broken
# key: hf7y/wtul#131 spent three days concluding "dexter's sshd rejects
# restrict/command=" from exactly that. ausculte.sh's `routes` probe is the
# guard; its propagation probe reads ssh_netns_port_for rather than retyping
# 2223 inline, which is how it used to carry its own copy (realisateur#1189).
SSH_NETNS_ADDR="${SSH_NETNS_ADDR:-dexter.tail893f2c.ts.net}"

# port=who-answers. 22 IS DECLARED ON PURPOSE -- naming it is what lets a block
# that defaults to it read as WRONG rather than as merely unlisted. Proven by
# host key, not belief: `ssh-keyscan -p <port>` re-proves any row, and the
# fingerprints are recorded in provision/monkey-wsl2/runbook.1.
SSH_NETNS_PORTS="${SSH_NETNS_PORTS:-22=windows 2223=dexter 2224=monkey 2225=vaporwave}"

ssh_netns_host_at() {  # <port> -> who answers there; rc 1 for a port not declared
  local kv
  for kv in $SSH_NETNS_PORTS; do
    [ "${kv%%=*}" = "$1" ] && { printf '%s' "${kv#*=}"; return 0; }
  done
  return 1
}

ssh_netns_port_for() {  # <host> -> the port that reaches it, for callers that must build an ssh command rather than use an alias
  local kv
  for kv in $SSH_NETNS_PORTS; do
    [ "${kv#*=}" = "$1" ] && { printf '%s' "${kv%%=*}"; return 0; }
  done
  return 1
}
