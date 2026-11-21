#!/usr/bin/env python3
"""Deterministic UAT runner for ONE business process (D-167, spike M0).

Runs a process file (JSON, see scripts/uat/README.md) against a Letflow tenant over HTTP:
no model, standard library only. One JSON line per step goes to <run dir>/run.jsonl, the
values saved by the steps go to <run dir>/context.json and a table to <run dir>/summary.md.

Tokens come ONLY from the caller's environment: for each actor the runner calls
`bash "$TEAM_ROOT/project/scripts/uat_creds.sh" token <user>` and keeps the answer in memory.
The runner never prints a token, never writes one to a file and scrubs every token it has
seen (and anything shaped like a JWT) out of the log before it is written.

Commands: `run` (one process), `chain` (an ordered list of processes sharing one context),
`cleanup` (replay the recorded cleanup list of an aborted run, also `--cleanup <run dir>`) and
`dry-run` (run every changed process file on QA with its own `dry_run` block).

Exit codes: 0 every step, every cleanup step and the build check passed; 1 a verdict failed;
2 bad usage or a bad process file (nothing was run). `dry-run` never uses 2 for a failure: the
bp_dryrun capability reads exit 2 as "this runner has no such command yet".
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import shlex
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path

HTTP_TIMEOUT_S = 30
TOKEN_CMD_TIMEOUT_S = 60
INBOX_PAGES_MAX = 10
RESPONSE_EXCERPT_MAX = 2000
STABLE_EXTRA_S = 120
DO_KINDS = ("api", "wait_task", "assert_only", "repeat", "parallel")
DEFAULT_BASE_URL_TEMPLATE = "https://{tenant}.letflow.qa.bizdala.com"
BUILTIN_NAMES = ("tenant", "TENANT", "run_id", "now_utc", "old_base_url")

SECRET_KEY = re.compile(r"pass(word)?|secret|token|authorization|api[_-]?key|credential", re.I)
JWT_SHAPE = re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*")
PLAIN_DECIMAL = re.compile(r"^-?\d+(\.\d+)?$")
OPERATORS = {"equals", "contains", "regex", "absent", "exists", "default"}


class RunnerError(Exception):
    """A step cannot be executed or its answer is not what the process expects."""


class ConfigError(Exception):
    """The process file or the command line is wrong; nothing was run."""


class Undefined(RunnerError):
    def __init__(self, name):
        super().__init__(f"undefined variable ${{{name}}}")
        self.name = name


# -- substitution and expressions ---------------------------------------------------------------

_TOKEN = re.compile(r"\s*(?:(\d+(?:\.\d+)?)|([A-Za-z_][A-Za-z0-9_]*)|(.))")
_PLACEHOLDER = re.compile(r"\$\{([^}]*)\}")
_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def fmt_decimal(value: Decimal) -> str:
    text = format(value, "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text or "0"


def to_decimal(value, what="value") -> Decimal:
    if isinstance(value, bool):
        raise RunnerError(f"{what} {value!r} is not a number")
    try:
        return Decimal(str(value).strip())
    except InvalidOperation:
        raise RunnerError(f"{what} is not a number") from None


def eval_expression(text: str, ctx: dict) -> str:
    """Tiny number expression: names from ctx, + - * / and parentheses, Decimal arithmetic."""
    tokens = []
    for number, name, other in _TOKEN.findall(text):
        if number:
            tokens.append(("num", number))
        elif name:
            tokens.append(("name", name))
        elif other.strip():
            tokens.append(("op", other))
    pos = 0

    def peek():
        return tokens[pos] if pos < len(tokens) else (None, None)

    def take():
        nonlocal pos
        pos += 1
        return tokens[pos - 1]

    def factor():
        kind, val = peek()
        if kind == "op" and val == "-":
            take()
            return -factor()
        if kind == "op" and val == "(":
            take()
            inner = expr()
            if peek() != ("op", ")"):
                raise RunnerError(f"expression {text!r}: missing )")
            take()
            return inner
        if kind == "num":
            take()
            return Decimal(val)
        if kind == "name":
            take()
            if val not in ctx:
                raise Undefined(val)
            return to_decimal(ctx[val], f"variable {val}")
        raise RunnerError(f"expression {text!r}: unexpected {val!r}")

    def term():
        left = factor()
        while peek() in (("op", "*"), ("op", "/")):
            op = take()[1]
            right = factor()
            if op == "/" and right == 0:
                raise RunnerError(f"expression {text!r}: division by zero")
            left = left * right if op == "*" else left / right
        return left

    def expr():
        left = term()
        while peek() in (("op", "+"), ("op", "-")):
            op = take()[1]
            right = term()
            left = left + right if op == "+" else left - right
        return left

    result = expr()
    if pos != len(tokens):
        raise RunnerError(f"expression {text!r}: unexpected {tokens[pos][1]!r}")
    return fmt_decimal(result)


def substitute(value, ctx: dict):
    """${name} and ${a + 1} in strings, recursively. A string that is exactly one ${name}
    gives the raw value of the variable; anything else gives a string (numbers as plain decimals)."""
    if isinstance(value, str):
        whole = _PLACEHOLDER.fullmatch(value)
        if whole and _NAME.match(whole.group(1).strip()):
            name = whole.group(1).strip()
            if name not in ctx:
                raise Undefined(name)
            return ctx[name]

        def one(match):
            inner = match.group(1).strip()
            if _NAME.match(inner):
                if inner not in ctx:
                    raise Undefined(inner)
                return str(ctx[inner])
            return eval_expression(inner, ctx)

        return _PLACEHOLDER.sub(one, value)
    if isinstance(value, list):
        return [substitute(v, ctx) for v in value]
    if isinstance(value, dict):
        return {k: substitute(v, ctx) for k, v in value.items()}
    return value


def referenced_names(value) -> set:
    """Variable names a (not yet substituted) structure reads: used to skip cleanup steps."""
    names = set()
    if isinstance(value, str):
        for match in _PLACEHOLDER.finditer(value):
            names.update(n for n in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", match.group(1)))
    elif isinstance(value, list):
        for v in value:
            names |= referenced_names(v)
    elif isinstance(value, dict):
        for v in value.values():
            names |= referenced_names(v)
    return names


# -- JSON path and assertions -------------------------------------------------------------------

_PATH_PART = re.compile(r"\.([A-Za-z0-9_\-]+)|\[(\d+)\]|\[\"([^\"]*)\"\]")


def json_path(doc, path: str):
    """`$.a.b[0].c` -> (found, value). `$` is the whole document."""
    if not path.startswith("$"):
        raise RunnerError(f"path {path!r} must start with $")
    rest = path[1:]
    cur = doc
    pos = 0
    while pos < len(rest):
        match = _PATH_PART.match(rest, pos)
        if not match:
            raise RunnerError(f"path {path!r}: cannot read {rest[pos:]!r}")
        pos = match.end()
        key, index, quoted = match.groups()
        if index is not None:
            if not isinstance(cur, list) or int(index) >= len(cur):
                return False, None
            cur = cur[int(index)]
        else:
            key = key if key is not None else quoted
            if not isinstance(cur, dict) or key not in cur:
                return False, None
            cur = cur[key]
    return True, cur


def numbers_equal(actual, expected):
    """Numeric equality when both sides are numbers or plain decimal strings; else None."""

    def num(x):
        if isinstance(x, bool):
            return None
        if isinstance(x, (int, float, Decimal)):
            return Decimal(str(x))
        if isinstance(x, str) and PLAIN_DECIMAL.match(x.strip()):
            return Decimal(x.strip())
        return None

    a, e = num(actual), num(expected)
    if a is None or e is None:
        return None
    return a == e


def values_equal(actual, expected) -> bool:
    numeric = numbers_equal(actual, expected)
    return numeric if numeric is not None else actual == expected


def check_matcher(found, actual, matcher):
    """One matcher against one path result -> (ok, short description of what was expected)."""
    if isinstance(matcher, dict) and matcher.keys() & OPERATORS:
        if "default" in matcher and not found:
            found, actual = True, matcher["default"]
        if "equals" in matcher:
            return found and values_equal(actual, matcher["equals"]), {"equals": matcher["equals"]}
        if "contains" in matcher:
            want = matcher["contains"]
            if isinstance(actual, (str, list, dict)) and found:
                ok = want in actual
            else:
                ok = False
            return ok, {"contains": want}
        if "regex" in matcher:
            ok = found and isinstance(actual, (str, int, float)) and bool(
                re.search(matcher["regex"], str(actual))
            )
            return ok, {"regex": matcher["regex"]}
        if "absent" in matcher:
            absent = (not found) or actual is None
            return (absent if matcher["absent"] else not absent), {"absent": matcher["absent"]}
        if "exists" in matcher:
            return (found if matcher["exists"] else not found), {"exists": matcher["exists"]}
    return found and values_equal(actual, matcher), {"equals": matcher}


def strings_in(doc):
    """Every string value (and key) anywhere in a parsed JSON document."""
    if isinstance(doc, str):
        yield doc
    elif isinstance(doc, dict):
        for k, v in doc.items():
            yield str(k)
            yield from strings_in(v)
    elif isinstance(doc, list):
        for v in doc:
            yield from strings_in(v)


def refused_results(spec: dict, status: int, body, text) -> list:
    """expect_refused: a 4xx (or the given status) and the error code somewhere in the answer."""
    wanted = spec.get("status")
    if wanted is None:
        status_row = {"what": "status", "expected": "4xx", "actual": status, "ok": 400 <= status < 500}
    else:
        wanted_list = wanted if isinstance(wanted, list) else [wanted]
        status_row = {"what": "status", "expected": wanted, "actual": status, "ok": status in wanted_list}
    results = [status_row]
    code = spec.get("code")
    if code:
        haystack = list(strings_in(body)) if body is not None else [text or ""]
        hit = any(str(code) in x for x in haystack)
        said = (body.get("detail") or body.get("title")) if isinstance(body, dict) else None
        results.append({"what": "error code", "expected": code, "actual": code if hit else (said or "<absent>"), "ok": hit})
    return results


def run_assertions(expect: dict, status: int, body, text=None, mask=False) -> list:
    """expect = {status: 200 | [200, 201], json: {"$.a.b": matcher, "key": matcher}} or
    {refused: {status, code}} (the expect_refused sugar). mask: a step that handles a secret
    never shows an actual value."""
    if "refused" in expect:
        return refused_results(expect["refused"], status, body, text)
    results = []
    if "status" not in expect:
        results.append({"what": "status", "expected": "2xx", "actual": status, "ok": 200 <= status < 300})
    else:
        wanted = expect["status"]
        wanted_list = wanted if isinstance(wanted, list) else [wanted]
        results.append({"what": "status", "expected": wanted, "actual": status, "ok": status in wanted_list})
    for raw_path, matcher in (expect.get("json") or {}).items():
        path = raw_path if (raw_path == "$" or raw_path.startswith(("$.", "$["))) else f"$.{raw_path}"
        found, actual = json_path(body, path)
        ok, wanted = check_matcher(found, actual, matcher)
        shown = "***" if (mask or SECRET_KEY.search(path)) else (actual if found else "<absent>")
        results.append({"what": path, "expected": wanted, "actual": shown, "ok": bool(ok)})
    return results


def match_unordered(expects: list, calls: list, mask=False):
    """Each expectation must be met by a different call, in any order (concurrency: one 201, one 409).
    -> (all ok, rows of the first assignment that passes, else of the order given)."""
    from itertools import permutations

    n = len(expects)
    first = None
    for perm in permutations(range(n)):
        rows = []
        for e_idx, c_idx in enumerate(perm):
            status, body, text = calls[c_idx]
            rows.append(run_assertions(expects[e_idx], status, body, text, mask))
        if first is None:
            first = rows
        if all(r["ok"] for group in rows for r in group):
            return True, rows
    return False, first or []


# -- redaction ----------------------------------------------------------------------------------


def redact(value):
    """Mask the value of every key that looks like a secret, recursively."""
    if isinstance(value, dict):
        return {k: ("***" if SECRET_KEY.search(str(k)) else redact(v)) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v) for v in value]
    return value


def excerpt(text, limit=RESPONSE_EXCERPT_MAX) -> str:
    """The start of an answer for the log: a JSON answer is parsed and its secret-looking keys masked."""
    text = text or ""
    try:
        parsed = json.loads(text)
    except ValueError:
        return text[:limit]
    return json.dumps(redact(parsed), ensure_ascii=False)[:limit]


# -- HTTP ---------------------------------------------------------------------------------------


def http_call(method: str, url: str, headers: dict, body, timeout=HTTP_TIMEOUT_S):
    """-> (status, parsed json or None, raw text). Transport errors raise RunnerError."""
    data = None
    hdrs = {"Accept": "application/json", "User-Agent": "uat-runner/0"}
    hdrs.update(headers)
    if body is not None:
        data = json.dumps(body).encode()
        hdrs.setdefault("Content-Type", "application/json")
    request = urllib.request.Request(url, data=data, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as resp:
            status, raw = resp.status, resp.read()
    except urllib.error.HTTPError as err:
        status, raw = err.code, err.read()
    except (urllib.error.URLError, OSError) as err:
        raise RunnerError(f"{method} {url}: transport error: {getattr(err, 'reason', err)}") from None
    text = raw.decode("utf-8", "replace")
    try:
        parsed = json.loads(text) if text.strip() else None
    except ValueError:
        parsed = None
    return status, parsed, text


def health_sha(url: str):
    """The build sha of /health, or None."""
    try:
        status, parsed, text = http_call("GET", url, {}, None, timeout=10)
    except RunnerError:
        return None
    if status != 200:
        return None
    if isinstance(parsed, dict) and isinstance(parsed.get("sha"), str):
        return parsed["sha"]
    match = re.search(r'"sha"\s*:\s*"([0-9a-fA-F]+)"', text)
    return match.group(1) if match else None


# -- the runner ---------------------------------------------------------------------------------


def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha_matches(have, want) -> bool:
    """A short sha from the command line matches the full sha of /health (either may be the prefix)."""
    have, want = (have or "").lower(), (want or "").lower()
    return bool(have and want) and (have.startswith(want) or want.startswith(have))


def origin_of(url: str) -> str:
    parts = urllib.parse.urlsplit(url)
    return f"{parts.scheme}://{parts.netloc}"


class Runner:
    """One run: a list of processes (a chain; one process is a chain of one) sharing one context."""

    def __init__(self, process, *, base_url, tenant, actors, run_dir, inputs=None, health_url=None,
                 poll_interval=None, run_id=None, out=None, build_sha=None, old_base_url=None,
                 keep_going=False, label=None, file_issues=False, repo=None, gh_cmd=None):
        self.processes = list(process) if isinstance(process, (list, tuple)) else [process]
        self.process = self.processes[0]
        self.label = label or "+".join(p["id"] for p in self.processes)
        self.base_url = base_url.rstrip("/")
        self.health_url = health_url or self.base_url + "/health"
        self.old_base_url = old_base_url.rstrip("/") if old_base_url else None
        self.actors = actors
        self.run_dir = Path(run_dir)
        self.poll_interval = poll_interval
        self.build_sha = build_sha
        self.keep_going = keep_going
        self.file_issues = file_issues
        self.repo = repo
        self.gh_cmd = gh_cmd
        self.run_id = run_id or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + secrets.token_hex(3)
        self.out = out or sys.stdout
        self.tokens = {}
        self.secrets = {}  # in memory only: a value a step saved with {"secret": path}
        self.secret_values = set()
        self.instance_docs = {}
        self.records = []
        self.entries = []  # cleanup list: {process, cleanup: [steps], ctx, done}
        self.issues = {}
        self.replay = False
        self.started_mono = time.monotonic()
        ctx = dict(inputs or {})
        ctx.update({"tenant": tenant, "TENANT": tenant, "run_id": self.run_id, "now_utc": now_utc()})
        if self.old_base_url:
            ctx["old_base_url"] = self.old_base_url
        self.ctx = ctx
        self.tenant = tenant

    # -- log ----------------------------------------------------------------------------------

    def scrub(self, text: str) -> str:
        for secret in self.secret_values:
            text = text.replace(secret, "***")
        return JWT_SHAPE.sub("***", text)

    def write_line(self, record: dict):
        record.setdefault("run_id", self.run_id)
        record.setdefault("process", self.process["id"])
        line = self.scrub(json.dumps(record, ensure_ascii=False, sort_keys=False))
        with open(self.run_dir / "run.jsonl", "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
        self.records.append(json.loads(line))
        step = record.get("step") or "-"
        tail = f" - {record['error']}" if record.get("error") else ""
        print(self.scrub(f"{record.get('phase', ''):9} {step:12} {record['verdict']:7} {record.get('ms', 0)} ms{tail}"),
              file=self.out, flush=True)

    def _atomic_write(self, name, text):
        path = self.run_dir / name
        tmp = path.with_suffix(".tmp")
        tmp.write_text(self.scrub(text), encoding="utf-8")
        os.replace(tmp, path)

    def save_context(self):
        if not self.replay:  # a cleanup replay must not overwrite the context of the run it cleans up
            self._atomic_write("context.json", json.dumps(self.ctx, indent=2, ensure_ascii=False, default=str))
        if self.entries:
            self._atomic_write("cleanup.json", json.dumps(self.entries, indent=2, ensure_ascii=False, default=str))

    def save_meta(self, started_at):
        meta = {"run_id": self.run_id, "label": self.label, "tenant": self.tenant, "base_url": self.base_url,
                "health_url": self.health_url, "old_base_url": self.old_base_url, "actors": self.actors,
                "started": started_at, "processes": [p["id"] for p in self.processes]}
        self._atomic_write("meta.json", json.dumps(meta, indent=2, ensure_ascii=False))

    # -- tokens -------------------------------------------------------------------------------

    def token_for(self, role: str) -> str:
        if role in self.tokens:
            return self.tokens[role]
        user = self.actors.get(role)
        if not user:
            raise RunnerError(f"no user for actor {role!r} (--actors)")
        root = os.environ.get("TEAM_ROOT")
        if not root:
            raise RunnerError("TEAM_ROOT is not set: cannot find project/scripts/uat_creds.sh")
        script = os.path.join(root, "project", "scripts", "uat_creds.sh")
        try:
            done = subprocess.run(["bash", script, "token", user], capture_output=True, text=True,
                                  timeout=TOKEN_CMD_TIMEOUT_S, env=os.environ.copy(), stdin=subprocess.DEVNULL)
        except (OSError, subprocess.TimeoutExpired) as err:
            raise RunnerError(f"token command for actor {role!r} failed to run: {type(err).__name__}") from None
        match = re.search(r"^Token:\s*(\S+)\s*$", done.stdout or "", re.M)
        if done.returncode != 0 or not match:
            first = (done.stderr or "").strip().splitlines()[:1]
            raise RunnerError(f"no token for actor {role!r} (exit {done.returncode}) {first[0] if first else ''}".strip())
        self.tokens[role] = match.group(1)
        self.secret_values.add(match.group(1))
        return match.group(1)

    def request(self, role, method, path, body=None, headers=None, http_as=None):
        hdrs = dict(headers or {})
        if http_as:
            value = self.secrets.get(http_as)
            if not value:
                raise RunnerError(f"http_as {http_as}: no {http_as} value yet (an earlier step must save it with "
                                  f'{{"secret": "$.value"}})')
            if not self.old_base_url:
                raise RunnerError(f"http_as {http_as}: --old-base-url is not set")
            hdrs["Authorization"] = "Bearer " + value
            return http_call(method, self.old_base_url + path, hdrs, body)
        hdrs["Authorization"] = "Bearer " + self.token_for(role)
        return http_call(method, self.base_url + path, hdrs, body)

    def needed_roles(self, processes=None) -> list:
        roles = set()
        for process in processes or self.processes:
            for step in (process.get("steps") or []) + (process.get("cleanup") or []):
                do = step["do"]
                calls = do["parallel"] if "parallel" in do else [do]
                if not step.get("http_as") and step.get("actor"):
                    roles.add(step["actor"])
                for call in calls:
                    if call.get("actor") and not call.get("http_as"):
                        roles.add(call["actor"])
        return sorted(roles)

    # -- preflight ----------------------------------------------------------------------------

    def _pre_line(self, step, verdict, started, **extra):
        record = {"ts": now_utc(), "phase": "preflight", "step": step, "actor": "-", "verdict": verdict,
                  "ms": int((time.monotonic() - started) * 1000), "process": self.label}
        record.update(extra)
        self.write_line(record)
        return verdict != "error" and verdict != "fail"

    def preflight(self, check_stable=True):
        """-> (ok, sha at start). The run starts only when this passes: a sha, the expected build, a stable
        build, a reachable tenant and a token for every actor."""
        started = time.monotonic()
        sha = health_sha(self.health_url)
        if not sha:
            self._pre_line("health", "error", started, method="GET", path="/health", sha=None,
                           error="/health gave no build sha: the run did not start")
            return False, None
        self._pre_line("health", "pass", started, method="GET", path="/health", sha=sha)
        if self.build_sha and not sha_matches(sha, self.build_sha):
            self._pre_line("build_sha", "fail", time.monotonic(), sha=sha,
                           error=f"build is {sha}, expected {self.build_sha}: the run did not start")
            return False, sha
        stable = self._stable_check(sha) if check_stable else True
        if not stable:
            return False, sha
        started = time.monotonic()
        try:
            status, _, _ = http_call("GET", self.base_url + "/", {}, None, timeout=15)
            reachable, why = status < 500, f"answered {status}"
        except RunnerError as err:
            reachable, why = False, str(err)
        if not reachable:
            self._pre_line("tenant", "error", started, error=f"tenant {self.tenant} not reachable at {self.base_url}: {why}")
            return False, sha
        self._pre_line("tenant", "pass", started, method="GET", path="/", status=status)
        return self._tokens(), sha

    def _stable_check(self, sha):
        root = os.environ.get("TEAM_ROOT")
        script = os.path.join(root, "project", "scripts", "qa_stable.sh") if root else None
        if not script or not os.path.isfile(script):
            return True
        started = time.monotonic()
        env = os.environ.copy()
        env["QA_URL"] = origin_of(self.health_url)
        limit = int(env.get("UAT_STABLE_MAX_MIN", "12")) * 60 + STABLE_EXTRA_S
        try:
            done = subprocess.run(["bash", script, "--wait"], capture_output=True, text=True, timeout=limit, env=env,
                                  stdin=subprocess.DEVNULL)
        except (OSError, subprocess.TimeoutExpired) as err:
            return self._pre_line("stable", "error", started, error=f"qa_stable.sh did not finish: {type(err).__name__}")
        said = (done.stdout or "").strip().splitlines()[-1:] or [""]
        match = re.search(r"sha=([0-9a-fA-F]+)", said[0])
        if done.returncode != 0 or "stable" not in said[0] or "unstable" in said[0]:
            return self._pre_line("stable", "fail", started, error=f"the build is not stable: {said[0] or 'no answer'}")
        if match and not sha_matches(match.group(1), sha):
            return self._pre_line("stable", "fail", started,
                                  error=f"the build changed while waiting for it to be stable: {sha} -> {match.group(1)}")
        return self._pre_line("stable", "pass", started, sha=sha)

    def _tokens(self):
        ok = True
        for role in self.needed_roles():
            started = time.monotonic()
            try:
                self.token_for(role)
            except RunnerError as err:
                ok = self._pre_line(f"token:{role}", "error", started, actor=role, error=str(err)) and ok
                continue
            self._pre_line(f"token:{role}", "pass", started, actor=role)
        return ok

    # -- steps --------------------------------------------------------------------------------

    def run_step(self, step: dict, phase: str) -> bool:
        record = {"ts": now_utc(), "run_id": self.run_id, "process": self.process["id"], "phase": phase,
                  "step": step["id"], "actor": step.get("actor") or "-"}
        started = time.monotonic()
        response = None
        secret_step = self._handles_secret(step)
        try:
            missing = [n for n in step.get("requires", []) if n not in self.ctx]
            if missing:
                record.update(verdict="skipped", error="requires " + ", ".join(missing))
                return self._finish(record, started, True)
            do = step["do"]
            calls = self._execute(step, do, record)
            status, body, response = calls[0]
            results = self._assert_calls(step, do, calls, secret_step)
            record["status"] = status
            record["asserted"] = results
            failed = [r for r in results if not r["ok"]]
            if failed:
                first = failed[0]
                what = first["what"]
                label = f"expected {first['expected']} got {first['actual']}" if what == "status" else \
                    f"expected {what} {first['expected']} got {first['actual']}"
                record.update(verdict="fail", error=label)
                which = re.match(r"call (\d+):", first["what"])
                shown = calls[int(which.group(1)) - 1] if which and int(which.group(1)) <= len(calls) else calls[0]
                record["response_excerpt"] = self._excerpt(shown[2], secret_step, shown[0])
                return self._finish(record, started, False)
            self._save(step, body if len(calls) == 1 or "repeat" in do else [c[1] for c in calls], record)
            record["verdict"] = "pass"
            return self._finish(record, started, True)
        except RunnerError as err:
            record.update(verdict="error", error=str(err))
            if response:
                record["response_excerpt"] = self._excerpt(response, secret_step, 0)
            return self._finish(record, started, False)
        except Exception as err:  # a bug in a process file must not skip the cleanup
            record.update(verdict="error", error=f"{type(err).__name__}: {err}")
            return self._finish(record, started, False)

    @staticmethod
    def _handles_secret(step) -> bool:
        if step.get("http_as"):
            return True
        return any(isinstance(spec, dict) and "secret" in spec for spec in (step.get("save") or {}).values())

    @staticmethod
    def _excerpt(text, secret_step, status):
        if secret_step and 200 <= status < 300:
            return "<withheld: the answer carries a secret>"
        return excerpt(text)

    def _finish(self, record, started, ok):
        record["ms"] = int((time.monotonic() - started) * 1000)
        self.write_line(record)
        self.save_context()
        return ok

    # -- one step, by kind --------------------------------------------------------------------

    def _execute(self, step, do, record):
        """-> a list of (status, parsed, text), one per HTTP call (one for api, wait_task, assert_only)."""
        http_as = step.get("http_as")
        role = step.get("actor")
        if "wait_task" in do:
            return [self._wait_task(step, do, record)]
        if "parallel" in do:
            return self._parallel(role, do["parallel"], http_as, record)
        if "repeat" in do:
            times = int(substitute(do.get("times", 2), self.ctx))
            return self._repeat(role, do["repeat"], times, http_as, record)
        spec = do["assert_only"] if "assert_only" in do else do
        if "assert_only" in do:
            spec = dict(spec, api="GET")
        info = self._call(role, spec, http_as)
        record.update(method=info["method"], path=info["path"])
        if info["request"] is not None:
            record["request"] = info["request"]
        return [info["result"]]

    def _call(self, role, spec, http_as=None):
        """One HTTP call of a step (thread safe): the substituted request and the answer."""
        method = str(spec["api"]).upper()
        path = substitute(spec["path"], self.ctx)
        body = redacted = None
        if "body" in spec:
            body = substitute(spec["body"], self.ctx)
            redacted = redact(body)
        headers = substitute(spec.get("headers") or {}, self.ctx)
        who = spec.get("actor", role)
        result = self.request(who, method, path, body, headers, http_as=spec.get("http_as", http_as))
        return {"method": method, "path": path, "request": redacted, "result": result}

    def _repeat(self, role, spec, times, http_as, record):
        """The same call `times` times with the same body, one after the other (retry, idempotency)."""
        if times < 2:
            raise RunnerError("repeat: times must be at least 2")
        infos = [self._call(role, spec, http_as) for _ in range(times)]
        record.update(method=infos[0]["method"], path=infos[0]["path"], calls=[
            {"status": i["result"][0]} for i in infos])
        if infos[0]["request"] is not None:
            record["request"] = infos[0]["request"]
        return [i["result"] for i in infos]

    def _parallel(self, role, specs, http_as, record):
        """The calls at the same moment (a barrier releases them together): concurrency."""
        barrier = threading.Barrier(len(specs))
        for spec in specs:  # tokens are fetched here, not inside a thread
            if not spec.get("http_as", http_as):
                self.token_for(spec.get("actor", role))

        def fire(spec):
            method = str(spec["api"]).upper()
            path = substitute(spec["path"], self.ctx)
            body = substitute(spec["body"], self.ctx) if "body" in spec else None
            headers = substitute(spec.get("headers") or {}, self.ctx)
            who = spec.get("actor", role)
            as_ = spec.get("http_as", http_as)
            try:
                barrier.wait(timeout=10)
            except threading.BrokenBarrierError:
                pass
            return {"method": method, "path": path, "request": redact(body) if body is not None else None,
                    "result": self.request(who, method, path, body, headers, http_as=as_)}

        with ThreadPoolExecutor(max_workers=len(specs)) as pool:
            futures = [pool.submit(fire, spec) for spec in specs]
            infos = []
            for fut in futures:
                try:
                    infos.append(fut.result())
                except RunnerError:
                    barrier.abort()
                    raise
        record.update(method="PARALLEL", path=" | ".join(f"{i['method']} {i['path']}" for i in infos),
                      calls=[{"method": i["method"], "path": i["path"], "status": i["result"][0],
                              **({"request": i["request"]} if i["request"] is not None else {})} for i in infos])
        return [i["result"] for i in infos]

    def _assert_calls(self, step, do, calls, mask):
        """The rows of every assertion of the step: one expectation per call, in order (or unordered)."""
        if "expect_refused" in step:
            refused = substitute(step["expect_refused"], self.ctx)
            spec = {"code": refused} if not isinstance(refused, dict) else refused
            expects = [{"refused": spec}] * len(calls)
        else:
            expect = substitute(step.get("expect") or {}, self.ctx)
            if isinstance(expect, dict) and "unordered" in expect:
                wanted = expect["unordered"]
                if len(wanted) != len(calls):
                    raise RunnerError(f"expect.unordered has {len(wanted)} entries for {len(calls)} calls")
                ok, groups = match_unordered(wanted, calls, mask)
                return [dict(r, what=f"expectation {i + 1}: {r['what']}") for i, g in enumerate(groups) for r in g]
            if isinstance(expect, list):
                if len(expect) != len(calls):
                    raise RunnerError(f"expect has {len(expect)} entries for {len(calls)} calls")
                expects = expect
            elif "repeat" in do:
                later = substitute(step["expect_repeat"], self.ctx) if "expect_repeat" in step else expect
                expects = [expect] + [later] * (len(calls) - 1)
            else:
                expects = [expect] * len(calls)
        rows = []
        for i, (e, (status, body, text)) in enumerate(zip(expects, calls)):
            for r in run_assertions(e, status, body, text, mask):
                rows.append(dict(r, what=f"call {i + 1}: {r['what']}") if len(calls) > 1 else r)
        return rows

    def _wait_task(self, step, do, record):
        spec = substitute(do["wait_task"], self.ctx)
        role, doc, node = step["actor"], spec["for_document"], spec["step"]
        within = float(spec.get("within_s", 30))
        interval = self.poll_interval if self.poll_interval is not None else float(spec.get("interval_s", 2))
        deadline = time.monotonic() + within
        polls, last_problem = 0, None
        while True:
            polls += 1
            task_id, last_problem = self._find_task(role, doc, node)
            if task_id:
                break
            if time.monotonic() >= deadline:
                detail = f" ({last_problem})" if last_problem else ""
                raise RunnerError(f"timeout: no pending {node} task for document {doc} in {within:g} s, {polls} polls{detail}")
            time.sleep(interval)
        record.update(task_id=task_id, polls=polls, method="POST")
        if do.get("claim"):
            status, _, _ = self.request(role, "POST", f"/api/v1/tasks/{task_id}/claim", {})
            if status >= 300:
                record.update(path=f"/api/v1/tasks/{task_id}/claim")
                raise RunnerError(f"claim of task {task_id} answered {status}")
        complete = do.get("complete")
        body = substitute((complete or {}).get("body", {}), self.ctx)
        record["path"] = f"/api/v1/tasks/{task_id}/complete"
        record["request"] = redact(body)
        return self.request(role, "POST", f"/api/v1/tasks/{task_id}/complete", body)

    def _find_task(self, role, doc, node):
        """The id of a PENDING task `node` whose instance carries variables.document_id == doc."""
        cursor, problem = None, None
        for _ in range(INBOX_PAGES_MAX):
            path = "/api/v1/tasks/inbox?page_size=200" + (f"&cursor={cursor}" if cursor else "")
            status, page, _ = self.request(role, "GET", path)
            if status != 200 or not isinstance(page, dict):
                return None, f"inbox answered {status}"
            for item in page.get("items") or []:
                if str(item.get("status", "")).upper() != "PENDING" or item.get("node_id") != node:
                    continue
                inst = item.get("instance_id")
                if inst not in self.instance_docs:
                    st, body, _ = self.request(role, "GET", f"/api/v1/instances/{inst}")
                    if st != 200 or not isinstance(body, dict):
                        problem = f"instance read answered {st}"
                        continue
                    self.instance_docs[inst] = (body.get("variables") or {}).get("document_id")
                if self.instance_docs[inst] == doc:
                    return item.get("id"), None
            cursor = page.get("next_cursor")
            if not cursor:
                break
        return None, problem

    def _save(self, step, body, record):
        for name, spec in (step.get("save") or {}).items():
            if isinstance(spec, dict) and spec.get("if_unset") and name in self.ctx:
                continue
            if isinstance(spec, dict) and "secret" in spec:
                found, value = json_path(body, spec["secret"])
                if not found or not isinstance(value, str) or not value:
                    raise RunnerError(f"save {name}: {spec['secret']} not found in the answer")
                self.secrets[name] = value  # never into the context, never into a file
                self.secret_values.add(value)
                continue
            if isinstance(spec, str) and (spec == "$" or spec.startswith(("$.", "$["))):
                found, value = json_path(body, spec)
                if not found:
                    raise RunnerError(f"save {name}: {spec} not found in the answer")
            elif isinstance(spec, dict) and "api" in spec:
                value = self._save_from_read(step["actor"], spec, name, record)
            elif isinstance(spec, dict) and "pick" in spec:
                value = self._pick(body, spec, name)
            else:
                value = substitute(spec, self.ctx)
            self.ctx[name] = value

    def _pick(self, body, spec, name):
        found, value = json_path(body, spec["pick"])
        if found and value is not None:
            return value
        if "default" in spec:
            return substitute(spec["default"], self.ctx)
        raise RunnerError(f"save {name}: {spec['pick']} not found in the answer")

    def _save_from_read(self, role, spec, name, record):
        path = substitute(spec["path"], self.ctx)
        status, parsed, _ = self.request(role, str(spec["api"]).upper(), path)
        record.setdefault("extra_requests", []).append({"method": str(spec["api"]).upper(), "path": path, "status": status})
        if status >= 300:
            raise RunnerError(f"save {name}: {path} answered {status}")
        return self._pick(parsed, spec, name)

    # -- processes, cleanup -------------------------------------------------------------------

    def run_process(self, process) -> bool:
        """The steps of one process (then its outputs). Its cleanup is recorded now and runs at the end."""
        self.process = process
        entry = {"process": process["id"], "cleanup": process.get("cleanup") or [], "ctx": self.ctx, "done": False}
        self.entries.append(entry)
        for name, value in (process.get("defaults") or {}).items():
            self.ctx.setdefault(name, value)
        self.save_context()
        missing = [n for n in process.get("inputs") or [] if n not in self.ctx]
        steps_ok = True
        if missing:
            steps_ok = False
            self.write_line({"phase": "inputs", "step": "inputs", "actor": "-", "verdict": "error", "ms": 0,
                             "error": "inputs missing: " + ", ".join(missing)})
        for step in process["steps"] if steps_ok else []:
            if steps_ok:
                steps_ok = self.run_step(step, "step")
            else:
                self.write_line({"phase": "step", "step": step["id"], "actor": step.get("actor") or "-",
                                 "verdict": "skipped", "error": "an earlier step failed", "ms": 0})
        if steps_ok:
            try:
                for name, expr in (process.get("outputs") or {}).items():
                    self.ctx[name] = substitute(expr, self.ctx)
            except RunnerError as err:
                steps_ok = False
                self.write_line({"phase": "outputs", "step": "outputs", "actor": "-", "verdict": "error",
                                 "error": str(err), "ms": 0})
        entry["ctx"] = dict(self.ctx)  # frozen: this process's cleanup sees the context as it left it
        self.save_context()
        return steps_ok

    def cleanup_all(self) -> bool:
        """Every recorded cleanup, newest process first. A failing step does not stop the next one."""
        ok = True
        for entry in reversed(self.entries):
            if not entry["done"]:
                ok = self._cleanup_entry(entry) and ok
        return ok

    def _cleanup_entry(self, entry) -> bool:
        live, snapshot = self.ctx, entry["ctx"]
        work = dict(snapshot)
        self.ctx, self.process = work, {"id": entry["process"]}
        ok = True
        try:
            for step in entry["cleanup"]:
                ok = self.run_step(step, "cleanup") and ok
        finally:
            for key, value in work.items():
                if key not in snapshot or snapshot[key] != value:
                    live[key] = value
            self.ctx = live
        entry["done"] = ok
        self.save_context()
        return ok

    # -- the run ------------------------------------------------------------------------------

    def run(self, check_stable=True) -> int:
        self.run_dir.mkdir(parents=True, exist_ok=True)
        started_at = now_utc()
        self.save_context()
        self.save_meta(started_at)
        pre_ok, sha_start = self.preflight(check_stable)
        if not pre_ok:
            self._summary(started_at, sha_start, None, False, True, False)
            print(f"{self.label}: FAIL (preflight; run dir {self.run_dir})", file=self.out, flush=True)
            return 1
        results = {}
        stopped = False
        try:
            for process in self.processes:
                if stopped:
                    self.process = process
                    self.write_line({"phase": "step", "step": "-", "actor": "-", "verdict": "skipped", "ms": 0,
                                     "error": "an earlier process failed"})
                    results[process["id"]] = None
                    continue
                results[process["id"]] = self.run_process(process)
                stopped = not results[process["id"]] and not self.keep_going
        finally:
            cleanup_ok = self.cleanup_all()
        self.process = {"id": self.label}
        sha_end = health_sha(self.health_url)
        build_moved = sha_end != sha_start
        if build_moved:
            self.write_line({"phase": "preflight", "step": "build", "actor": "-", "verdict": "fail", "sha": sha_end,
                             "ms": 0, "error": f"build moved: {sha_start} -> {sha_end}"})
        steps_ok = all(v is True for v in results.values())
        if self.file_issues:
            self._file_issues()
        self.save_context()
        ok = steps_ok and cleanup_ok and not build_moved
        self._summary(started_at, sha_start, sha_end, steps_ok, cleanup_ok, build_moved)
        print(f"{self.label}: {'PASS' if ok else 'FAIL'} (run dir {self.run_dir})", file=self.out, flush=True)
        return 0 if ok else 1

    def replay_cleanup(self) -> int:
        """Run the cleanup list of an aborted run again (cleanup.json of the run directory)."""
        try:
            entries = json.loads((self.run_dir / "cleanup.json").read_text(encoding="utf-8"))
        except (OSError, ValueError) as err:
            print(f"runner.py: cannot read {self.run_dir}/cleanup.json: {err}", file=sys.stderr)
            return 2
        self.entries = [e for e in entries if isinstance(e, dict) and "cleanup" in e]
        self.replay = True
        started_at = now_utc()
        self.label = f"cleanup of {self.run_dir.name}"
        self.process = {"id": "cleanup"}
        self.processes = [{"id": e["process"], "steps": [], "cleanup": e["cleanup"]} for e in self.entries]
        started = time.monotonic()
        sha = health_sha(self.health_url)
        if not sha:
            self._pre_line("health", "error", started, error="/health gave no build sha: nothing was cleaned up")
            return 1
        self._pre_line("health", "pass", started, sha=sha)
        if not self._tokens():
            return 1
        ok = self.cleanup_all()
        left = [e["process"] for e in self.entries if not e["done"]]
        self._summary(started_at, sha, sha, True, ok, False, name="summary-cleanup.md")
        print(f"cleanup of {self.run_dir}: {'PASS' if ok else 'FAIL'}" + (f" (not done: {', '.join(left)})" if left else ""),
              file=self.out, flush=True)
        return 0 if ok else 1

    # -- issues -------------------------------------------------------------------------------

    def failing_lines(self):
        """process id -> its first failing record (a step, a cleanup step, missing inputs, outputs)."""
        first = {}
        for r in self.records:
            if r.get("phase") in ("step", "cleanup", "inputs", "outputs") and r.get("verdict") in ("fail", "error"):
                first.setdefault(r["process"], r)
        return first

    def issue_title(self, record) -> str:
        asserted = [a for a in record.get("asserted") or [] if not a["ok"]]
        if asserted:
            a = asserted[0]
            what = "" if a["what"] == "status" else a["what"] + " "
            tail = f"expected {what}{a['expected']} got {a['actual']}"
        else:
            tail = str(record.get("error") or record.get("verdict"))
        return self.scrub(f"UAT {record['process']} {record['step']}: {tail}")[:200]

    def issue_body(self, record) -> str:
        pid = record["process"]
        lines = [r for r in self.records if r.get("process") == pid and r.get("phase") in ("step", "cleanup", "inputs", "outputs")]
        rows = ["| phase | step | actor | request | status | verdict | ms | note |", "|---|---|---|---|---|---|---|---|"]
        for r in lines:
            rows.append(f"| {r.get('phase', '')} | {r.get('step', '')} | {r.get('actor', '')} | "
                        f"{(r.get('method', '') + ' ' + r.get('path', '')).strip()} | {r.get('status', '')} | "
                        f"{r.get('verdict', '')} | {r.get('ms', '')} | {str(r.get('error', '')).replace('|', '/')} |")
        shas = [r.get("sha") for r in self.records if r.get("phase") == "preflight" and r.get("sha")]
        body = [
            f"The UAT runner found a failure in process **{pid}** on tenant `{self.tenant}`.",
            "",
            f"- failing step: `{record['step']}` ({record.get('phase')}, actor `{record.get('actor', '-')}`)",
            f"- verdict: {record['verdict']}: {record.get('error', '')}",
            f"- build sha: {shas[0] if shas else 'unknown'}",
            f"- run id: {self.run_id}",
            f"- run log: `{(self.run_dir / 'run.jsonl').resolve()}` (summary.md and context.json beside it)",
            "",
            "## Steps of this process", "", *rows, "",
            "## Failing request (secrets masked)", "", "```json",
            json.dumps({"method": record.get("method"), "path": record.get("path"), "request": record.get("request"),
                        "calls": record.get("calls")}, indent=2, ensure_ascii=False),
            "```", "",
            "## Failing response (first 2000 characters, secrets masked)", "", "```",
            str(record.get("response_excerpt") or "(no answer was read)"), "```", "",
            "Filed by the UAT runner (`scripts/uat/runner.py --file-issues`).",
        ]
        return self.scrub("\n".join(body))

    def _file_issues(self):
        """One issue per failed process, once per run (issues.json remembers what was filed)."""
        ledger = self.run_dir / "issues.json"
        try:
            self.issues = json.loads(ledger.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self.issues = {}
        gh = shlex.split(self.gh_cmd or os.environ.get("UAT_GH") or "gh")
        for pid, record in self.failing_lines().items():
            if pid in self.issues:
                continue
            cmd = gh + ["issue", "create", "--title", self.issue_title(record), "--label", "uat-regression",
                        "--body-file", "-"]
            repo = self.repo or os.environ.get("UAT_ISSUE_REPO")
            if repo:
                cmd += ["--repo", repo]
            try:
                done = subprocess.run(cmd, input=self.issue_body(record), capture_output=True, text=True, timeout=120)
            except (OSError, subprocess.TimeoutExpired) as err:
                self.issues[pid] = f"NOT FILED: {type(err).__name__}"
                continue
            out = (done.stdout or "").strip().splitlines()
            self.issues[pid] = out[-1] if done.returncode == 0 and out else f"NOT FILED (gh exit {done.returncode})"
            print(self.scrub(f"issue     {pid:12} {self.issues[pid]}"), file=self.out, flush=True)
        self._atomic_write("issues.json", json.dumps(self.issues, indent=2))

    # -- summary ------------------------------------------------------------------------------

    def _summary(self, started_at, sha_start, sha_end, steps_ok, cleanup_ok, build_moved, name="summary.md"):
        ok = steps_ok and cleanup_ok and not build_moved and sha_start is not None
        first = next((r for r in self.records if r.get("verdict") in ("fail", "error")), None)
        lines = [
            f"# UAT run {self.label}",
            "",
            f"- run id: {self.run_id}",
            f"- tenant: {self.tenant}   base url: {self.base_url}",
            f"- started: {started_at}   duration: {int((time.monotonic() - self.started_mono) * 1000)} ms",
            f"- build sha at start: {sha_start}   at end: {sha_end}" + ("   **build moved: the run fails**" if build_moved else ""),
            f"- steps: {'pass' if steps_ok else 'FAIL'}   cleanup: {'pass' if cleanup_ok else 'FAIL'}",
            f"- verdict: **{'PASS' if ok else 'FAIL'}**",
        ]
        if first:
            what = f"{first.get('process', '')} {first.get('phase', '')} {first.get('step', '')}".strip()
            lines += ["", f"> **FIRST FAILING STEP: {what}** - {first.get('error', first.get('verdict'))}"]
        lines += ["", "## Processes", "", "| process | verdict | steps | cleanup | duration ms | first failing step |",
                  "|---|---|---|---|---|---|"]
        for pid in dict.fromkeys(r["process"] for r in self.records if r.get("phase") in ("step", "cleanup", "inputs", "outputs")):
            mine = [r for r in self.records if r.get("process") == pid and r.get("phase") in ("step", "cleanup", "inputs", "outputs")]
            bad = [r for r in mine if r.get("verdict") in ("fail", "error")]
            bad_steps = [r for r in bad if r["phase"] != "cleanup"]
            bad_clean = [r for r in bad if r["phase"] == "cleanup"]
            skipped = bool(mine) and all(r.get("verdict") == "skipped" for r in mine)
            verdict = "SKIPPED" if skipped else ("FAIL" if bad else "pass")
            lines.append(f"| {pid} | {verdict} | {'FAIL' if bad_steps else ('skipped' if skipped else 'pass')} | "
                         f"{'FAIL' if bad_clean else 'pass'} | {sum(int(r.get('ms') or 0) for r in mine)} | "
                         f"{(bad[0]['step'] + ': ' + str(bad[0].get('error', ''))).replace('|', '/') if bad else ''} |")
        lines += ["", "## Steps", "", "| phase | process | step | actor | request | status | verdict | ms | note |",
                  "|---|---|---|---|---|---|---|---|---|"]
        for r in self.records:
            req = f"{r.get('method', '')} {r.get('path', '')}".strip()
            mark = "**FAIL**" if r.get("verdict") in ("fail", "error") else r.get("verdict", "")
            row = (f"| {r.get('phase', '')} | {r.get('process', '')} | {r.get('step', '')} | {r.get('actor', '')} | {req} | "
                   f"{r.get('status', '')} | {mark} | {r.get('ms', '')} | {str(r.get('error', '')).replace('|', '/')} |")
            lines.append(("**>>** " + row) if r is first else row)
        outputs = {}
        for p in self.processes:
            outputs.update({k: self.ctx.get(k) for k in (p.get("outputs") or {}) if k in self.ctx})
        lines += ["", "## Outputs", "", "```json", json.dumps(outputs, indent=2, default=str), "```", ""]
        for key in ("balance_before", "balance_after", "balance_end"):
            if key in self.ctx:
                lines.append(f"- {key}: {self.ctx[key]}")
        if self.issues:
            lines += ["", "## Issues", ""] + [f"- {pid}: {url}" for pid, url in self.issues.items()]
        lines += ["", "## Context at the end", "", "```json", json.dumps(self.ctx, indent=2, default=str, ensure_ascii=False), "```", ""]
        (self.run_dir / name).write_text(self.scrub("\n".join(lines) + "\n"), encoding="utf-8")


# -- loading ------------------------------------------------------------------------------------


def validate_call(spec, where):
    if not isinstance(spec, dict) or "api" not in spec or "path" not in spec:
        raise ConfigError(f"{where}: a call needs api (the method) and path")


def validate_step(step, where) -> None:
    do = step["do"]
    kinds = [k for k in DO_KINDS if k in do]
    if len(kinds) != 1:
        raise ConfigError(f"{where}: do needs exactly one of {', '.join(DO_KINDS)}")
    kind = kinds[0]
    if kind == "api":
        validate_call(do, where)
    elif kind == "wait_task":
        if not isinstance(do["wait_task"], dict) or not {"for_document", "step"} <= set(do["wait_task"]):
            raise ConfigError(f"{where}: wait_task needs for_document and step")
    elif kind == "assert_only":
        spec = do["assert_only"]
        if not isinstance(spec, dict) or "path" not in spec or "body" in spec or str(spec.get("api", "GET")).upper() != "GET":
            raise ConfigError(f"{where}: assert_only is a GET with a path and no body")
        if "expect" not in step and "expect_refused" not in step:
            raise ConfigError(f"{where}: assert_only needs an expect")
    elif kind == "repeat":
        validate_call(do["repeat"], where)
        times = do.get("times", 2)
        if not isinstance(times, (int, str)) or (isinstance(times, int) and times < 2):
            raise ConfigError(f"{where}: repeat needs times of at least 2")
    elif kind == "parallel":
        calls = do["parallel"]
        if not isinstance(calls, list) or len(calls) < 2 or len(calls) > 6:
            raise ConfigError(f"{where}: parallel is a list of 2 to 6 calls")
        for call in calls:
            validate_call(call, where)
    if "http_as" in step and step["http_as"] != "shared_access":
        raise ConfigError(f"{where}: http_as can only be shared_access")
    if "http_as" not in step and not step.get("actor"):
        raise ConfigError(f"{where}: every step needs id, actor and do")
    if "expect_refused" in step and "expect" in step:
        raise ConfigError(f"{where}: give expect or expect_refused, not both")


def load_process(path) -> dict:
    try:
        process = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as err:
        raise ConfigError(f"cannot read process file {path}: {err}") from None
    if not isinstance(process, dict) or not process.get("id") or not isinstance(process.get("steps"), list) or not process["steps"]:
        raise ConfigError("a process file needs an id and a non-empty steps list")
    seen = set()
    for step in process["steps"] + (process.get("cleanup") or []):
        if not isinstance(step, dict) or not all(k in step for k in ("id", "do")) or not isinstance(step["do"], dict):
            raise ConfigError(f"every step needs id, actor and do: {str(step)[:80]}")
        if step["id"] in seen:
            raise ConfigError(f"duplicate step id {step['id']}")
        seen.add(step["id"])
        validate_step(step, f"step {step['id']}")
    return process


def load_chain(path) -> tuple:
    """-> (chain document, [process documents]). `processes` are names resolved in ../processes (with or
    without .json, or a stem such as BP-01), or paths relative to the chain file."""
    try:
        chain = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as err:
        raise ConfigError(f"cannot read chain file {path}: {err}") from None
    names = chain.get("processes") if isinstance(chain, dict) else None
    if not chain.get("id") or not isinstance(names, list) or not names:
        raise ConfigError("a chain file needs an id and a non-empty processes list")
    here = Path(path).resolve().parent
    processes = []
    for name in names:
        found = resolve_process_file(here, str(name))
        processes.append(load_process(found))
    ids = [p["id"] for p in processes]
    if len(set(ids)) != len(ids):
        raise ConfigError("a process appears twice in the chain: " + ", ".join(sorted({i for i in ids if ids.count(i) > 1})))
    return chain, processes


def resolve_process_file(chain_dir: Path, name: str) -> Path:
    candidates = [chain_dir / name, chain_dir.parent / "processes" / name, chain_dir.parent / "processes" / (name + ".json")]
    candidates += sorted((chain_dir.parent / "processes").glob(name + "-*.json"))
    for c in candidates:
        if c.is_file():
            return c
    raise ConfigError(f"chain: no process file for {name!r} (looked in {chain_dir.parent / 'processes'})")


def check_chain_inputs(processes, provided: set) -> None:
    """Every process finds its inputs in what the caller gave, its defaults, or the outputs of an earlier process."""
    available = set(provided) | set(BUILTIN_NAMES)
    for p in processes:
        missing = set(p.get("inputs") or []) - available - set(p.get("defaults") or {})
        if missing:
            raise ConfigError(f"{p['id']}: inputs missing: " + ", ".join(sorted(missing)))
        available |= set(p.get("outputs") or {}) | set(p.get("defaults") or {})


def parse_pairs(items, what) -> dict:
    out = {}
    for item in items:
        name, sep, value = item.partition("=")
        if not sep or not name:
            raise ConfigError(f"{what}: expected name=value, got {item!r}")
        out[name] = value
    return out


# -- dry run ------------------------------------------------------------------------------------

PROCESS_GLOBS = ("test/uat/processes/*.json", "test/uat/chains/*.json")


def changed_files(repo: Path) -> list:
    """Process and chain files that differ from origin/main (committed, edited or new)."""

    def git(*args):
        done = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, timeout=60)
        if done.returncode != 0:
            raise ConfigError("git " + " ".join(args[:2]) + " failed: " + (done.stderr or "").strip()[:200])
        return done.stdout

    base = git("merge-base", "HEAD", "origin/main").strip()
    names = set(git("diff", "--name-only", "--diff-filter=d", base, "--", *PROCESS_GLOBS).split())
    names |= set(git("ls-files", "--others", "--exclude-standard", "--", *PROCESS_GLOBS).split())
    return sorted(repo / n for n in names if (repo / n).is_file())


def base_url_for(tenant: str, template=None) -> str:
    return (template or os.environ.get("UAT_BASE_URL_TEMPLATE") or DEFAULT_BASE_URL_TEMPLATE).format(tenant=tenant)


def cmd_dry_run(args, out=None) -> int:
    """Every changed process file on QA with its own dry_run block {tenant, actors, inputs}, self-cleaning.
    Exit 0 only when all pass; a failure is exit 1 (exit 2 is reserved for 'no such command')."""
    out = out or sys.stdout
    repo = Path(args.repo or Path(__file__).resolve().parents[2])
    try:
        files = [Path(f) for f in args.files] if args.files else changed_files(repo)
    except ConfigError as err:
        print(f"dry-run: {err}", file=out)
        return 1
    if not files:
        print("dry-run: no process or chain file changed: nothing to run", file=out)
        return 0
    import check_processes

    problems = check_processes.check_files(files, root=repo, strict=True)
    if problems:
        print("dry-run: the static check fails, nothing was run:", file=out)
        for p in problems:
            print("  " + p, file=out)
        return 1
    root_dir = Path(args.run_dir_root or os.path.join("uat-runs", "dry-run-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")))
    worst = 0
    for index, path in enumerate(files):
        doc = json.loads(path.read_text(encoding="utf-8"))
        block = doc.get("dry_run") or {}
        tenant = block.get("tenant") or doc.get("tenant")
        actors = block.get("actors") or doc.get("actors") or {}
        inputs = dict(doc.get("inputs") if isinstance(doc.get("inputs"), dict) else {})
        inputs.update(block.get("inputs") or {})
        base = block.get("base_url") or args.base_url or base_url_for(tenant, args.base_url_template)
        try:
            if "processes" in doc:
                chain, processes = load_chain(path)
                label = chain["id"]
            else:
                processes, label = [load_process(path)], doc["id"]
            check_chain_inputs(processes, set(inputs))
        except ConfigError as err:
            print(f"dry-run: {path.name}: {err}", file=out)
            worst = 1
            continue
        print(f"dry-run: {path.name} on {tenant} ({base})", file=out, flush=True)
        runner = Runner(processes, base_url=base, tenant=tenant, actors=actors, run_dir=root_dir / path.stem,
                        inputs=inputs, health_url=args.health_url, poll_interval=args.poll_interval, out=out,
                        build_sha=args.build_sha, old_base_url=block.get("old_base_url") or args.old_base_url,
                        keep_going=False, label=label, file_issues=False)
        code = runner.run(check_stable=(index == 0 and not args.no_stable_check))
        worst = max(worst, 1 if code else 0)
    print("dry-run: " + ("PASS" if worst == 0 else "FAIL") + f" ({len(files)} file(s), runs in {root_dir})", file=out)
    return worst


# -- the CLI ------------------------------------------------------------------------------------


def add_run_options(p):
    p.add_argument("--tenant", help="tenant slug (becomes ${tenant}); a chain file may carry it")
    p.add_argument("--base-url", help="e.g. https://TENANT.letflow.qa.bizdala.com (default: --base-url-template)")
    p.add_argument("--base-url-template", help="URL with {tenant} (default env UAT_BASE_URL_TEMPLATE or " + DEFAULT_BASE_URL_TEMPLATE + ")")
    p.add_argument("--actors", help="actor=keycloak-user,... e.g. admin=qoimeks-qa-admin,storekeeper=qoimeks-qa-store")
    p.add_argument("--input", nargs="+", action="extend", default=[], metavar="NAME=VALUE", help="process inputs")
    p.add_argument("--input-file", help="JSON file with inputs (e.g. the context.json of an earlier run)")
    p.add_argument("--run-dir", help="where run.jsonl, context.json and summary.md go (default uat-runs/<run id>)")
    p.add_argument("--health-url", help="build sha source (default <base-url>/health)")
    p.add_argument("--poll-interval", type=float, help="seconds between task polls (default: the step's interval_s, 2)")
    p.add_argument("--build-sha", help="the build the run is for: /health must report it (a prefix is enough)")
    p.add_argument("--no-stable-check", action="store_true", help="do not call project/scripts/qa_stable.sh --wait")
    p.add_argument("--old-base-url", help="the old address, e.g. https://qa.bizdala.com/qoimeks/<slug>/api (http_as steps)")
    p.add_argument("--file-issues", action="store_true", help="open one GitHub issue per failed process with gh")
    p.add_argument("--repo", help="the repository for --file-issues (default env UAT_ISSUE_REPO or gh's own)")
    p.add_argument("--gh", help="the gh command (default env UAT_GH or gh)")


def build_parser():
    parser = argparse.ArgumentParser(prog="runner.py", description="Deterministic UAT runner (D-167, M1).")
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run", help="run one process file against a tenant")
    run.add_argument("process", help="process file (JSON), e.g. test/uat/processes/BP-01-receive-goods.json")
    add_run_options(run)
    chain = sub.add_parser("chain", help="run the processes of a chain file in order, sharing one context")
    chain.add_argument("chain", help="chain file (JSON), e.g. test/uat/chains/rc-sss.json")
    chain.add_argument("--keep-going", action="store_true", help="go on with the next process after a failure")
    add_run_options(chain)
    cleanup = sub.add_parser("cleanup", help="replay the cleanup list of an aborted run (also: --cleanup <run dir>)")
    cleanup.add_argument("run_dir", help="the run directory of the aborted run")
    cleanup.add_argument("--base-url", help="override the base url recorded in meta.json")
    cleanup.add_argument("--actors", help="override the actors recorded in meta.json")
    cleanup.add_argument("--health-url")
    cleanup.add_argument("--old-base-url")
    cleanup.add_argument("--poll-interval", type=float)
    dry = sub.add_parser("dry-run", help="run every changed process file on QA with its dry_run block")
    dry.add_argument("--changed", action="store_true", help="the files that differ from origin/main (default)")
    dry.add_argument("--files", nargs="+", help="these files instead of the changed ones")
    dry.add_argument("--repo", help="the product checkout (default: the one this script is in)")
    dry.add_argument("--run-dir-root", help="a directory for the run directories (one per file)")
    dry.add_argument("--base-url", help="the same base url for every file (default: the dry_run block, then the template)")
    dry.add_argument("--base-url-template", help="URL with {tenant}")
    dry.add_argument("--health-url")
    dry.add_argument("--poll-interval", type=float)
    dry.add_argument("--build-sha")
    dry.add_argument("--no-stable-check", action="store_true")
    dry.add_argument("--old-base-url")
    return parser


def read_inputs(args) -> dict:
    inputs = {}
    if args.input_file:
        try:
            inputs.update(json.loads(Path(args.input_file).read_text(encoding="utf-8")))
        except (OSError, ValueError) as err:
            raise ConfigError(f"cannot read input file: {err}") from None
    inputs.update(parse_pairs(args.input, "--input"))
    return inputs


def new_run_dir(args, run_id) -> Path:
    run_dir = Path(args.run_dir or os.path.join("uat-runs", run_id))
    if (run_dir / "run.jsonl").exists():
        raise ConfigError(f"{run_dir}/run.jsonl exists: use a new --run-dir")
    return run_dir


def main_run(args) -> int:
    try:
        if args.command == "chain":
            chain, processes = load_chain(args.chain)
            label = chain["id"]
        else:
            chain, processes = {}, [load_process(args.process)]
            label = processes[0]["id"]
        inputs = dict(chain.get("inputs") or {})
        inputs.update(read_inputs(args))
        tenant = args.tenant or chain.get("tenant")
        if not tenant:
            raise ConfigError("--tenant is needed")
        actors = dict(chain.get("actors") or {})
        actors.update(parse_pairs([a for a in (args.actors or "").split(",") if a], "--actors"))
        needed = {s.get("actor") for p in processes for s in p["steps"] + (p.get("cleanup") or []) if not s.get("http_as")}
        needed |= {c["actor"] for p in processes for s in p["steps"] + (p.get("cleanup") or [])
                   for c in s["do"].get("parallel", []) if c.get("actor")}
        needed.discard(None)
        if needed - actors.keys():
            raise ConfigError("actors missing in --actors: " + ", ".join(sorted(needed - actors.keys())))
        check_chain_inputs(processes, set(inputs))
        base_url = args.base_url or chain.get("base_url") or base_url_for(tenant, args.base_url_template)
        run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + secrets.token_hex(3)
        run_dir = new_run_dir(args, run_id)
    except ConfigError as err:
        print(f"runner.py: {err}", file=sys.stderr)
        return 2
    runner = Runner(processes, base_url=base_url, tenant=tenant, actors=actors, run_dir=run_dir, inputs=inputs,
                    health_url=args.health_url, poll_interval=args.poll_interval, run_id=run_id, build_sha=args.build_sha,
                    old_base_url=args.old_base_url or chain.get("old_base_url"), keep_going=getattr(args, "keep_going", False),
                    label=label, file_issues=args.file_issues, repo=args.repo, gh_cmd=args.gh)
    return runner.run(check_stable=not args.no_stable_check)


def main_cleanup(args) -> int:
    run_dir = Path(args.run_dir)
    try:
        meta = json.loads((run_dir / "meta.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as err:
        print(f"runner.py: cannot read {run_dir}/meta.json: {err}", file=sys.stderr)
        return 2
    try:
        actors = dict(meta.get("actors") or {})
        actors.update(parse_pairs([a for a in (args.actors or "").split(",") if a], "--actors"))
    except ConfigError as err:
        print(f"runner.py: {err}", file=sys.stderr)
        return 2
    runner = Runner([{"id": "cleanup", "steps": []}], base_url=args.base_url or meta["base_url"], tenant=meta.get("tenant", ""),
                    actors=actors, run_dir=run_dir, health_url=args.health_url or meta.get("health_url"),
                    poll_interval=args.poll_interval, old_base_url=args.old_base_url or meta.get("old_base_url"))
    return runner.replay_cleanup()


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "--cleanup":
        argv[0] = "cleanup"
    args = build_parser().parse_args(argv)
    if args.command == "cleanup":
        return main_cleanup(args)
    if args.command == "dry-run":
        return cmd_dry_run(args)
    return main_run(args)


if __name__ == "__main__":
    sys.exit(main())
