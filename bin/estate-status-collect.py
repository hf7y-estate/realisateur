#!/usr/bin/env python3
"""Collect the estate's health AS ITS CONTAINERS REPORT IT.

RUN ON dexter:  python3 estate-status-collect.py
Read-only: reads `docker inspect`, /srv/*/compose.yaml, this account's crontab
and the nightly agent logs under /srv/agent. Writes nothing, starts nothing,
dispatches nothing. Prints one JSON document on stdout -- the payload published
to https://hf7y.com/estate/status.json by bin/estate-watch.sh.

WHY CONTAINERS ARE THE SUBJECT. The unix accounts this replaces are gone with
monkey (2026-09-24). What runs the estate now is two kinds of container, and
they fail differently:

  SERVICES   long-lived, one per /srv/<name>/compose.yaml. Their failure is
             silent: roster sat Exited for four days with RestartCount 0
             because `restart: always` does not cover a container that fails
             at START (realisateur#1191).
  PASSES     one --rm container per repo per night, spawned by /srv/agent.
             Their failure is also silent -- the pass "finishes" and the work
             is simply absent -- so a pass is graded on what it LEFT, not on
             its exit code alone.

Every field is a probe of live state at generation time. A field this script
cannot read is null, never a guess or a zero: a missing log means the repo has
never been dispatched, which is a finding, not a blank.
"""
import datetime, glob, json, os, re, subprocess

SRV = os.environ.get("ESTATE_SRV", "/srv")
AGENT = os.environ.get("ESTATE_AGENT_DIR", "/srv/agent")
DOCKER = os.environ.get("ESTATE_DOCKER", "docker")
CRONTAB = os.environ.get("ESTATE_CRONTAB", "crontab")
CADENCE_MIN = int(os.environ.get("ESTATE_CADENCE_MIN", "20"))
GRACE_MIN = int(os.environ.get("ESTATE_GRACE_MIN", "40"))
# The hourly gated tick is the only starter. Zach, 2026-10-09, asked whether
# the ungated 01:00 row goes: "1 remove it." (#1677)
NIGHTLY_TAG = "realisateur:agent-burn:RUNNER"
NIGHTLY_MAX_H = 26          # the tick is hourly; a day with no run is a finding
NO_AUTOSTART = ".no-autostart"   # provision/dexter/autostart/dexter-srv-autostart's own opt-out marker
PULL_RE = re.compile(r"https://github\.com/[\w.-]+/[\w.-]+/pull/\d+")
# The files the dispatcher IS. They are not a checkout (#1332): unless
# each is a symlink into a clone that something pulls, a merged fix reaches the
# 01:00 pass on no path -- and reads exactly like a fix.
DISPATCH_FILES = ("nightly.sh", "run-agent.sh", "merge-carry.sh", "Dockerfile")
AGENT_SRC = os.environ.get(
    "ESTATE_AGENT_SRC",
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "agent"))
WIRE = os.environ.get(
    "ESTATE_WIRE", os.path.join(os.path.dirname(os.path.abspath(__file__)), "wire-agent-dispatch.sh"))
TOKCHECK = os.environ.get(
    "ESTATE_TOKCHECK",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "dispatch-token-check.sh"))


def sh_rc(*cmd):
    """(returncode, stdout) -- "could not look" and "found nothing" are
    different answers and a bare stdout conflates them."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return 127, ""
    return p.returncode, p.stdout


def now_z():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)


def z(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_z(s):
    if not s:
        return None
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def age_h(s, ref):
    d = parse_z(s)
    return None if d is None else round((ref - d).total_seconds() / 3600, 1)


# --- containers --------------------------------------------------------------
def inspect_all():
    """Every container on the host, running or not. None means the daemon
    could not be reached -- which is a different report from "none running"."""
    rc, out = sh_rc(DOCKER, "ps", "-aq")
    if rc != 0:
        return None
    ids = out.split()
    if not ids:
        return []
    rc, out = sh_rc(DOCKER, "inspect", *ids)
    if rc != 0:
        return None
    try:
        return json.loads(out)
    except ValueError:
        return None


def published(c):
    """True when at least one declared binding actually reached the host.
    A running container whose declared ports are unpublished is unreachable
    while `docker ps`, its healthcheck and its unit all read healthy -- the
    exact state dexter-srv-autostart was written to make visible."""
    want = c.get("HostConfig", {}).get("PortBindings") or {}
    if not want:
        return None                      # declares nothing: not a question
    have = c.get("NetworkSettings", {}).get("Ports") or {}
    return any(v for v in have.values())


def container_row(c):
    st = c.get("State", {})
    return {
        "name": c.get("Name", "").lstrip("/"),
        "image": c.get("Config", {}).get("Image"),
        "project": (c.get("Config", {}).get("Labels") or {}).get("com.docker.compose.project"),
        "state": st.get("Status"),
        "health": (st.get("Health") or {}).get("Status"),
        "restarts": c.get("RestartCount"),
        "exit_code": st.get("ExitCode") if st.get("Status") == "exited" else None,
        "started_at": z(parse_z(st.get("StartedAt"))) if parse_z(st.get("StartedAt")) else None,
        "finished_at": z(parse_z(st.get("FinishedAt"))) if st.get("Status") == "exited" and parse_z(st.get("FinishedAt")) else None,
        "ports_published": published(c),
    }


def declared_services():
    """One per /srv/<name>/compose.yaml. `.no-autostart` marks a service whose
    RESTING STATE IS STOPPED (groc-browser is started on demand and parked by
    its own idle-stop cron) -- stopped is correct there, so it is not graded."""
    out = []
    for p in sorted(glob.glob(os.path.join(SRV, "*", "compose.yaml"))):
        d = os.path.dirname(p)
        out.append({"name": os.path.basename(d), "dir": d,
                    "on_demand": os.path.exists(os.path.join(d, NO_AUTOSTART))})
    return out


# --- the nightly pass layer --------------------------------------------------
def nightly_armed():
    rc, out = sh_rc(CRONTAB, "-l")
    if rc != 0:
        return None, None                # could not read a crontab != no crontab
    for line in out.splitlines():
        s = line.strip()
        if NIGHTLY_TAG in s and not s.startswith("#"):
            return True, s
    return False, None


def latest(pattern):
    """Newest by NAME, not mtime: the stamp is in the filename and is UTC, so
    a lexical max is chronological and a touched file cannot jump the queue."""
    hits = sorted(glob.glob(os.path.join(AGENT, pattern)))
    return hits[-1] if hits else None


def read(path):
    try:
        with open(path, errors="replace") as f:
            return f.read()
    except OSError:
        return None


def repo_list():
    """Every repo a pass has ever run in: `<repo>.<stamp>.log` under the agent
    dir. The hand list this used to read is gone -- the org is the set and the
    logs are the order (#1476)."""
    if not os.path.isdir(AGENT):
        return None
    return sorted({m.group(1) for f in os.listdir(AGENT)
                   if (m := PASS_LOG.match(f)) and m.group(1) != "nightly"})


PASS_LOG = re.compile(r"^(.+)\.\d{8}T\d{6}Z\.log$")
NIGHT_HEAD = re.compile(r"^=== nightly (\S+)\s+turns=(\d+)")
NIGHT_DONE = re.compile(r"^=== nightly done (\S+) ===")
DISPATCH = re.compile(r"^--- (\S+): (\d+) runnable, dispatching (\S+)")
# The image is the pass's other input, and `:latest` cannot say which one ran --
# so the log prints a digest and this reads it back. A failed pull is its own
# outcome, not a night that merely lacks a `done` line: nothing was dispatched.
NIGHT_IMAGE = re.compile(r"^=== image: (\S+) ===")
NIGHT_PULLFAIL = re.compile(r"^=== PULL FAILED: (\S+)")
SKIP = re.compile(r"^--- (\S+): queue empty, skipping")
BLIND = re.compile(r"^--- (\S+): COULD NOT READ THE QUEUE")
FINISH = re.compile(r"^--- (\S+): pass (finished|exited (\d+))")


def nightly_run():
    """The last sweep: when it started, what it dispatched, whether it ended.
    A sweep with no `done` line did not finish -- it is still running, or it
    died -- and those read identically from here, so both say so."""
    path = latest("nightly.*.log")
    if not path:
        return None
    txt = read(path) or ""
    run = {"log": os.path.basename(path), "started_at": None, "finished_at": None,
           "turns": None, "image": None, "pull_failed": None,
           "dispatched": {}, "skipped": [], "queue_unreadable": []}
    for line in txt.splitlines():
        m = NIGHT_HEAD.match(line)
        if m and run["started_at"] is None:
            run["started_at"], run["turns"] = m.group(1), int(m.group(2))
        m = NIGHT_DONE.match(line)
        if m:
            run["finished_at"] = m.group(1)
        m = NIGHT_IMAGE.match(line)
        if m:
            run["image"] = m.group(1)
        m = NIGHT_PULLFAIL.match(line)
        if m:
            run["pull_failed"] = m.group(1)
        m = DISPATCH.match(line)
        if m:
            run["dispatched"][m.group(1)] = {"queue": int(m.group(2)), "at": m.group(3), "outcome": None}
        m = SKIP.match(line)
        if m:
            run["skipped"].append(m.group(1))
        m = BLIND.match(line)
        if m:
            run["queue_unreadable"].append(m.group(1))
        m = FINISH.match(line)
        if m and m.group(1) in run["dispatched"]:
            run["dispatched"][m.group(1)]["outcome"] = "finished" if m.group(2) == "finished" else f"exited {m.group(3)}"
    return run


RESULT = re.compile(r"^=== result: (\S+)\s+turns=(\d+)\s+cost=\$(\S+)")
EXITED = re.compile(r"^=== (\S+) container exited \(rc=(\d+)\) ===")
# A tool call is echoed as "  > Bash gh issue comment ...", one line per call
# (run-agent.sh's own stream-json formatting) -- so a comment the pass left on
# its issue is read back from the log it was already printed to, the same way
# the PR it opened is (#1416: the file a pass used to write FOR the collector
# is retired; what a pass left is read from what it already produced).
COMMENTED = re.compile(r"gh issue comment\b")


def pass_row(repo):
    """The repo's most recent container pass, graded on WHAT IT LEFT: a PR it
    opened, a comment on its issue, or neither.

    `result: success` means claude exited cleanly, which it also does when it
    read the queue and wrote "nothing finishable from here" in a comment -- a
    successful run of the mechanism. So landing nothing is read off the PR and
    the comment, never inferred from the exit code."""
    path = latest(f"{repo}.*.log")
    if not path:
        return {"repo": repo, "log": None, "result": None, "turns": None,
                "cost_usd": None, "rc": None, "pr": None, "commented": False,
                "at": None, "note": "never dispatched: no log under the agent dir"}
    txt = read(path)
    if txt is None:
        return {"repo": repo, "log": os.path.basename(path), "result": None, "turns": None,
                "cost_usd": None, "rc": None, "pr": None, "commented": False,
                "at": None, "note": "log present but unreadable"}
    row = {"repo": repo, "log": os.path.basename(path), "result": None, "turns": None,
           "cost_usd": None, "rc": None, "pr": None, "commented": False, "note": None}
    stamp = os.path.basename(path).rsplit(".", 2)[-2]
    row["at"] = f"{stamp[:4]}-{stamp[4:6]}-{stamp[6:11]}:{stamp[11:13]}:{stamp[13:16]}"
    for line in txt.splitlines():
        m = RESULT.match(line)
        if m:
            row["result"], row["turns"] = m.group(1), int(m.group(2))
            try:
                row["cost_usd"] = round(float(m.group(3)), 4)
            except ValueError:
                row["cost_usd"] = None
        m = EXITED.match(line)
        if m:
            row["rc"] = int(m.group(2))
        if COMMENTED.search(line):
            row["commented"] = True
    # The PR the pass opened. NOT off the PR author: the container pushes with
    # the estate's own token, so every PR it opens is authored `hf7y` --
    # nightly.sh's own summary greps for `claude|agent` and has therefore
    # matched nobody on every green night.
    hit = PULL_RE.search(txt)
    if hit:
        row["pr"] = hit.group(0)
    return row


def dispatch_source():
    """Per file: is what dexter executes the file `main` holds, and will it
    STAY so? `linked` is the only state that survives the next merge.

    The classification is NOT repeated here. `wire-agent-dispatch.sh --state`
    is the one home for it, and it is the same code path `--apply` acts on, so
    the page cannot say `behind` about a file the verb would call `drifted`."""
    if not os.path.isdir(AGENT_SRC) or not os.access(WIRE, os.X_OK):
        return None                      # not run from a checkout: cannot say
    env = dict(os.environ, AGENT_DIR=AGENT, AGENT_SRC=AGENT_SRC)
    try:
        p = subprocess.run([WIRE, "--state"], capture_output=True, text=True,
                           timeout=60, env=env)
    except (OSError, subprocess.SubprocessError):
        return None
    if p.returncode != 0:
        return None
    out = {}
    for line in p.stdout.splitlines():
        f, _, state = line.partition("\t")
        if f in DISPATCH_FILES and state:
            out[f] = state
    return out or None


def dispatch_token():
    """What the credential the nightly pushes with can still do.

    The credential itself is never read here and never printed anywhere: the
    script answers on the host and hands back a shape, a login and two words.
    An agent cannot ask this question at all -- the harness refuses any command
    that materialises a credential -- which is exactly why it lives on a cron
    row instead of in somebody's terminal."""
    if not os.access(TOKCHECK, os.X_OK):
        return None
    try:
        p = subprocess.run([TOKCHECK, "--state"], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    out = {}
    for line in p.stdout.splitlines():
        k, _, v = line.partition("\t")
        if k and v:
            out[k] = v
    return out or None


# --- verdict -----------------------------------------------------------------
def grade(d):
    """DOWN is "something the estate needs is not running". DEGRADED is
    "running, and not doing its job". Every BLIND field grades DEGRADED: an
    unread probe must never read as a healthy one."""
    bad, warn = [], []
    if d["containers"] is None:
        return "DOWN", ["the docker daemon did not answer -- nothing below was read"]

    running = {c["name"] for c in d["containers"] if c["state"] == "running"}
    projects = {c["project"] for c in d["containers"] if c["state"] == "running" and c["project"]}
    for s in d["services"]:
        if s["on_demand"]:
            continue
        if s["name"] not in projects and s["name"] not in running:
            bad.append(f"{s['name']}: declared in {s['dir']}/compose.yaml and NOT running")
    for c in d["containers"]:
        if c["state"] != "running":
            continue
        if c["health"] == "unhealthy":
            warn.append(f"{c['name']}: healthcheck says unhealthy")
        if c["ports_published"] is False:
            warn.append(f"{c['name']}: running with NONE of its declared ports published")
        if (c["restarts"] or 0) > 3:
            warn.append(f"{c['name']}: restarted {c['restarts']} times")

    n = d["nightly"]
    if n["armed"] is None:
        warn.append("could not read the crontab -- whether the nightly is armed is UNKNOWN")
    elif not n["armed"]:
        bad.append(f"no crontab line carries {NIGHTLY_TAG} -- nothing dispatches tonight")
    if n["last_run"] is None:
        bad.append(f"no nightly log under {AGENT} -- the dispatcher has never run here")
    else:
        a = n["last_run"]["age_h"]
        if a is None:
            warn.append("the last nightly log has no parseable start time")
        elif a > NIGHTLY_MAX_H:
            bad.append(f"the last nightly started {a}h ago, past the {NIGHTLY_MAX_H}h a daily cron allows")
        elif n["last_run"]["pull_failed"]:
            bad.append(f"the nightly could not pull {n['last_run']['pull_failed']} and dispatched nothing -- "
                       "no container ran, so nothing landed")
        elif n["last_run"]["finished_at"] is None:
            warn.append("the last nightly has no `done` line -- still running, or it died")
        for repo in n["last_run"]["queue_unreadable"]:
            warn.append(f"{repo}: the nightly could not read its queue and skipped it")
        for repo, v in n["last_run"]["dispatched"].items():
            if v["outcome"] and v["outcome"] != "finished":
                warn.append(f"{repo}: pass {v['outcome']}")
    tok = n["dispatch_token"]
    if tok is None:
        warn.append("the dispatch credential was not asked about -- whether tonight can push is UNKNOWN")
    elif tok.get("reachable") == "no":
        # Nothing the nightly does lands. That is not "degraded", it is a night
        # of containers that cost money and push nothing.
        bad.append(f"the credential the nightly pushes with is not accepted: {tok.get('why', 'no reason given')}")
    elif tok.get("reachable") != "yes":
        warn.append(f"could not ask what the dispatch credential can do: {tok.get('why', 'no reason given')}")
    elif tok.get("workflows") == "no":
        warn.append("the dispatch credential cannot push `.github/workflows/` -- a pass that edits "
                    "one commits, fails to push, and has nothing to show for it")
    elif tok.get("workflows") == "unknown":
        warn.append(f"whether the dispatch credential may push `.github/workflows/` is UNKNOWN: "
                    f"{tok.get('why', 'no reason given')}")

    src = n["dispatch_source"]
    if src is None:
        warn.append("not run from a checkout, so whether /srv/agent matches `main` is UNKNOWN")
    else:
        # DRIFT is the loud one: the host is running code no PR describes.
        # A plain COPY is quieter and just as real -- it agrees today and
        # nothing will ever refresh it.
        # DRIFTED is the loud one: bytes that were never this path's content, so
        # somebody edited the host and `--apply` will refuse them. BEHIND is the
        # ordinary morning-after state and links cleanly; a plain COPY agrees
        # today and nothing will ever refresh it. Each is a finding: no state
        # but `linked` survives the next merge.
        drifted = [f for f, v in src.items() if v in ("drifted", "not-in-clone")]
        behind = [f for f, v in src.items() if v == "behind"]
        stale = [f for f, v in src.items() if v in ("copy", "absent")]
        if drifted:
            warn.append(f"{AGENT}: {' '.join(drifted)} hold bytes that were never on `main` -- "
                        f"somebody edited the host. `bin/wire-agent-dispatch.sh --check`")
        if behind:
            warn.append(f"{AGENT}: the nightly is running an EARLIER {' '.join(behind)} than "
                        f"`main` holds. `bin/wire-agent-dispatch.sh --apply`")
        elif stale and not drifted:
            warn.append(f"{AGENT}: {' '.join(stale)} are plain copies, so a merged fix reaches "
                        f"the nightly on no path. `bin/wire-agent-dispatch.sh --apply`")

    for p in n["passes"]:
        if p["log"] is None:
            warn.append(f"{p['repo']}: on the repo list and never dispatched")
        elif p["result"] and p["result"] != "success":
            warn.append(f"{p['repo']}: last pass ended `{p['result']}`")
        elif not p["pr"] and not p["commented"]:
            warn.append(f"{p['repo']}: last pass landed nothing -- no PR and no comment on its issue")

    if bad:
        return "DOWN", bad + warn
    if warn:
        return "DEGRADED", warn
    return "OK", []


def main():
    now = now_z()
    containers = inspect_all()
    rows = None if containers is None else sorted(
        (container_row(c) for c in containers), key=lambda r: r["name"])
    services = declared_services()
    armed, cron_line = nightly_armed()
    run = nightly_run()
    if run is not None:
        run["age_h"] = age_h(run["started_at"], now)
    repos = repo_list()
    passes = [pass_row(r) for r in (repos or [])]
    declared = {s["name"] for s in services}
    d = {
        "generated_at": z(now),
        "host": os.environ.get("ESTATE_HOST", "dexter"),
        "cadence_min": CADENCE_MIN,
        "grace_min": GRACE_MIN,
        "valid_until": z(now + datetime.timedelta(minutes=CADENCE_MIN + GRACE_MIN)),
        "containers": rows,
        "services": services,
        # Containers no compose file under /srv declares. Not graded -- a
        # hand-typed `docker run` is a legitimate thing to have done -- but
        # listed, because the page must not read as a census it is not.
        "unmanaged": None if rows is None else [
            r["name"] for r in rows if r["project"] not in declared],
        "nightly": {
            "armed": armed, "cron_line": cron_line,
            "repos": repos, "last_run": run, "passes": passes,
            "dispatch_source": dispatch_source(),
            "dispatch_token": dispatch_token(),
            "max_age_h": NIGHTLY_MAX_H,
        },
    }
    d["verdict"], d["findings"] = grade(d)
    print(json.dumps(d, indent=1, sort_keys=False))


if __name__ == "__main__":
    main()
