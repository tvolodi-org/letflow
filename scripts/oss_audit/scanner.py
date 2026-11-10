#!/usr/bin/env python3
"""Read-only secrets / internal-text scanner for the tracked tree and the full git history (T-1597).

stdlib only. Output per finding is exactly: scope, path, commit, rule id, severity, masked hint,
seen_in, in_head. The matched text, the line and any context are never printed, logged or put in
an exception message. Value hashes live in memory only (dedupe and the in_head join).
Exit: 0 complete (findings do not change it: this is an audit, not a gate), 3 partial (deadline),
4 incomplete coverage (a git read failed, unreadable files, commit count mismatch), 2 usage / not a git repo, 1 only for --check-file when a secret-class rule fires.
"""

import argparse
import hashlib
import ipaddress
import json
import math
import os
import re
import signal
import sqlite3
import subprocess
import sys
import threading
import time
from collections import Counter, defaultdict

sys.dont_write_bytecode = True  # no __pycache__ in the audited repository
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rules as R  # noqa: E402

GIT = os.environ.get("OSS_AUDIT_GIT") or "git"
WINDOW = 20000
OVERLAP = 256
MAX_FILE = 50 * 1024 * 1024
BLOB_CAP = 2000
UNSAFE_LOG_OPTS = ("--output", "--ext-diff", "--textconv", "--exec", "--upload-pack")
OWN_PREFIXES = ("scripts/oss_audit/", "test/scripts/oss_audit_test.exs", "docs/open-source/audit-report.md")

PATH_CLASSES = [
    ("handoffs/", "handoffs"), ("replay-work/", "replay-work"), ("state/", "state"),
    ("docs/uat/", "docs/uat"), ("docs/migration/", "docs/migration"), ("docs/runbooks/", "docs/runbooks"),
    (".claude/", ".claude"), (".github/", ".github"), ("deploy/", "deploy"), ("config/", "config"),
    ("priv/", "priv"), ("test/", "test"), ("web/", "web"), ("apps/mobile/", "apps/mobile"),
    ("docs/", "docs"), ("lib/", "lib"), ("scripts/", "scripts"),
]
CONFIG_EXT = {".env", ".yml", ".yaml", ".sh", ".exs", ".json", ".toml", ".ini", ".cfg", ".conf",
              ".properties", ".tf", ".service", ".bash", ".ps1", ".bat", ".cmd", ".dockerfile"}
DOC_EXT = {".md", ".txt", ".rst", ".adoc"}
LOCK_NAMES = {"mix.lock", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "pubspec.lock"}

STATE = {
    "git_failures": 0, "deadline": False, "rule_errors": Counter(), "last_commit": "", "procs": set(), "done": threading.Event(),
}


def path_class(path):
    for prefix, name in PATH_CLASSES:
        if path.startswith(prefix):
            return name
    return "other"


def file_kind(path):
    base = os.path.basename(path).lower()
    ext = os.path.splitext(base)[1]
    kinds = set()
    if ext in CONFIG_EXT or base.startswith(".env") or base.startswith("dockerfile") or "docker-compose" in base:
        kinds.add("config")
    if ext in DOC_EXT:
        kinds.add("doc")
    if base in LOCK_NAMES:
        kinds.add("lock")
    return kinds


# ---------------------------------------------------------------- subprocess + deadline

def spawn(args, **kw):
    proc = subprocess.Popen([GIT] + args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            start_new_session=True, bufsize=1 << 20, **kw)
    STATE["procs"].add(proc)
    return proc


def kill_group(proc, grace=2.0):
    try:
        pgid = os.getpgid(proc.pid)
    except (ProcessLookupError, PermissionError):
        pgid = None
    if pgid is not None:
        try:
            os.killpg(pgid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass
        t0 = time.time()
        while proc.poll() is None and time.time() - t0 < grace:
            time.sleep(0.05)
        try:
            os.killpg(pgid, signal.SIGKILL)  # descendants (helpers, shim sleep) die with the group
        except (ProcessLookupError, PermissionError):
            pass
    try:
        proc.wait(timeout=5)
    except Exception:
        pass


def release(proc):
    try:
        if proc.stdout:
            proc.stdout.close()
    except Exception:
        pass
    kill_group(proc, grace=0.0)
    STATE["procs"].discard(proc)


def git_out(args):
    """Run a short read-only git command; returns bytes ('' on failure). Same group/deadline handling."""
    proc = spawn(args)
    try:
        data = proc.stdout.read()
        proc.wait()
        if proc.returncode != 0 and not STATE["deadline"]:
            STATE["git_failures"] += 1
    finally:
        release(proc)
    return data


def watchdog(deadline_at):
    remaining = deadline_at - time.time()
    if remaining > 0 and STATE["done"].wait(remaining):
        return
    STATE["deadline"] = True
    for p in list(STATE["procs"]):
        kill_group(p)
    if STATE["done"].wait(5):
        return
    sys.stdout.write("PARTIAL: deadline; last commit reached %s\n" % (STATE["last_commit"] or "none"))
    sys.stdout.flush()
    os._exit(3)


# ---------------------------------------------------------------- matching

def entropy(s):
    c = Counter(s)
    n = len(s)
    return -sum(v / n * math.log2(v / n) for v in c.values())


def mask(value):
    if len(value) >= 12:
        return value[:2] + ".." + value[-2:]
    return "**"


def ip_class(text):
    try:
        ip = ipaddress.ip_address(text)
    except ValueError:
        return None
    if ip.is_loopback or ip.is_unspecified or ip.is_multicast or ip.is_link_local or ip.is_reserved:
        return None
    if ip in ipaddress.ip_network("192.0.2.0/24") or ip in ipaddress.ip_network("198.51.100.0/24") \
            or ip in ipaddress.ip_network("203.0.113.0/24"):
        return None
    if ip.is_private:
        return "private"
    return "public"


def pii_ok(local, dom):
    d = dom.lower()
    if any(x in d for x in R.PII_RESERVED_DOMAINS) or "noreply" in local.lower() or "no-reply" in local.lower():
        return False
    if d.rsplit(".", 1)[-1] in R.PII_FILE_TLDS:
        return False
    return True


def scan_text(line, kinds, noise):
    """Yield (rule_id, sev, cls, hint, ident) for one line. ident is the in-memory identity of the value."""
    low = line.lower()
    for rule in R.RULES:
        if rule.get("noise") and not noise:
            continue
        ex = rule.get("exts")
        if ex is not None and not (ex & kinds):
            continue
        if not any(n in low for n in rule["needles"]):
            continue
        try:
            for m in rule["rx"].finditer(line):
                g = m.groupdict()
                v = next((g[k] for k in ("v", "v2", "v3") if g.get(k)), None)
                rid = rule["id"]
                sev = rule["sev"]
                if rule.get("check_value") and (v is None or R.is_placeholder(v)):
                    continue
                if rule.get("conn"):
                    if R.is_placeholder(g["u"]) and R.is_placeholder(v):
                        continue
                    host = g["h"].lower()
                    if host in ("localhost", "db", "postgres", "redis", "127.0.0.1") or "example" in host:
                        sev = "H"
                    else:
                        sev = "C"
                if rule.get("entropy"):
                    if len(v) < 24 or entropy(v) < 4.2 or re.fullmatch(r"[0-9a-f]{32,64}", v) \
                            or re.fullmatch(r"[0-9a-fA-F\-]{36}", v) or "lock" in kinds:
                        continue
                if rule.get("ip"):
                    cls = ip_class(v)
                    if cls is None:
                        continue
                    if (rid == "I01") != (cls == "public"):
                        continue
                    pre = line[max(0, m.start() - 3):m.start()]
                    if pre[-1:] in ("v", "@") or pre.endswith("~>") or pre[-1:] == "V":
                        continue
                if rid == "P01" and not pii_ok(g["l"], g["d"]):
                    continue
                mode = rule["mode"]
                val = v if v is not None else m.group(0)
                if mode == "mask":
                    hint = mask(val)
                elif mode == "domain":
                    hint = "email:" + g["d"].lower()
                elif mode == "keyword":
                    hint = val.lower().replace(" ", "")
                elif mode == "host":
                    hint = "host:ai-dala.com"
                else:
                    hint = "**"
                ident = hashlib.sha256(val.encode("utf-8", "replace")).hexdigest() if rule["cls"] == "secret" \
                    else hint + ("|" + g["l"].lower() if rid == "P01" else "")
                yield (rid, sev, rule["cls"], hint, ident)
        except Exception:
            STATE["rule_errors"][rule["id"]] += 1


def scan_line_windowed(line, kinds, noise, cov):
    line = line.rstrip("\r\n")
    if len(line) <= WINDOW:
        yield from scan_text(line, kinds, noise)
        return
    cov["long_lines_windowed"] += 1
    step = WINDOW - OVERLAP
    for i in range(0, len(line), step):
        yield from scan_text(line[i:i + WINDOW], kinds, noise)
        if STATE["deadline"]:
            return


# ---------------------------------------------------------------- findings store

class Findings:
    def __init__(self):
        self.recs = {}
        self.tree_idents = set()
        self.summary = Counter()

    def add(self, scope, path, commit, hit, ts=0):
        rid, sev, cls, hint, ident = hit
        key = (scope, path, rid, ident)
        rec = self.recs.get(key)
        if rec is None:
            self.recs[key] = {"scope": scope, "path": path, "commit": commit, "rule": rid, "sev": sev,
                              "hint": hint, "seen_in": 1, "ident": ident, "_last": commit, "ts": ts}
            if scope == "tree":
                self.tree_idents.add((rid, ident))
        else:
            if scope == "history":
                if commit != rec["_last"]:
                    rec["seen_in"] += 1
                    rec["_last"] = commit
                if ts and ts <= rec["ts"]:
                    rec["commit"], rec["ts"] = commit, ts
            else:
                rec["seen_in"] += 1

    def rows(self, have_tree):
        out = []
        for rec in self.recs.values():
            in_head = ("yes" if (rec["rule"], rec["ident"]) in self.tree_idents else "no") if have_tree else "n/a"
            if rec["scope"] == "tree":
                in_head = "yes"
            out.append((rec["scope"], rec["path"], rec["commit"], rec["rule"], rec["sev"], rec["hint"],
                        rec["seen_in"], in_head))
        out.sort(key=lambda r: (r[0], r[1], r[3], r[2], r[5], r[6]))
        return out


# ---------------------------------------------------------------- binary / sqlite

STR_ASCII = re.compile(rb"[\x20-\x7e]{6,}")
STR_UTF16 = re.compile(rb"(?:[\x20-\x7e]\x00){6,}")


def audit_binary(data, path, scope, commit, store, cov, noise, ts=0):
    if data[:16] == b"SQLite format 3\x00":
        if audit_sqlite(data, path, scope, commit, store, cov, noise, ts):
            return
    cov["binary_scanned"] += 1
    kinds = file_kind(path)
    for rx, dec in ((STR_ASCII, "ascii"), (STR_UTF16, "utf-16-le")):
        for m in rx.finditer(data):
            if STATE["deadline"]:
                return
            text = m.group(0).decode(dec, "replace")
            for hit in scan_line_windowed(text, kinds | {"config", "doc"}, noise, cov):
                store.add(scope, path, commit, hit, ts)


def audit_sqlite(data, path, scope, commit, store, cov, noise, ts=0):
    try:
        buf = bytearray(data)
        if len(buf) > 20 and buf[18] == 2 and buf[19] == 2:  # WAL header: an in-memory db cannot open it
            buf[18] = buf[19] = 1  # patched copy in memory only; the file is never touched
        con = sqlite3.connect(":memory:")
        con.deserialize(bytes(buf))
        tables = [r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")]
    except Exception:
        return False
    cov["sqlite_audited"] += 1
    kinds = {"config", "doc"}
    for t in tables:
        try:
            cur = con.execute('SELECT * FROM "%s"' % t.replace('"', '""'))
            cols = [d[0] for d in cur.description]
            n = 0
            for row in cur:
                n += 1
                if STATE["deadline"]:
                    return True
                for col, cell in zip(cols, row):
                    if isinstance(cell, bytes):
                        cell = cell.decode("utf-8", "replace")
                    if not isinstance(cell, str) or not cell:
                        continue
                    for ln in cell.split("\n"):
                        for hit in scan_line_windowed(ln, kinds, noise, cov):
                            store.add(scope, "%s#%s.%s" % (path, t, col), commit, hit, ts)
            cov["sqlite_rows"] += n
        except Exception:
            STATE["rule_errors"]["sqlite:" + t] += 1
    con.close()
    return True


# ---------------------------------------------------------------- tree

def decode_path(b):
    return b.decode("utf-8", "surrogateescape")


def is_own(path):
    return path.startswith(OWN_PREFIXES)


def scan_tree(root, store, cov, noise):
    files = [decode_path(p) for p in git_out(["-C", root, "ls-files", "-z"]).split(b"\0") if p]
    for path in files:
        if STATE["deadline"]:
            return
        if is_own(path):
            continue
        full = os.path.join(root, os.fsencode(path).decode("utf-8", "surrogateescape"))
        if os.path.islink(full) or not os.path.isfile(full):
            continue
        try:
            size = os.path.getsize(full)
        except OSError:
            cov["unreadable"] += 1
            continue
        if size > MAX_FILE:
            cov["unscanned_oversize"] += 1
            cov["oversize_paths"].append(path)
            continue
        cov["tree_files"] += 1
        try:
            with open(full, "rb") as fh:
                head = fh.read(8192)
                if b"\0" in head:
                    audit_binary(head + fh.read(), path, "tree", "HEAD", store, cov, noise)
                    continue
                kinds = file_kind(path)
                fh.seek(0)
                for raw in fh:
                    if STATE["deadline"]:
                        return
                    for hit in scan_line_windowed(raw.decode("utf-8", "replace"), kinds, noise, cov):
                        store.add("tree", path, "HEAD", hit)
        except OSError:
            cov["unreadable"] += 1


# ---------------------------------------------------------------- history

BIN_RX = re.compile(rb"^Binary files (.+) and (.+) differ\s*$")


def clean_path(raw):
    p = raw.rstrip(b"\r\n").split(b"\t")[0].decode("utf-8", "replace")
    if p.startswith('"') and p.endswith('"'):
        p = p[1:-1]
    return p


def scan_history(root, store, cov, noise, rev_args):
    cmd = ["-C", root, "log"] + (rev_args or ["--all"]) + [
        "--no-color", "-p", "-U0", "-m", "--no-renames", "--no-ext-diff", "--no-textconv",
        "--format=C %H %ct %P"]
    proc = spawn(cmd)
    commit, ts, path, in_header = "", 0, None, False
    seen = set()
    blobs = []
    try:
        for raw in proc.stdout:
            if STATE["deadline"]:
                break
            c0 = raw[:1]
            if c0 == b"C" and raw.startswith(b"C ") and len(raw) > 42:
                parts = raw.split()
                commit, ts = parts[1].decode()[:12], int(parts[2])
                seen.add(parts[1])
                STATE["last_commit"] = commit
                path, in_header = None, False
                continue
            if raw.startswith(b"diff --git "):
                path, in_header = None, True
                cov["patch_sections"] += 1
                continue
            if in_header:
                if raw.startswith(b"+++ "):
                    p = clean_path(raw[4:])
                    path = p[2:] if p.startswith("b/") else None
                elif raw.startswith(b"Binary files"):
                    m = BIN_RX.match(raw)
                    if m:
                        b = clean_path(m.group(2))
                        if b != "/dev/null":
                            blobs.append((commit, b[2:] if b.startswith("b/") else b, ts))
                elif raw.startswith(b"@@"):
                    in_header = False
                continue
            if c0 == b"@" and raw.startswith(b"@@"):
                continue
            if c0 == b"+" and path is not None and not is_own(path):
                kinds = file_kind(path)
                for hit in scan_line_windowed(raw[1:].decode("utf-8", "replace"), kinds, noise, cov):
                    store.add("history", path, commit, hit, ts)
        proc.wait()
        if proc.returncode != 0 and not STATE["deadline"]:
            STATE["git_failures"] += 1  # the history stream ended early: coverage cannot be claimed
    finally:
        release(proc)
    cov["commits_scanned"] = len(seen)
    if STATE["deadline"]:
        return
    audited = set()
    for i, (cm, p, ts) in enumerate(blobs):
        if is_own(p):
            continue
        if i >= BLOB_CAP:
            cov["blob_cap_hit"] = True
            break
        if STATE["deadline"]:
            return
        data = git_out(["-C", root, "cat-file", "blob", "%s:%s" % (cm, p)])
        if not data:
            continue
        h = hashlib.sha256(data).digest()
        if h in audited:
            continue
        audited.add(h)
        cov["blobs_audited"] += 1
        if len(data) > MAX_FILE:
            cov["unscanned_oversize"] += 1
            continue
        audit_binary(data, p, "history", cm, store, cov, noise, ts)


# ---------------------------------------------------------------- main

def check_file(path):
    hits = 0
    kinds = {"config", "doc"}
    with open(path, "rb") as fh:
        for raw in fh:
            for hit in scan_line_windowed(raw.decode("utf-8", "replace"), kinds, False, Counter()):
                if hit[2] == "secret":
                    hits += 1
                    print("%s\t%s\t%s" % (path, hit[0], hit[3]))
    return 1 if hits else 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="oss_audit.sh", description=__doc__.split("\n")[0])
    ap.add_argument("--tree", action="store_true")
    ap.add_argument("--history", action="store_true")
    ap.add_argument("--rev-range", default=None, help="git revision args for the history scan (default --all)")
    ap.add_argument("--budget-seconds", type=float, default=900)
    ap.add_argument("--format", choices=("tsv", "json"), default="tsv")
    ap.add_argument("--out", default=None)
    ap.add_argument("--include-noise", action="store_true", help="also run noise rules S14 and I02")
    ap.add_argument("--check-file", default=None, help="scan one file with secret rules only; exit 1 on a hit")
    ap.add_argument("--repo", default=".", help="repository (default: current directory)")
    a = ap.parse_args(argv)

    if a.check_file:
        return check_file(a.check_file)

    rev_tokens = a.rev_range.split() if a.rev_range else []
    # --rev-range is passed to `git log`: refuse options that write files or run diff helpers (read-only audit).
    if any(t.startswith(UNSAFE_LOG_OPTS) for t in rev_tokens):
        sys.stderr.write("--rev-range: refused option (only revisions and read-only log filters)\n")
        return 2

    top = subprocess.run([GIT, "-C", a.repo, "rev-parse", "--show-toplevel"], capture_output=True)
    if top.returncode != 0:
        sys.stderr.write("not a git repository\n")
        return 2
    root = top.stdout.decode().strip()
    do_tree = a.tree or not a.history
    do_hist = a.history or not a.tree

    t0 = time.time()
    if a.budget_seconds <= 0:
        STATE["deadline"] = True
    threading.Thread(target=watchdog, args=(t0 + a.budget_seconds,), daemon=True).start()

    cov = Counter()
    cov["oversize_paths"] = []
    store = Findings()
    head = git_out(["-C", root, "rev-parse", "HEAD"]).decode().strip()[:12]
    shallow = git_out(["-C", root, "rev-parse", "--is-shallow-repository"]).decode().strip() == "true"
    total = git_out(["-C", root, "rev-list", "--all", "--count"]).decode().strip()  # before the scan: refs may move
    if do_tree:
        scan_tree(root, store, cov, a.include_noise)
    if do_hist and not STATE["deadline"]:
        rev = rev_tokens or None
        scan_history(root, store, cov, a.include_noise, rev)
    refs = len(git_out(["-C", root, "for-each-ref"]).splitlines()) if not STATE["deadline"] else -1
    STATE["done"].set()

    reasons = []
    failed = False
    if STATE["deadline"]:
        status = "PARTIAL (deadline)"
    else:
        if cov["unscanned_oversize"]:
            reasons.append("unscanned_oversize=%d" % cov["unscanned_oversize"])
        if cov["blob_cap_hit"]:
            reasons.append("blob cap %d hit" % BLOB_CAP)
        if STATE["rule_errors"]:
            reasons.append("rule_error=%d" % sum(STATE["rule_errors"].values()))
        if STATE["git_failures"]:
            reasons.append("git_failures=%d" % STATE["git_failures"])
            failed = True
        if cov["unreadable"]:
            reasons.append("unreadable_files=%d" % cov["unreadable"])
            failed = True
        if do_hist and not a.rev_range:
            if not total.isdigit() or cov["commits_scanned"] != int(total):
                reasons.append("commits_scanned=%d of rev_list_all_count=%s" % (cov["commits_scanned"], total or "?"))
                failed = True
        if shallow:
            reasons.append("SHALLOW clone")
        if a.rev_range:
            reasons.append("rev-range restricted")
        status = "COMPLETE" if not reasons else "INCOMPLETE (%s)" % "; ".join(reasons)

    rows = store.rows(do_tree)
    out = open(a.out, "w") if a.out else sys.stdout
    try:
        if a.format == "json":
            keys = ("scope", "path", "commit", "rule", "severity", "hint", "seen_in", "in_head")
            for r in rows:
                out.write(json.dumps(dict(zip(keys, r))) + "\n")
        else:
            out.write("scope\tpath\tcommit\trule\tseverity\thint\tseen_in\tin_head\n")
            for r in rows:
                out.write("\t".join(str(x) for x in r) + "\n")
        summ = Counter((r[3], path_class(r[1].split("#")[0]), r[0]) for r in rows)
        out.write("# summary\n")
        for (rid, pc, scope), n in sorted(summ.items()):
            out.write("# count\t%s\t%s\t%s\t%d\n" % (rid, pc, scope, n))
        sev = Counter(r[4] for r in rows)
        out.write("# severity\t%s\n" % " ".join("%s=%d" % kv for kv in sorted(sev.items())))
        out.write("# coverage\t%s\n" % status)
        out.write("# coverage\thead=%s tree_files=%d binary_scanned=%d sqlite_audited=%d sqlite_rows=%d "
                  "long_lines_windowed=%d unscanned_oversize=%d\n" % (
                      head, cov["tree_files"], cov["binary_scanned"], cov["sqlite_audited"], cov["sqlite_rows"],
                      cov["long_lines_windowed"], cov["unscanned_oversize"]))
        out.write("# coverage\tcommits_scanned=%d rev_list_all_count=%s patch_sections=%d blobs_audited=%d "
                  "refs=%d shallow=%s\n" % (
                      cov["commits_scanned"], total, cov["patch_sections"], cov["blobs_audited"], refs,
                      str(shallow).lower()))
        sys.stderr.write("elapsed_s=%.1f\n" % (time.time() - t0))
        if STATE["rule_errors"]:
            out.write("# rule_errors\t%s\n" % " ".join("%s=%d" % kv for kv in sorted(STATE["rule_errors"].items())))
        if STATE["deadline"]:
            out.write("PARTIAL: deadline; last commit reached %s\n" % (STATE["last_commit"] or "none"))
    finally:
        if a.out:
            out.close()
    if STATE["deadline"]:
        return 3
    return 4 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
