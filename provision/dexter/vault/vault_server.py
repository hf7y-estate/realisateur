#!/usr/bin/env python3
"""vault_server.py -- the archive as a service. hf7y/realisateur#1164, #742.

After provision/dexter/roster: the image is RUNTIME, the mount is STATE, and
nothing is pip-installed. Stdlib only -- it must come back up when everything
else is broken.

THE ONE INVARIANT: NO ENDPOINT RETURNS PROSE. That is what this service exists
for. `vault:` is an archive -- prose goes there when it stops being true -- so a
citation is a retrieval and the door is shut (CLAUDE.md, #762). Every other
design here follows from it:

  - /deposit takes prose IN and answers with a commit sha. Never a body.
  - /manifest answers with FRONTMATTER ONLY: which source a note came from and
    the sha256 it was taken at. Never the note.
  - there is no GET that names a file.

WHY /manifest IS NOT A HOLE. `consigne status` -- the reaping queue -- has to
know, per vault note, which repo path it came from and at what hash, so it can
tell a DIVERGED fork from a clean deposit. It compares that against the source
repo in the CALLER's own checkout. So the comparison needs provenance, not
content, and provenance is not the retired premise: `source_sha256` identifies
a source file, and cannot reconstruct a line of the archive. That split is what
lets the queue run from a host with no clone, which is the whole point of
#1164.

WHY A DEPOSIT CARRIES ITS CONTENT, unlike the spool it replaces.
bin/consigne's spool holds absolute PATHS and `vault-spool-drain.sh` reads the
source out of the depositor's own tree -- correct while both are on one
filesystem, impossible across a network. So the body is in the request. The
archive's three integrity reads (is it a repo, does an existing note differ,
does it read back byte-identical) still happen, on this side of the door, which
is where they always belonged.
"""
import hmac
import json
import os
import re
import subprocess
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

VAULT = os.environ.get("VAULT_DIR", "/data/vault")
REMOTE = os.environ.get("VAULT_REMOTE", "https://github.com/hf7y/ecosystem1-vault.git")
PORT = int(os.environ.get("VAULT_PORT", "8647"))
TOKEN = os.environ.get("VAULT_WRITE_TOKEN", "")
PUSH_TOKEN = os.environ.get("VAULT_PUSH_TOKEN", "")
BRANCH = os.environ.get("VAULT_BRANCH", "main")

# A deposit path is <project>/<relative>, both slash-safe. Anchored, and `..`
# is rejected as a whole segment rather than as a substring, so a legitimate
# name like `notes..md` still deposits.
DEPOSIT_PATH_RE = re.compile(r"^[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$")
FRONTMATTER_KEYS = ("source_repo", "source_path", "source_sha256")

_lock = threading.Lock()


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def git(*args, check=True):
    """git in the vault, with output captured. Never inherits a terminal."""
    p = subprocess.run(("git", "-C", VAULT) + args, capture_output=True, text=True)
    if check and p.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {p.stderr.strip() or p.stdout.strip()}")
    return p.stdout.strip()


def push_url():
    """The remote with the push credential spliced in, never logged or stored.
    Absent token -> the bare remote, which fails closed on a private repo."""
    if PUSH_TOKEN and REMOTE.startswith("https://"):
        return REMOTE.replace("https://", f"https://x-access-token:{PUSH_TOKEN}@", 1)
    return REMOTE


def ensure_clone():
    """The clone is STATE in the mount, made once. A missing one is created; a
    present one is left exactly as it is, because this process is not the only
    writer of history and must never reset someone else's."""
    if os.path.isdir(os.path.join(VAULT, ".git")):
        return
    os.makedirs(os.path.dirname(VAULT) or "/data", exist_ok=True)
    p = subprocess.run(("git", "clone", "--branch", BRANCH, push_url(), VAULT),
                       capture_output=True, text=True)
    if p.returncode != 0:
        # Loud, and WITHOUT the url: it carries the token.
        raise RuntimeError("could not clone the vault remote -- check VAULT_PUSH_TOKEN")
    git("config", "user.name", "vault-service")
    git("config", "user.email", "vault-service@localhost")


def frontmatter(path):
    """The first few lines' `key: value` pairs, for the three keys that say
    where a note came from. Reads a bounded prefix, never the note."""
    out = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for i, line in enumerate(fh):
                if i >= 60:
                    break
                for k in FRONTMATTER_KEYS:
                    if line.startswith(f"{k}: "):
                        out.setdefault(k, line[len(k) + 2:].strip())
    except OSError:
        return None
    return out


def manifest():
    """Every note in the vault, as provenance. No bodies, by construction --
    this function has no code path that opens a file for its content."""
    rows = []
    for root, dirs, files in os.walk(VAULT):
        dirs[:] = [d for d in dirs if d != ".git"]
        for name in sorted(files):
            if not name.endswith(".md"):
                continue
            full = os.path.join(root, name)
            fm = frontmatter(full)
            rows.append({
                "path": os.path.relpath(full, VAULT),
                "source_repo": (fm or {}).get("source_repo"),
                "source_path": (fm or {}).get("source_path"),
                "source_sha256": (fm or {}).get("source_sha256"),
                # UNREADABLE is a finding in `consigne status`, so an absent
                # frontmatter must be reported as absent, never omitted.
                "readable": bool(fm and all(k in fm for k in FRONTMATTER_KEYS)),
            })
    return rows


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "vault/1"

    def log_message(self, fmt, *args):
        print(f"{now()} {self.address_string()} {fmt % args}", flush=True)

    def send(self, code, obj):
        body = (json.dumps(obj) + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/healthz":
            # THE SERVICE'S OWN HEALTH IS NOT THE NETWORK'S. `ok` answers "can
            # this process still take a deposit", which needs HEAD and nothing
            # else. Counting unpushed work reads origin/<branch>, a ref that is
            # absent on a fresh clone and stale whenever the remote is
            # unreachable -- graded into `ok` it would restart the container for
            # someone else's outage, and drop the deposits not yet pushed.
            try:
                head = git("rev-parse", "HEAD")
            except RuntimeError as e:
                return self.send(500, {"ok": False, "error": str(e)})
            try:
                unpushed, unpushed_error = int(git("rev-list", "--count",
                                                   f"origin/{BRANCH}..HEAD") or 0), None
            except RuntimeError as e:
                # NOT ZERO. An unmeasured backlog reported as none is the
                # could-not-look-reads-as-nothing-wrong shape; null plus a
                # reason is the honest answer.
                unpushed, unpushed_error = None, str(e)
            return self.send(200, {"ok": True, "head": head, "unpushed": unpushed,
                                   "unpushed_error": unpushed_error,
                                   "notes": len(manifest()),
                                   "writes_enabled": bool(TOKEN)})
        if u.path == "/manifest":
            return self.send(200, {"notes": manifest()})
        # EVERY OTHER GET, including anything that looks like a note path. The
        # message says why, so a caller that wanted to read is told the rule
        # rather than left guessing at a 404.
        return self.send(404, {"error": "the vault serves provenance, never prose "
                                        "(hf7y/realisateur#742); try /manifest"})

    def do_POST(self):
        u = urlparse(self.path)
        if u.path != "/deposit":
            return self.send(404, {"error": "no such path"})
        if not TOKEN:
            return self.send(503, {"error": "VAULT_WRITE_TOKEN is unset -- deposits are "
                                            "refused, never open by default"})
        if not hmac.compare_digest(self.headers.get("X-Vault-Token", ""), TOKEN):
            return self.send(403, {"error": "bad or missing X-Vault-Token"})
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            path, body = req["path"], req["body"]
            by = req.get("by") or "unknown"
        except Exception:                                   # noqa: BLE001
            return self.send(400, {"error": 'want {"path":"<proj>/<file>.md",'
                                            '"body":"<text>","by":"<who>"}'})
        if not isinstance(body, str) or not DEPOSIT_PATH_RE.match(path) \
                or ".." in path.split("/") or not path.endswith(".md"):
            return self.send(400, {"error": "path must be <project>/<name>.md, "
                                            "no .. segment; body must be text"})
        with _lock:
            return self.deposit(path, body, by)

    def deposit(self, path, body, by):
        dest = os.path.join(VAULT, path)
        data = body.encode()
        if os.path.exists(dest):
            with open(dest, "rb") as fh:
                if fh.read() == data:
                    # IDEMPOTENT, not an error: a retried deposit is the same
                    # deposit, and the caller must be able to retry safely.
                    return self.send(200, {"deposited": False, "reason": "identical",
                                           "path": path, "head": git("rev-parse", "HEAD")})
            # THE OVERWRITE REFUSAL, kept from consign-prose: a note somebody
            # annotated is not silently replaced.
            return self.send(409, {"error": "a different note already exists at that path",
                                   "path": path})
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as fh:
            fh.write(data)
        # THE READ-BACK GATE: an archive that edits what it archives has
        # destroyed it, so the bytes come back off disk before this commits.
        with open(dest, "rb") as fh:
            if fh.read() != data:
                os.unlink(dest)
                return self.send(500, {"error": "read-back mismatch -- nothing was committed"})
        try:
            git("add", "--", path)
            git("commit", "-q", "-m", f"consigne: deposit {path} (by {by})")
            head = git("rev-parse", "HEAD")
        except RuntimeError as e:
            return self.send(500, {"error": f"deposit written but not committed: {e}"})
        pushed, why = True, None
        try:
            git("push", "-q", push_url(), f"HEAD:{BRANCH}")
        except RuntimeError as e:
            # PROSE-REAPING.md 2: an unpushed deposit is not deposited. The
            # commit stands and the caller is TOLD, rather than being given a
            # success that only holds on this disk.
            pushed, why = False, str(e).replace(PUSH_TOKEN, "***") if PUSH_TOKEN else str(e)
        return self.send(200 if pushed else 202,
                         {"deposited": True, "path": path, "head": head,
                          "pushed": pushed, "push_error": why})


if __name__ == "__main__":
    ensure_clone()
    print(f"{now()} vault serving on 0.0.0.0:{PORT} vault={VAULT} "
          f"deposits={'enabled' if TOKEN else 'REFUSED (no token)'}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
