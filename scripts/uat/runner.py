#!/usr/bin/env python3
"""Deterministic UAT runner for ONE business process (D-167, spike M0).

Runs a process file (JSON, see scripts/uat/README.md) against a Letflow tenant over HTTP:
no model, standard library only. One JSON line per step goes to <run dir>/run.jsonl, the
values saved by the steps go to <run dir>/context.json and a table to <run dir>/summary.md.

Tokens come ONLY from the caller's environment: for each actor the runner calls
`bash "$TEAM_ROOT/project/scripts/uat_creds.sh" token <user>` and keeps the answer in memory.
The runner never prints a token, never writes one to a file and scrubs every token it has
seen (and anything shaped like a JWT) out of the log before it is written.

Exit codes: 0 every step, every cleanup step and the build check passed; 1 a verdict failed;
2 bad usage or a bad process file (nothing was run).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path

HTTP_TIMEOUT_S = 30
TOKEN_CMD_TIMEOUT_S = 60
INBOX_PAGES_MAX = 10
RESPONSE_EXCERPT_MAX = 2000

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


def run_assertions(expect: dict, status: int, body) -> list:
    """expect = {status: 200 | [200, 201], json: {"$.a.b": matcher, "key": matcher}}."""
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
        shown = "***" if SECRET_KEY.search(path) else (actual if found else "<absent>")
        results.append({"what": path, "expected": wanted, "actual": shown, "ok": bool(ok)})
    return results


# -- redaction ----------------------------------------------------------------------------------


def redact(value):
    """Mask the value of every key that looks like a secret, recursively."""
    if isinstance(value, dict):
        return {k: ("***" if SECRET_KEY.search(str(k)) else redact(v)) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v) for v in value]
    return value


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


class Runner:
    def __init__(self, process, *, base_url, tenant, actors, run_dir, inputs=None, health_url=None,
                 poll_interval=None, run_id=None, out=None):
        self.process = process
        self.base_url = base_url.rstrip("/")
        self.health_url = health_url or self.base_url + "/health"
        self.actors = actors
        self.run_dir = Path(run_dir)
        self.poll_interval = poll_interval
        self.run_id = run_id or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + secrets.token_hex(3)
        self.out = out or sys.stdout
        self.tokens = {}
        self.secret_values = set()
        self.instance_docs = {}
        self.records = []
        ctx = dict(process.get("defaults") or {})
        ctx.update(inputs or {})
        ctx.update(
            {
                "tenant": tenant,
                "TENANT": tenant,
                "run_id": self.run_id,
                "now_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            }
        )
        self.ctx = ctx

    # -- log ----------------------------------------------------------------------------------

    def scrub(self, text: str) -> str:
        for secret in self.secret_values:
            text = text.replace(secret, "***")
        return JWT_SHAPE.sub("***", text)

    def write_line(self, record: dict):
        line = self.scrub(json.dumps(record, ensure_ascii=False, sort_keys=False))
        with open(self.run_dir / "run.jsonl", "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
        self.records.append(json.loads(line))
        step = record.get("step")
        tail = f" - {record['error']}" if record.get("error") else ""
        print(self.scrub(f"{record.get('phase', ''):9} {step:12} {record['verdict']:7} {record.get('ms', 0)} ms{tail}"),
              file=self.out, flush=True)

    def save_context(self):
        path = self.run_dir / "context.json"
        tmp = path.with_suffix(".tmp")
        tmp.write_text(self.scrub(json.dumps(self.ctx, indent=2, ensure_ascii=False, default=str)), encoding="utf-8")
        os.replace(tmp, path)

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

    def request(self, role, method, path, body=None, headers=None):
        hdrs = dict(headers or {})
        hdrs["Authorization"] = "Bearer " + self.token_for(role)
        return http_call(method, self.base_url + path, hdrs, body)

    # -- steps --------------------------------------------------------------------------------

    def run_step(self, step: dict, phase: str) -> bool:
        record = {"ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "run_id": self.run_id,
                  "process": self.process["id"], "phase": phase, "step": step["id"], "actor": step["actor"]}
        started = time.monotonic()
        response = None
        try:
            missing = [n for n in step.get("requires", []) if n not in self.ctx]
            if missing:
                record.update(verdict="skipped", error="requires " + ", ".join(missing))
                return self._finish(record, started, True)
            do = step["do"]
            if "wait_task" in do:
                status, body, response = self._wait_task(step, do, record)
            else:
                status, body, response = self._api(step["actor"], do, record)
            expect = substitute(step.get("expect") or {}, self.ctx)
            results = run_assertions(expect, status, body)
            record["status"] = status
            record["asserted"] = results
            failed = [r for r in results if not r["ok"]]
            if failed:
                first = failed[0]
                record.update(verdict="fail", error=f"expected {first['what']} {first['expected']} got {first['actual']}")
                record["response_excerpt"] = (response or "")[:RESPONSE_EXCERPT_MAX]
                return self._finish(record, started, False)
            self._save(step, body, record)
            record["verdict"] = "pass"
            return self._finish(record, started, True)
        except RunnerError as err:
            record.update(verdict="error", error=str(err))
            if response:
                record["response_excerpt"] = response[:RESPONSE_EXCERPT_MAX]
            return self._finish(record, started, False)
        except Exception as err:  # a bug in a process file must not skip the cleanup
            record.update(verdict="error", error=f"{type(err).__name__}: {err}")
            return self._finish(record, started, False)

    def _finish(self, record, started, ok):
        record["ms"] = int((time.monotonic() - started) * 1000)
        self.write_line(record)
        self.save_context()
        return ok

    def _api(self, role, do, record):
        method = str(do["api"]).upper()
        path = substitute(do["path"], self.ctx)
        body = redacted = None
        if "body" in do:
            body = substitute(do["body"], self.ctx)
            redacted = redact(body)
        headers = substitute(do.get("headers") or {}, self.ctx)
        record.update(method=method, path=path)
        if redacted is not None:
            record["request"] = redacted
        status, parsed, text = self.request(role, method, path, body, headers)
        return status, parsed, text

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

    # -- the run ------------------------------------------------------------------------------

    def run(self) -> int:
        self.run_dir.mkdir(parents=True, exist_ok=True)
        started_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.save_context()
        sha_start = health_sha(self.health_url)
        steps_ok, cleanup_ok, build_moved = True, True, False
        pre = {"ts": started_at, "run_id": self.run_id, "process": self.process["id"], "phase": "preflight",
               "step": "health", "actor": "-", "method": "GET", "path": "/health", "sha": sha_start}
        if not sha_start:
            pre.update(verdict="error", error="/health gave no build sha: the run did not start")
            self._finish(pre, time.monotonic(), False)
            self._summary(started_at, None, None, False, False, True)
            return 1
        pre["verdict"] = "pass"
        self._finish(pre, time.monotonic(), True)
        try:
            for step in self.process["steps"]:
                if steps_ok:
                    steps_ok = self.run_step(step, "step")
                else:
                    self.write_line({"run_id": self.run_id, "process": self.process["id"], "phase": "step",
                                     "step": step["id"], "actor": step["actor"], "verdict": "skipped",
                                     "error": "an earlier step failed", "ms": 0})
        finally:
            for step in self.process.get("cleanup") or []:
                cleanup_ok = self.run_step(step, "cleanup") and cleanup_ok
        sha_end = health_sha(self.health_url)
        if sha_end != sha_start:
            build_moved = True
            self.write_line({"run_id": self.run_id, "process": self.process["id"], "phase": "preflight", "step": "build",
                             "actor": "-", "verdict": "fail", "sha": sha_end, "ms": 0,
                             "error": f"build moved: {sha_start} -> {sha_end}"})
        if steps_ok:
            try:
                for name, expr in (self.process.get("outputs") or {}).items():
                    self.ctx[name] = substitute(expr, self.ctx)
            except RunnerError as err:
                steps_ok = False
                self.write_line({"run_id": self.run_id, "process": self.process["id"], "phase": "outputs",
                                 "step": "outputs", "actor": "-", "verdict": "error", "error": str(err), "ms": 0})
        self.save_context()
        ok = steps_ok and cleanup_ok and not build_moved
        self._summary(started_at, sha_start, sha_end, steps_ok, cleanup_ok, build_moved)
        print(f"{self.process['id']}: {'PASS' if ok else 'FAIL'} (run dir {self.run_dir})", file=self.out, flush=True)
        return 0 if ok else 1

    def _summary(self, started_at, sha_start, sha_end, steps_ok, cleanup_ok, build_moved):
        ok = steps_ok and cleanup_ok and not build_moved and sha_start is not None
        lines = [
            f"# UAT run {self.process['id']} - {self.process.get('title', '')}",
            "",
            f"- run id: {self.run_id}",
            f"- tenant: {self.ctx.get('tenant')}   base url: {self.base_url}",
            f"- started: {started_at}",
            f"- build sha at start: {sha_start}   at end: {sha_end}" + ("   **build moved: the run fails**" if sha_start != sha_end else ""),
            f"- steps: {'pass' if steps_ok else 'FAIL'}   cleanup: {'pass' if cleanup_ok else 'FAIL'}",
            f"- verdict: **{'PASS' if ok else 'FAIL'}**",
            "",
            "| phase | step | actor | request | status | verdict | ms | note |",
            "|---|---|---|---|---|---|---|---|",
        ]
        for r in self.records:
            req = f"{r.get('method', '')} {r.get('path', '')}".strip()
            lines.append(f"| {r.get('phase', '')} | {r.get('step', '')} | {r.get('actor', '')} | {req} | "
                         f"{r.get('status', '')} | {r.get('verdict', '')} | {r.get('ms', '')} | {str(r.get('error', '')).replace('|', '/')} |")
        outputs = {k: self.ctx.get(k) for k in (self.process.get("outputs") or {}) if k in self.ctx}
        lines += ["", "## Outputs", "", "```json", json.dumps(outputs, indent=2, default=str), "```", ""]
        for key in ("balance_before", "balance_after", "balance_end"):
            if key in self.ctx:
                lines.append(f"- {key}: {self.ctx[key]}")
        (self.run_dir / "summary.md").write_text(self.scrub("\n".join(lines) + "\n"), encoding="utf-8")


# -- loading and the CLI ------------------------------------------------------------------------


def load_process(path) -> dict:
    try:
        process = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as err:
        raise ConfigError(f"cannot read process file {path}: {err}") from None
    if not isinstance(process, dict) or not process.get("id") or not isinstance(process.get("steps"), list) or not process["steps"]:
        raise ConfigError("a process file needs an id and a non-empty steps list")
    seen = set()
    for step in process["steps"] + (process.get("cleanup") or []):
        if not isinstance(step, dict) or not all(k in step for k in ("id", "actor", "do")):
            raise ConfigError(f"every step needs id, actor and do: {str(step)[:80]}")
        if step["id"] in seen:
            raise ConfigError(f"duplicate step id {step['id']}")
        seen.add(step["id"])
        do = step["do"]
        if not isinstance(do, dict) or not ("api" in do or "wait_task" in do):
            raise ConfigError(f"step {step['id']}: do needs api or wait_task")
        if "api" in do and "path" not in do:
            raise ConfigError(f"step {step['id']}: an api step needs a path")
        if "wait_task" in do and not {"for_document", "step"} <= set(do["wait_task"]):
            raise ConfigError(f"step {step['id']}: wait_task needs for_document and step")
    return process


def parse_pairs(items, what) -> dict:
    out = {}
    for item in items:
        name, sep, value = item.partition("=")
        if not sep or not name:
            raise ConfigError(f"{what}: expected name=value, got {item!r}")
        out[name] = value
    return out


def build_parser():
    parser = argparse.ArgumentParser(prog="runner.py", description="Deterministic UAT runner (D-167, spike M0).")
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run", help="run one process file against a tenant")
    run.add_argument("process", help="process file (JSON), e.g. test/uat/processes/BP-01-receive-goods.json")
    run.add_argument("--tenant", required=True, help="tenant slug (becomes ${tenant})")
    run.add_argument("--base-url", required=True, help="e.g. https://TENANT.letflow.qa.bizdala.com")
    run.add_argument("--actors", required=True, help="actor=keycloak-user,... e.g. admin=qoimeks-qa-admin,storekeeper=qoimeks-qa-store")
    run.add_argument("--input", nargs="+", action="extend", default=[], metavar="NAME=VALUE", help="process inputs")
    run.add_argument("--input-file", help="JSON file with inputs (e.g. the context.json of an earlier run)")
    run.add_argument("--run-dir", help="where run.jsonl, context.json and summary.md go (default uat-runs/<run id>)")
    run.add_argument("--health-url", help="build sha source (default <base-url>/health)")
    run.add_argument("--poll-interval", type=float, help="seconds between task polls (default: the step's interval_s, 2)")
    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    try:
        process = load_process(args.process)
        inputs = {}
        if args.input_file:
            try:
                inputs.update(json.loads(Path(args.input_file).read_text(encoding="utf-8")))
            except (OSError, ValueError) as err:
                raise ConfigError(f"cannot read input file: {err}") from None
        inputs.update(parse_pairs(args.input, "--input"))
        actors = parse_pairs([a for a in args.actors.split(",") if a], "--actors")
        needed = {s["actor"] for s in process["steps"] + (process.get("cleanup") or [])}
        if needed - actors.keys():
            raise ConfigError("actors missing in --actors: " + ", ".join(sorted(needed - actors.keys())))
        have = set(inputs) | set(process.get("defaults") or {})
        if set(process.get("inputs") or []) - have:
            raise ConfigError("inputs missing: " + ", ".join(sorted(set(process["inputs"]) - have)))
        run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + secrets.token_hex(3)
        run_dir = Path(args.run_dir or os.path.join("uat-runs", run_id))
        if (run_dir / "run.jsonl").exists():
            raise ConfigError(f"{run_dir}/run.jsonl exists: use a new --run-dir")
    except ConfigError as err:
        print(f"runner.py: {err}", file=sys.stderr)
        return 2
    runner = Runner(process, base_url=args.base_url, tenant=args.tenant, actors=actors, run_dir=run_dir,
                    inputs=inputs, health_url=args.health_url, poll_interval=args.poll_interval, run_id=run_id)
    return runner.run()


if __name__ == "__main__":
    sys.exit(main())
