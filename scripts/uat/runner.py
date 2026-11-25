#!/usr/bin/env python3
"""Deterministic UAT runner for ONE business process (D-167, spike M0).

Runs a process file (JSON, see scripts/uat/README.md) against a Letflow tenant over HTTP:
no model, standard library only. One JSON line per step goes to <run dir>/run.jsonl, the
values saved by the steps go to <run dir>/context.json and a table to <run dir>/summary.md.

Tokens come ONLY from the caller's environment: for each actor the runner calls
`bash "$TEAM_ROOT/project/scripts/uat_creds.sh" token <user>` and keeps the answer in memory.
The runner never prints a token, never writes one to a file and scrubs every token it has
seen (and anything shaped like a JWT) out of the log before it is written.

An actor is a user name ("qoimeks-qa2-admin") or an object that says where it lives
({"user": "admin-user", "tenant": "bpm-default", "base_url": "https://qa.bizdala.com"}): the
platform administrator of the platform tenant. Its requests go to its own address, its token
belongs to its own tenant, and the preflight, the retired-tenant guard and the residue check
cover that tenant too.

Commands: `run` (one process), `chain` (an ordered list of processes with isolated working contexts and explicit
`pass` lists for outputs handed on), `cleanup` (replay the recorded cleanup list of an aborted run, also
`--cleanup <run dir>`) and `dry-run` (run every changed process file on QA with its own `dry_run` block).

A chain file may say `"cleanup": "per_process"`: the cleanup of a process then runs right after that process
(instead of after the last one of the chain), so that the next process meets the tenant without what the previous
one created. The default is `"cleanup": "end"`.

A step may wait for a mail in the mail trap (`wait_mail`: by recipient and subject, the body of the mail never
reaches the log, the recipient and the address of the trap are masked) and a process may say what the run watches
on the platform tenant (`platform_residue`: the definitions that must be back on their version and the instances
that must not be left open).

Exit codes: 0 every step, every cleanup step and the build check passed; 1 a verdict failed;
2 bad usage or a bad process file (nothing was run). `dry-run` never uses 2 for a failure: the
bp_dryrun capability reads exit 2 as "this runner has no such command yet".
"""

from __future__ import annotations

import argparse
import contextlib
import json
import math
import os
import re
import secrets
import shlex
import subprocess
import sys
import tempfile
import threading
import time
import uuid
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
DO_KINDS = ("api", "wait_task", "wait_mail", "assert_only", "repeat", "parallel")
# The mail trap (Mailpit) a wait_mail step reads: the address of the trap, how long a search may take and
# how many messages of the search answer are looked at (G18).
MAIL_TRAP_URL_DEFAULT = "http://127.0.0.1:8025"
MAIL_TRAP_TIMEOUT_S = 10
MAIL_SEARCH_LIMIT = 25
# When the cleanups of a chain's processes run: "end" (all of them after the last process, newest first)
# or "per_process" (the cleanup of a process runs right after that process).
CLEANUP_MODES = ("end", "per_process")
DEFAULT_BASE_URL_TEMPLATE = "https://{tenant}.letflow.qa.bizdala.com"
# The throwaway platform tenants of the platform scenarios (PM 22:3x/22:4x): the safe slug prefix infra
# confirmed, the one fixed fixture tenant that is never residue, and the states a tenant ends in.
PLATFORM_TENANT_PREFIX = "uat-tmp-"
PLATFORM_FIXTURE_TENANT = "uat-tmp-fixture"
PLATFORM_TENANT_FINAL_STATUSES = ("inactive",)
TENANT_REGISTRY_PATH = "/api/v1/tenants"
# ${uuid1} .. ${uuid12}: twelve fresh UUIDs per run (a client operation id of the old phone address must be a
# new UUID for every operation and the same one on a retry; the run makes them, the process file only names them).
UUID_NAMES = tuple(f"uuid{i}" for i in range(1, 13))
BUILTIN_NAMES = ("tenant", "TENANT", "run_id", "now_utc", "old_base_url") + UUID_NAMES

SECRET_KEY = re.compile(r"pass(?:word|wd)?|secret|token|authorization|api[_-]?key|credential|access", re.I)
JWT_SHAPE = re.compile(r"(?<![A-Za-z0-9_.-])[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+(?![A-Za-z0-9_.-])")
BEARER_SHAPE = re.compile(r"\bBearer(?:[ \t]+[A-Za-z0-9._~+/=-]+)?", re.I)
AUTHORIZATION_HEADER = re.compile(r"(?im)(?<![\"A-Za-z0-9_])(Authorization\s*:\s*)[^\r\n]*")
EMAIL_SHAPE = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
URL_SHAPE = re.compile(r"\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s'\"<>()]+")
PHONE_SHAPE = re.compile(r"(?<![\w.-])(?:\+[0-9][0-9\s().-]{6,}[0-9]|[0-9]{10,15}|[0-9][0-9\s()-]{6,}[0-9]|\([0-9]{3}\)[0-9\s.-]{6,}[0-9])(?![\w.-])")
PLAIN_DECIMAL = re.compile(r"^-?\d+(\.\d+)?$")
OPERATORS = {"equals", "contains", "regex", "absent", "exists", "default"}


class RunnerError(Exception):
    """A step cannot be executed or its answer is not what the process expects."""


class ConfigError(Exception):
    """The process file or the command line is wrong; nothing was run."""


def actor_spec(value, where="actor") -> dict:
    """-> {"user": str, "tenant": str|None, "base_url": str|None}: one actor of a run.

    The plain string form stays: "qoimeks-qa2-admin" is an actor of the tenant of the run. The object
    form says where the actor lives: {"user": "admin-user", "tenant": "bpm-default",
    "base_url": "https://qa.bizdala.com"} is an actor of another tenant (the platform administrator),
    whose requests go to its own address and whose token is minted for its own realm.
    """
    if isinstance(value, str):
        user = value.strip()
        if not user:
            raise ConfigError(f"{where}: an actor needs a user name")
        return {"user": user, "tenant": None, "base_url": None}
    if isinstance(value, dict):
        user = value.get("user")
        if not isinstance(user, str) or not user.strip():
            raise ConfigError(f"{where}: an actor object needs a user name")
        tenant = value.get("tenant")
        if tenant is not None and (not isinstance(tenant, str) or not tenant.strip()):
            raise ConfigError(f"{where}: the tenant of an actor must be a text")
        base_url = value.get("base_url")
        if base_url is not None:
            if not isinstance(base_url, str) or not base_url.strip():
                raise ConfigError(f"{where}: the base url of an actor must be a text")
            base_url = base_url.strip().rstrip("/")
            if not base_url.startswith(("http://", "https://")):
                raise ConfigError(f"{where}: the base url of an actor must be an http(s) address")
        return {"user": user.strip(), "tenant": tenant.strip() if tenant else None, "base_url": base_url}
    raise ConfigError(f"{where}: an actor is a user name or an object {{user, tenant, base_url}}")


def normalize_actors(actors, where="actors") -> dict:
    """-> {role: actor spec}. A bad entry is a usage error (exit 2), never a failed run."""
    if not isinstance(actors, dict):
        raise ConfigError(f"{where} must be an object {{actor: user name or {{user, tenant, base_url}}}}")
    out = {}
    for role, value in actors.items():
        if not isinstance(role, str) or not role.strip():
            raise ConfigError(f"{where}: an actor needs a name")
        out[role] = actor_spec(value, f"{where}[{role!r}]")
    return out


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


def wait_time_ok(value) -> bool:
    """Can the runner read this as a wait time (wait_mail within_s, interval_s)?

    A number, a numeric text, or a whole ${...} reference: the value of a reference is substituted before it is
    read, so the loader must not refuse a file whose time comes from a name of the context. The static checker
    (scripts/uat/check_processes.py) asks this same question, so the two never disagree about one file."""
    if isinstance(value, bool):
        return False
    if isinstance(value, (int, float)):
        return math.isfinite(value)
    if not isinstance(value, str):
        return False
    text = value.strip()
    if not text:
        return False
    if _PLACEHOLDER.fullmatch(text):
        return bool(_PLACEHOLDER.fullmatch(text).group(1).strip())
    try:
        return math.isfinite(float(text))
    except ValueError:
        return False


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


def _mask_characters(match, pattern) -> str:
    return re.sub(pattern, "*", match.group())


def _mask_phone(match) -> str:
    value = match.group()
    if re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", value):
        return value  # an ISO calendar date is not a phone number
    if re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", value):
        return value  # an all-numeric UUID is still an identifier, not a phone number
    return _mask_characters(match, r"[0-9]")


def redact_text(text: str) -> str:
    """Mask credentials and contact details in free text, preserving punctuation and the shape of numbers."""
    text = AUTHORIZATION_HEADER.sub(lambda m: m.group(1) + "***", text)
    text = BEARER_SHAPE.sub("***", text)
    text = JWT_SHAPE.sub("***", text)
    text = EMAIL_SHAPE.sub(lambda m: _mask_characters(m, r"[A-Za-z0-9]"), text)
    return PHONE_SHAPE.sub(_mask_phone, text)


def redact(value):
    """Mask secret-looking fields and sensitive strings, recursively."""
    if isinstance(value, dict):
        return {k: ("***" if SECRET_KEY.search(str(k)) else redact(v)) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v) for v in value]
    if isinstance(value, str):
        return redact_text(value)
    return value


def excerpt(text, limit=RESPONSE_EXCERPT_MAX) -> str:
    """The start of an answer for the log, with secret fields and sensitive strings masked."""
    text = text or ""
    try:
        parsed = json.loads(text)
    except ValueError:
        return redact_text(text)[:limit]
    return json.dumps(redact(parsed), ensure_ascii=False)[:limit]


def log_safe_url(url: str) -> str:
    """A URL as it may be written in a log or a record: the scheme, the host and the path, without the
    userinfo, the query and the fragment.

    The search of a mail trap carries the recipient (a personal datum) in its query and a trap address may
    carry a credential in its userinfo; neither of them may reach a run record."""
    try:
        parts = urllib.parse.urlsplit(url)
        host, port = parts.hostname or "", parts.port
    except ValueError:
        return "<address>"
    if not parts.scheme or not parts.netloc:
        return "<address>"
    netloc = f"{host}:{port}" if port else host
    return urllib.parse.urlunsplit((parts.scheme, netloc, parts.path, "", ""))


def scrub_urls(text: str) -> str:
    """Free text that may hold a URL (the reason of a transport error): every URL in it loses its userinfo,
    its query and its fragment."""
    return URL_SHAPE.sub(lambda m: log_safe_url(m.group(0)), text)


def mask_mail_recipient(recipient: str) -> str:
    """The mailbox of a mail as it may be written in a log: its shape, never its value.

    A mailbox is a personal datum, and the general redaction cannot be relied on for it: it reads by shape,
    and an address with two dots has the shape of a token."""
    return re.sub(r"[A-Za-z0-9]", "*", recipient)


def trap_problem(url: str) -> str:
    """Why a mail trap address cannot be used, or "" when it can. The address itself is never named.

    The trap is a plain Mailpit on a host: a credential in it, a query or a fragment have no meaning there,
    and urllib cannot even connect through a userinfo."""
    try:
        parts = urllib.parse.urlsplit(url)
    except ValueError:
        return "the mail trap address cannot be parsed"
    if parts.scheme not in ("http", "https"):
        return "the mail trap address is not an http(s) address"
    if not parts.hostname:
        return "the mail trap address has no host"
    if parts.username or parts.password:
        return "the mail trap address must not carry a credential"
    if parts.query or parts.fragment:
        return "the mail trap address must not carry a query or a fragment"
    return ""


# -- HTTP ---------------------------------------------------------------------------------------


def http_call(method: str, url: str, headers: dict, body, timeout=HTTP_TIMEOUT_S):
    """-> (status, parsed json or None, raw text). Transport errors raise RunnerError.

    The address that goes into an error is written without its userinfo, its query and its fragment: the
    search of a mail trap carries the recipient in its query."""
    data = None
    hdrs = {"Accept": "application/json", "User-Agent": "uat-runner/0"}
    hdrs.update(headers)
    if body is not None:
        data = json.dumps(body).encode()
        hdrs.setdefault("Content-Type", "application/json")
    try:
        request = urllib.request.Request(url, data=data, method=method, headers=hdrs)
    except ValueError as err:
        raise RunnerError(f"{method} {log_safe_url(url)}: the address cannot be used "
                          f"({type(err).__name__})") from None
    try:
        with urllib.request.urlopen(request, timeout=timeout) as resp:
            status, raw = resp.status, resp.read()
    except urllib.error.HTTPError as err:
        status, raw = err.code, err.read()
    except (urllib.error.URLError, OSError) as err:
        reason = scrub_urls(str(getattr(err, "reason", err)))
        raise RunnerError(f"{method} {log_safe_url(url)}: transport error: {reason}") from None
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


RESIDUE_FINAL_STATES = ("reversed", "cancelled", "rejected")
RESIDUE_DOC_LIMIT = 200  # the newest non-final documents listed per tenant, before and after a run
RESIDUE_CURSOR_RESTARTS = 3  # expired open-task cursors: restart from page one, then fail closed


class Runner:
    """One run: fixtures share the base context; each chain process gets its own context plus passed outputs."""

    def __init__(self, process, *, base_url, tenant, actors, run_dir, inputs=None, health_url=None,
                 poll_interval=None, run_id=None, out=None, build_sha=None, old_base_url=None,
                 keep_going=False, label=None, file_issues=False, repo=None, gh_cmd=None, fixtures=None, pass_map=None,
                 overrides=None, cleanup_mode="end", residue_check=True, allow_create=False, mail_trap_url=None):
        if cleanup_mode not in CLEANUP_MODES:
            raise ConfigError(f"cleanup must be one of {', '.join(CLEANUP_MODES)}, got {cleanup_mode!r}")
        self.residue_check = residue_check  # chain/run level switch; a process may also say "residue_check": false
        self.residue_before = {}  # tenant -> {base_url, actors, docs, tasks} recorded before the first process
        self.platform_before = {}  # tenant -> {base_url, actor, tenants} recorded before the first process
        # What a cleanup replay cannot judge (G-08): a missing baseline is a failing residue row, never a
        # skipped check.
        self.baseline_problems = []
        self.cleanup_mode = cleanup_mode  # a chain's "cleanup": when the cleanups of its processes run
        self.overrides = {pid: dict(over, actors=normalize_actors(over.get("actors") or {}, f"chain entry {pid} actors"))
                          for pid, over in (overrides or {}).items()}
        self.allow_create = allow_create  # a tenant may be created only when the caller says so (--allow-create)
        self.tokens = {}  # (tenant, user) -> token: a token belongs to a user of a tenant, not to a role
        self.token_refreshes = 0  # a step whose request caused a re-login is logged with retried: true
        self.process_tenants = {}
        self.processes = list(process) if isinstance(process, (list, tuple)) else [process]
        self.fixtures = list(fixtures or [])  # fixture documents, in run order (see expand_fixtures)
        self.pass_map = pass_map or {}  # chain: source process id -> output names the later processes may read
        self.process_outputs = {}  # all declared outputs, for the final context/report; never implicit process input
        self.process = self.processes[0]
        self.label = label or "+".join(p["id"] for p in self.processes)
        self.base_url = base_url.rstrip("/")
        self.health_url = health_url or self.base_url + "/health"
        self.old_base_url = old_base_url.rstrip("/") if old_base_url else None
        self.actors = normalize_actors(actors)
        self.run_dir = Path(run_dir)
        self.poll_interval = poll_interval
        self.build_sha = build_sha
        self.keep_going = keep_going
        self.file_issues = file_issues
        self.repo = repo
        self.gh_cmd = gh_cmd
        self.run_id = run_id or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + secrets.token_hex(3)
        self.out = out or sys.stdout
        self.secrets = {}  # in memory only: a value a step saved with {"secret": path}
        self.secret_values = set()
        self.instance_docs = {}
        # The mail trap a wait_mail step reads (G18): the command line, then MAIL_TRAP_URL, then the local trap.
        self.mail_trap_url = (mail_trap_url or os.environ.get("MAIL_TRAP_URL") or MAIL_TRAP_URL_DEFAULT).rstrip("/")
        self.blocked_saves = {}  # name -> why: the values only a blocked (never run) step would have saved
        self.started_instances = []  # the instances this run started: {"instance_id", "tenant", "base_url", "role"}
        self.platform_watch = {}  # what the run watches on the platform tenant: {"definitions": [...], "instances": [...]}
        self.records = []
        self.entries = []  # cleanup list: {process, cleanup: [steps], ctx, done}
        self.issues = {}
        self.replay = False
        self.started_mono = time.monotonic()
        ctx = dict(inputs or {})
        ctx.update({"tenant": tenant, "TENANT": tenant, "run_id": self.run_id, "now_utc": now_utc()})
        ctx.update({name: str(uuid.uuid4()) for name in UUID_NAMES})
        if self.old_base_url:
            ctx["old_base_url"] = self.old_base_url
        self.ctx = ctx
        self.tenant = tenant
        self.main_view = None

    @contextlib.contextmanager
    def _on(self, pid):
        """Run as the tenant of a chain entry that has its own (tenant, actors, base urls)."""
        over = self.overrides.get(pid)
        keep = (self.tenant, self.base_url, self.actors, self.old_base_url)
        self.process_tenants[pid] = over["tenant"] if over else self.tenant
        if over:
            self.tenant, self.base_url, self.actors = over["tenant"], over["base_url"].rstrip("/"), over["actors"]
            self.old_base_url = (over.get("old_base_url") or "").rstrip("/") or None
        try:
            yield over
        finally:
            self.tenant, self.base_url, self.actors, self.old_base_url = keep

    def _fresh_ctx(self, over):
        ctx = dict(over.get("inputs") or {})
        ctx.update({"tenant": over["tenant"], "TENANT": over["tenant"], "run_id": self.run_id, "now_utc": now_utc()})
        ctx.update({name: str(uuid.uuid4()) for name in UUID_NAMES})
        if over.get("old_base_url"):
            ctx["old_base_url"] = over["old_base_url"].rstrip("/")
        return ctx

    # -- log ----------------------------------------------------------------------------------

    def scrub(self, text: str) -> str:
        for secret in self.secret_values:
            text = text.replace(secret, "***")
        return redact_text(text)

    def write_line(self, record: dict):
        record.setdefault("run_id", self.run_id)
        record.setdefault("process", self.process["id"])
        record = redact(record)
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
            self._atomic_write("context.json", json.dumps(redact(self.ctx), indent=2, ensure_ascii=False, default=str))
        if self.entries:
            self._atomic_write("cleanup.json", json.dumps(redact(self.entries), indent=2, ensure_ascii=False, default=str))

    def save_meta(self, started_at):
        meta = {"run_id": self.run_id, "label": self.label, "tenant": self.tenant, "base_url": self.base_url,
                "health_url": self.health_url, "old_base_url": self.old_base_url, "actors": self.actors,
                "started": started_at, "processes": [p["id"] for p in self.processes]}
        self._atomic_write("meta.json", json.dumps(redact(meta), indent=2, ensure_ascii=False))

    # -- tokens -------------------------------------------------------------------------------

    def actor_spec(self, role: str) -> dict:
        """The actor of this role: {"user", "tenant", "base_url"}. An actor of another tenant keeps
        its own tenant and address; a plain actor lives on the tenant of the run."""
        spec = self.actors.get(role)
        if not spec:
            raise RunnerError(f"no user for actor {role!r} (--actors)")
        return spec

    def actor_base(self, role: str) -> str:
        """The address the requests of this actor go to: its own, or the one of the run."""
        return self.actor_spec(role).get("base_url") or self.base_url

    def _token_key(self, spec: dict, tenant=None) -> tuple:
        """A token belongs to a user of a tenant: the same user on two tenants is two tokens."""
        return (tenant or spec.get("tenant") or self.tenant, spec["user"])

    def _token_of(self, spec: dict, role: str = "", tenant=None) -> str:
        """The token of one actor: minted by project/scripts/uat_creds.sh for the realm of its user."""
        key = self._token_key(spec, tenant)
        if key in self.tokens:
            return self.tokens[key]
        user = spec["user"]
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
        self.tokens[key] = match.group(1)
        self.secret_values.add(match.group(1))
        return match.group(1)

    def token_for(self, role: str) -> str:
        return self._token_of(self.actor_spec(role), role)

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
        base = self.actor_base(role)
        hdrs["Authorization"] = "Bearer " + self.token_for(role)
        result = http_call(method, base + path, hdrs, body)
        if result[0] == 401:
            # A chain can outlive the preflight token. Re-login this actor once and retry only this request;
            # a second 401 is returned to the step's normal assertions and fails it.
            self.token_refreshes += 1
            self.tokens.pop(self._token_key(self.actor_spec(role)), None)
            hdrs["Authorization"] = "Bearer " + self.token_for(role)
            result = http_call(method, base + path, hdrs, body)
        return result

    def _fresh_process_tokens(self, process) -> bool:
        """Mint at the start of every process, not only at preflight: a long chain must not reuse an old token."""
        started = time.monotonic()
        roles = self.needed_roles([process], fixtures=False)
        try:
            for role in roles:
                self.tokens.pop(self._token_key(self.actor_spec(role)), None)
                self.token_for(role)
        except RunnerError as err:
            self.write_line({"phase": "tokens", "step": f"token:{process['id']}", "actor": role, "verdict": "error",
                             "ms": int((time.monotonic() - started) * 1000), "error": str(err)})
            return False
        self.write_line({"phase": "tokens", "step": f"token:{process['id']}", "actor": ", ".join(roles) or "-",
                         "verdict": "pass", "ms": int((time.monotonic() - started) * 1000), "minted": roles})
        return True

    def needed_roles(self, processes=None, fixtures=True) -> list:
        roles = set()
        if processes is None:
            processes = [p for p in self.processes if p["id"] not in self.overrides]
        for process in (list(self.fixtures) if fixtures else []) + list(processes):
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

    def tenant_groups(self) -> list:
        """-> [{tenant, base_url, health_url, actors: {role: spec}, roles: {role}}] for every tenant this run
        touches: the tenant of the run, the tenants of the chain's other entries and the tenants the actors
        name. An actor object names the tenant it lives on; a plain actor lives on the tenant of its process.
        The first group is always the tenant of the run."""
        groups = {}

        def group(tenant, base_url, health_url=None):
            got = groups.get(tenant)
            if got is None:
                base = base_url.rstrip("/")
                got = {"tenant": tenant, "base_url": base, "health_url": health_url or (base + "/health"),
                       "actors": {}, "roles": set()}
                groups[tenant] = got
            return got

        bases = {self.tenant: self.base_url}
        for over in self.overrides.values():
            bases.setdefault(over["tenant"], over["base_url"].rstrip("/"))
        main = group(self.tenant, self.base_url, self.health_url)
        maps = [(self.actors, self.tenant, self.needed_roles())]
        for pid, over in self.overrides.items():
            maps.append((over["actors"], over["tenant"],
                         self.needed_roles([p for p in self.processes if p["id"] == pid], fixtures=False)))
        for actors, process_tenant, roles in maps:
            base = bases.get(process_tenant, self.base_url)
            for role, spec in actors.items():
                tenant = spec.get("tenant") or process_tenant
                got = group(tenant, spec.get("base_url") or base)
                got["actors"][role] = spec
                if role in roles:
                    got["roles"].add(role)
        main["base_url"] = self.base_url
        main["health_url"] = self.health_url
        return list(groups.values())

    def _pre_line(self, step, verdict, started, **extra):
        record = {"ts": now_utc(), "phase": "preflight", "step": step, "actor": "-", "verdict": verdict,
                  "ms": int((time.monotonic() - started) * 1000), "process": self.label}
        record.update(extra)
        self.write_line(record)
        return verdict != "error" and verdict != "fail"

    def preflight(self, check_stable=True, subject="the run"):
        """-> (ok, sha at start). The run starts only when this passes: a sha, the expected build, a stable
        build, a reachable tenant and a token for every actor. Every tenant the run touches is checked.
        The cleanup replay of a run dir makes the same checks (G-08): subject says who did not start."""
        started = time.monotonic()
        sha = health_sha(self.health_url)
        if not sha:
            self._pre_line("health", "error", started, method="GET", path="/health", sha=None,
                           error=f"/health gave no build sha: {subject} did not start")
            return False, None
        self._pre_line("health", "pass", started, method="GET", path="/health", sha=sha)
        if self.build_sha:
            if not sha_matches(sha, self.build_sha):
                self._pre_line("build_sha", "fail", time.monotonic(), sha=sha,
                               error=f"build is {sha}, expected {self.build_sha}: {subject} did not start")
                return False, sha
            # The row is written whether the check passed or failed: a reader sees that the check was made.
            self._pre_line("build_sha", "pass", time.monotonic(), sha=sha)
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
        groups = self.tenant_groups()
        ok = self._group_tokens(groups[0], main=True)
        for group in groups[1:]:
            ok = self._group_preflight(group) and ok
        return ok, sha

    def _group_preflight(self, group):
        """Reachability, health and the tokens of one more tenant of the run (not the tenant of the run)."""
        tenant = group["tenant"]
        started = time.monotonic()
        try:
            status, _, _ = http_call("GET", group["base_url"] + "/", {}, None, timeout=15)
            reachable, why = status < 500, f"answered {status}"
        except RunnerError as err:
            reachable, why = False, str(err)
        if not reachable:
            return self._pre_line(f"tenant:{tenant}", "error", started,
                                  error=f"tenant {tenant} not reachable at {group['base_url']}: {why}")
        self._pre_line(f"tenant:{tenant}", "pass", started, method="GET", path="/", status=status)
        started = time.monotonic()
        sha = health_sha(group["health_url"])
        if not sha:
            return self._pre_line(f"health:{tenant}", "error", started, method="GET", path="/health", sha=None,
                                  error=f"tenant {tenant}: /health gave no build sha: the run did not start")
        self._pre_line(f"health:{tenant}", "pass", started, method="GET", path="/health", sha=sha)
        return self._group_tokens(group)

    def _group_tokens(self, group, main=False):
        """A token for every actor of this tenant the run uses: the run does not start without it."""
        ok = True
        for role in sorted(group["roles"]):
            started = time.monotonic()
            step = f"token:{role}" if main else f"token:{group['tenant']}:{role}"
            try:
                self._token_of(group["actors"][role], role, group["tenant"])
            except RunnerError as err:
                ok = self._pre_line(step, "error", started, actor=role, error=str(err)) and ok
                continue
            self._pre_line(step, "pass", started, actor=role)
        return ok

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

    # -- steps --------------------------------------------------------------------------------

    def run_step(self, step: dict, phase: str) -> bool:
        record = {"ts": now_utc(), "run_id": self.run_id, "process": self.process["id"], "phase": phase,
                  "step": step["id"], "actor": step.get("actor") or "-", "_token_refreshes": self.token_refreshes}
        started = time.monotonic()
        response = None
        secret_step = self._handles_secret(step)
        try:
            if blocked_reason(step):
                # a step that waits for a piece that is not built: reported, never run, never a pass
                return self._blocked_line(record, started, step, blocked_reason(step))
            waits = [n for n in step.get("requires", []) if n not in self.ctx and n in self.blocked_saves]
            if waits:
                # it needs a value that only a blocked step would have saved: blocked too, never skipped
                return self._blocked_line(record, started, step, self.blocked_saves[waits[0]])
            missing = [n for n in step.get("requires", []) if n not in self.ctx]
            if missing:
                record.update(verdict="skipped", error="requires " + ", ".join(missing))
                return self._finish(record, started, True)
            present = [n for n in step.get("skip_if", []) if n in self.ctx]
            if present:
                record.update(verdict="skipped", error="skip_if " + ", ".join(present) + " (already there)")
                return self._finish(record, started, True)
            create = None if step.get("refusal_probe") else self._tenant_create(step)
            if create is not None:
                reason = self._create_skip_reason(step, create)
                if reason:
                    record.update(verdict="skipped", error=reason)
                    return self._finish(record, started, True)
            do = step["do"]
            calls = self._execute(step, do, record)
            self._note_started_instances(step, calls)
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

    def _blocked_line(self, record, started, step, why):
        """A step that waits for a piece that is not built: reported, never run, never a pass, never a failure.
        The names it would have saved are blocked as well, so the steps that need them are not run either."""
        record.update(verdict="blocked", error="not run: blocked by " + why)
        for name in step.get("save") or {}:
            self.blocked_saves.setdefault(name, why)
        return self._finish(record, started, True)

    def _blocked_names(self, text) -> list:
        """-> the names of a `${...}` text that only a blocked step would have saved (and no step has)."""
        names = [m.group(1).strip() for m in _PLACEHOLDER.finditer(str(text))]
        return [n for n in names if n not in self._watch_context() and n in self.blocked_saves]

    @staticmethod
    def _handles_secret(step) -> bool:
        if step.get("http_as"):
            return True
        return any(isinstance(spec, dict) and "secret" in spec for spec in (step.get("save") or {}).values())

    def _note_started_instances(self, step: dict, calls: list):
        """An instance the run started is remembered: the platform residue check asks whether it is still open.

        The instance lives in the tenant of the actor that started it (the platform administrator starts the
        platform process in the platform tenant), so the tenant of the actor is remembered with it."""
        role = step.get("actor") or ""
        for status, body, _ in calls:
            if status >= 300 or not isinstance(body, dict):
                continue
            instance_id = body.get("instance_id")
            if not isinstance(instance_id, str) or not instance_id:
                continue
            spec = self.actors.get(role) or {}
            tenant = spec.get("tenant") or self.tenant
            base_url = spec.get("base_url") or self.base_url
            entry = {"instance_id": instance_id, "tenant": tenant, "base_url": base_url, "role": role}
            if entry not in self.started_instances:
                self.started_instances.append(entry)
                self._save_platform_watch()  # the cleanup replay of an interrupted run must know the instance

    def _tenant_create(self, step) -> dict:
        """The body of a step that creates a tenant (POST /api/v1/tenants), or None when it creates none."""
        do = step.get("do") or {}
        calls = []
        if "parallel" in do:
            calls = do["parallel"]
        elif "repeat" in do:
            calls = [do["repeat"]]
        elif "api" in do:
            calls = [do]
        try:
            for spec in calls:
                if not isinstance(spec, dict):
                    continue
                path = substitute(spec.get("path", ""), self.ctx).rstrip("/")
                if str(spec.get("api", "")).upper() != "POST" or path != TENANT_REGISTRY_PATH:
                    continue
                body = spec.get("body")
                return substitute(body, self.ctx) if isinstance(body, dict) else {}
        except RunnerError:
            return None  # a name nobody gave: the step itself fails with that error
        return None

    def _create_skip_reason(self, step, body: dict) -> str:
        """Why a tenant must not be created now (empty: it may run)."""
        if not self.allow_create:
            return "creating a tenant needs --allow-create"
        slug = str(body.get("slug") or "")
        today = datetime.now(timezone.utc).strftime("%Y%m%d")
        prefix = PLATFORM_TENANT_PREFIX + today
        if not slug.startswith(prefix):
            return ""  # only the throwaway tenants of the day are limited to one
        role = step.get("actor")
        try:
            status, answer, _ = self.request(role, "GET", TENANT_REGISTRY_PATH)
        except RunnerError:
            return ""  # the registry cannot be read: the create step answers for itself
        if status != 200 or not isinstance(answer, dict):
            return ""
        for row in answer.get("items") or []:
            if isinstance(row, dict) and str(row.get("slug") or "").startswith(prefix):
                return "already created today"
        return ""

    @staticmethod
    def _excerpt(text, secret_step, _status):
        if secret_step:
            return "<withheld: the answer carries a secret>"
        return excerpt(text)

    def _finish(self, record, started, ok):
        refreshed = record.pop("_token_refreshes", self.token_refreshes)
        if self.token_refreshes != refreshed:
            record["retried"] = True
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
        if "wait_mail" in do:
            return [self._wait_mail(step, do, record)]
        if "parallel" in do:
            return self._parallel(role, do["parallel"], http_as, record)
        if "repeat" in do:
            times = int(substitute(do.get("times", 2), self.ctx))
            return self._repeat(role, do["repeat"], times, http_as, record)
        spec = do["assert_only"] if "assert_only" in do else do
        if "assert_only" in do:
            spec = dict(spec, api="GET")
        info = self._call(role, spec, http_as)
        if "poll" in step:
            info = self._poll_call(step, do, role, spec, http_as, info, record)
        record.update(method=info["method"], path=info["path"])
        if info["request"] is not None:
            record["request"] = info["request"]
        return [info["result"]]

    def _poll_call(self, step, do, role, spec, http_as, info, record):
        """A GET step with `poll`: the same read again until its `expect` holds or `within_s` ran out (the engine
        runs the steps of an instance after the start answer, so a read right after it cannot be final). The last
        answer is the one the step is judged on; `polls` says how often the read ran."""
        conf = substitute(step["poll"], self.ctx)
        within = self._wait_time(conf, "within_s", 60)
        interval = self.poll_interval if self.poll_interval is not None else self._wait_time(conf, "interval_s", 2)
        deadline = time.monotonic() + within
        polls = 1
        while not all(r["ok"] for r in self._assert_calls(step, do, [info["result"]], False)):
            if time.monotonic() >= deadline:
                break
            time.sleep(interval)
            info = self._call(role, spec, http_as)
            polls += 1
        record["polls"] = polls
        return info

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

    # -- wait_mail (G18) -------------------------------------------------------------------------

    def _wait_mail(self, step, do, record):
        """Wait for a mail to the recipient with the subject, in the mail trap.

        The trap is asked by recipient only: the subject is matched by the runner, so a mail with the subject
        and another one with a similar subject cannot be confused. The body of a mail is never read into the
        log: only the recipient, the subject and the id of the message that matched.

        The recipient is a personal datum and the trap address may carry a credential: neither of them is
        written in clear text into a record or an error. The recipient is masked (its shape stays visible),
        the address is written without its userinfo, its query and its fragment."""
        spec = substitute(do["wait_mail"], self.ctx)
        recipient = str(spec.get("recipient") or "").strip()
        subject = str(spec.get("subject") or "")
        if not recipient or not subject:
            raise RunnerError("wait_mail needs a recipient and a subject")
        trap = str(spec.get("trap_url") or self.mail_trap_url or "").rstrip("/")
        why = trap_problem(trap)
        if why:
            raise RunnerError(f"wait_mail: {why}")
        shown = mask_mail_recipient(recipient)
        contains = bool(spec.get("subject_contains"))
        within = self._wait_time(spec, "within_s", 60)
        interval = self.poll_interval if self.poll_interval is not None else self._wait_time(spec, "interval_s", 2)
        deadline = time.monotonic() + within
        polls, message_id, problem = 0, None, None
        while True:
            polls += 1
            message_id, problem = self._find_mail(trap, recipient, subject, contains)
            if message_id:
                break
            if time.monotonic() >= deadline:
                detail = f" ({problem})" if problem else ""
                raise RunnerError(f"timeout: no mail to {shown} with the subject {subject!r} "
                                  f"in {within:g} s, {polls} polls{detail}")
            time.sleep(interval)
        record.update(method="GET", path=log_safe_url(f"{trap}/api/v1/search"), polls=polls,
                      mail_to=shown, mail_subject=subject, mail_id=message_id)
        answer = {"to": shown, "subject": subject, "message_id": message_id}
        return 200, answer, json.dumps(answer, ensure_ascii=False)

    @staticmethod
    def _wait_time(spec, key, default):
        """The wait time of a wait_mail step: a number, or the number a ${name} of the context gave. A value that
        is no number is a step error, never a crash."""
        if key not in spec:
            return float(default)
        value = spec[key]
        try:
            number = float(value)
        except (TypeError, ValueError):
            raise RunnerError(f"wait_mail {key} must be a number, got {value!r}") from None
        if not math.isfinite(number):
            raise RunnerError(f"wait_mail {key} must be a finite number, got {value!r}")
        return number

    def _find_mail(self, trap, recipient, subject, contains=False):
        """-> (message id, None) when the trap holds a mail to the recipient with the subject; (None, why) otherwise.

        The search answer is a summary of every mail to the recipient: its subject and its addresses are read
        from there. A summary that carries neither is not enough, and the message itself is read (its subject
        and its addresses, never its body)."""
        query = urllib.parse.quote(f"to:{recipient}", safe="")
        url = f"{trap}/api/v1/search?query={query}&limit={MAIL_SEARCH_LIMIT}"
        try:
            status, body, _ = http_call("GET", url, {}, None, timeout=MAIL_TRAP_TIMEOUT_S)
        except RunnerError as err:
            return None, f"the mail trap is not reachable ({err})"
        if status != 200 or not isinstance(body, dict):
            return None, f"the mail trap answered {status}"
        for row in body.get("messages") or []:
            if not isinstance(row, dict):
                continue
            message_id = str(row.get("ID") or row.get("id") or "")
            if not message_id:
                continue
            addresses = self._mail_addresses(row)
            found = row.get("Subject", row.get("subject"))
            if not addresses or found is None:
                message = self._mail_message(trap, message_id)
                if message is None:
                    continue
                addresses = addresses or self._mail_addresses(message)
                found = found if found is not None else message.get("Subject", message.get("subject"))
            if recipient.strip().lower() not in addresses:
                continue
            if found is None:
                continue
            if self._subject_matches(str(found), subject, contains):
                return message_id, None
        return None, "the trap holds no such mail"

    def _mail_message(self, trap, message_id):
        """One message of the trap; only its subject and its addresses are read, never its body."""
        url = f"{trap}/api/v1/message/{urllib.parse.quote(message_id, safe='')}"
        try:
            status, body, _ = http_call("GET", url, {}, None, timeout=MAIL_TRAP_TIMEOUT_S)
        except RunnerError:
            return None
        if status != 200 or not isinstance(body, dict):
            return None
        return body

    @staticmethod
    def _mail_addresses(row) -> list:
        """The addresses of a mail of the trap: a list of {Address} or of plain addresses."""
        to = row.get("To") if row.get("To") is not None else row.get("to")
        if not isinstance(to, list):
            return []
        out = []
        for entry in to:
            address = entry.get("Address", entry.get("address")) if isinstance(entry, dict) else entry
            if isinstance(address, str):
                out.append(address.strip().lower())
        return out

    @staticmethod
    def _subject_matches(have: str, want: str, contains: bool) -> bool:
        if contains:
            return want.strip() in have
        return have.strip() == want.strip()

    def _inbox_page(self, role, cursor=None):
        """The inbox endpoint used by wait_task; residue uses the status-filtered task list instead."""
        path = "/api/v1/tasks/inbox?page_size=200" + (f"&cursor={cursor}" if cursor else "")
        return self.request(role, "GET", path)

    def _find_task(self, role, doc, node):
        """The id of a PENDING task `node` whose instance carries variables.document_id == doc."""
        cursor, problem = None, None
        for _ in range(INBOX_PAGES_MAX):
            status, page, _ = self._inbox_page(role, cursor)
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
                if spec.get("optional") and not (json_path(body, spec["pick"])[0] and json_path(body, spec["pick"])[1] is not None):
                    continue  # a look-up that found nothing leaves the name unset (fixtures: "create it then")
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

    def run_process(self, process, isolated=False) -> bool:
        """Run one process and freeze the context of its cleanup. A chain process is isolated: only the
        outputs named by the chain's `pass` list are copied back for later processes. Fixtures are not isolated."""
        shared = self.ctx
        over = self.overrides.get(process["id"])
        work = self._fresh_ctx(over) if over else (dict(shared) if isolated else shared)
        base = set(work)  # the names the process starts with: everything else it creates
        self.ctx = work
        self.process = process
        entry = {"process": process["id"], "cleanup": process.get("cleanup") or [], "ctx": work, "done": False}
        try:
            with self._on(process["id"]):
                if not self._fresh_process_tokens(process):
                    return False
                self.entries.append(entry)
                ok = self._run_process_body(process, isolated, shared, work, entry)
            entry["created"] = [name for name in work if name not in base]
            return ok
        finally:
            self.ctx = shared

    def _run_process_body(self, process, isolated, shared, work, entry):
        for name, value in (process.get("defaults") or {}).items():
            self.ctx.setdefault(name, value)
        self.save_context()
        missing = [n for n in process.get("inputs") or [] if n not in self.ctx]
        steps_ok = True
        if missing:
            steps_ok = False
            self.write_line({"phase": "inputs", "step": "inputs", "actor": "-", "verdict": "error", "ms": 0,
                             "error": "inputs missing: " + ", ".join(missing)})
        failed_step = None
        for step in process["steps"] if steps_ok else []:
            if steps_ok:
                steps_ok = self.run_step(step, "step")
                if not steps_ok:
                    failed_step = step["id"]
            elif blocked_reason(step) or any(n in self.blocked_saves for n in step.get("requires", [])):
                self.run_step(step, "step")  # a blocked step is reported as blocked, whatever failed before it
            else:
                self.write_line({"phase": "step", "step": step["id"], "actor": step.get("actor") or "-",
                                 "verdict": "skipped", "error": f"an earlier step failed ({failed_step})", "ms": 0})
        if steps_ok:
            try:
                for name, expr in (process.get("outputs") or {}).items():
                    self.ctx[name] = substitute(expr, self.ctx)
            except RunnerError as err:
                steps_ok = False
                self.write_line({"phase": "outputs", "step": "outputs", "actor": "-", "verdict": "error",
                                 "error": str(err), "ms": 0})
        entry["ctx"] = dict(self.ctx)  # frozen: this process's cleanup sees the context as it left it
        if steps_ok:
            outputs = {name: self.ctx[name] for name in (process.get("outputs") or {}) if name in self.ctx}
            self.process_outputs.update(outputs)
            if isolated:
                for name in self.pass_map.get(process["id"], []):
                    if name in outputs:
                        shared[name] = outputs[name]
        self.save_context()
        return steps_ok

    def run_fixture(self, fixture) -> bool:
        """A fixture is a process whose steps run first; its cleanup (recorded now) runs after every process's."""
        doc = dict(fixture, id="fixture:" + fixture["id"])
        ok = self.run_process(doc)
        if ok:
            missing = [n for n in fixture.get("provides") or [] if n not in self.ctx]
            if missing:
                ok = False
                self.write_line({"phase": "outputs", "step": "provides", "actor": "-", "verdict": "error", "ms": 0,
                                 "error": "the fixture did not provide: " + ", ".join(missing)})
        return ok

    def cleanup_all(self, skip_cleaned=False) -> bool:
        """Every recorded cleanup, newest process first. A failing step does not stop the next one.
        skip_cleaned: the entries whose cleanup already ran in this run (per_process) are left alone."""
        ok = True
        for entry in reversed(self.entries):
            if skip_cleaned and entry.get("cleaned"):
                continue
            if not entry["done"]:
                ok = self._cleanup_entry(entry) and ok
        return ok

    def _cleanup_of(self, process) -> bool:
        """The cleanup of one process, right after that process (a chain with "cleanup": "per_process"):
        with the frozen context of that process, and without handing its working values to the chain."""
        entry = next((e for e in reversed(self.entries) if e["process"] == process["id"]), None)
        if entry is None:
            return True
        ok = self._cleanup_entry(entry, merge=False)
        self._drop_working_values(process, entry)
        return ok

    def _drop_working_values(self, process, entry):
        """The working values of a process leave the chain context when its cleanup has run: only the
        outputs the chain hands on (`pass`) stay."""
        keep = set(self.pass_map.get(process["id"], []))
        for name in entry.get("created") or []:
            if name not in keep:
                self.ctx.pop(name, None)

    def _cleanup_entry(self, entry, merge=True) -> bool:
        """The cleanup of one process, with the context it left behind. merge: what the cleanup changes
        reaches the chain context (the end-of-chain cleanup); per_process keeps it out of the chain."""
        live, snapshot = self.ctx, entry["ctx"]
        work = dict(snapshot)
        self.ctx, self.process = work, {"id": entry["process"]}
        ok = True
        try:
            with self._on(entry["process"]):
                for step in entry["cleanup"]:
                    ok = self.run_step(step, "cleanup") and ok
        finally:
            if merge:
                for key, value in work.items():
                    if key not in snapshot or snapshot[key] != value:
                        live[key] = value
            self.ctx = live
        entry["done"] = ok
        entry["cleaned"] = True
        self.save_context()
        return ok

    # -- tenant residue check -------------------------------------------------------------------

    def _residue_targets(self) -> dict:
        """tenant -> True of every tenant this run touches whose processes keep the check on."""
        targets = {}
        if not self.residue_check:
            return targets
        own = [p for p in self.processes if p["id"] not in self.overrides]
        if own or self.fixtures:
            if not own or any(p.get("residue_check") is not False for p in own):
                targets[self.tenant] = True
        for pid, over in self.overrides.items():
            proc = next((p for p in self.processes if p["id"] == pid), None)
            if proc is not None and proc.get("residue_check") is not False:
                targets.setdefault(over["tenant"], True)
        return targets

    def _residue_groups(self) -> list:
        """-> the tenants this run touches and what each of them can leave behind.

        A tenant with an "admin" actor holds business data: the document and open-task check.
        A tenant with an actor object may be the platform tenant: the registry check (the throwaway
        tenants) - only when one of its actors may read the tenant registry.
        A process may turn the check off for its own tenant ("residue_check": false)."""
        if not self.residue_check:
            return []
        wanted = self._residue_targets()
        out = []
        for group in self.tenant_groups():
            if not group["actors"]:
                continue
            other = {role: spec for role, spec in group["actors"].items() if spec.get("tenant")}
            if group["tenant"] not in wanted and not other:
                continue  # the process of this tenant turned the check off
            out.append({"tenant": group["tenant"], "base_url": group["base_url"], "actors": group["actors"],
                        # the document check only where the process keeps the check on for the tenant: the
                        # platform tenant holds no business documents (its own check is the platform one)
                        "plain": group["tenant"] in wanted
                        and any(not spec.get("tenant") for spec in group["actors"].values()),
                        "platform": sorted(other, key=lambda r: (0 if "platform" in r else 1, r))})
        return out

    def _registry_of(self, group):
        """-> (role, {slug: status}) of the tenant registry, when an actor of this tenant may read it;
        (None, None) when no actor of this tenant is a platform administrator."""
        for role in group["platform"]:
            tenants = self._platform_tenants(role)
            if tenants is not None:
                return role, tenants
        return None, None

    # -- the platform residue check (G18) --------------------------------------------------------

    def _platform_residue_watch(self) -> dict:
        """-> what the run watches on the platform tenant: {"definitions": [names], "instances": [names]}.

        A run watches nothing until a process says so in a `platform_residue` block; a run that watches
        something watches it on every tenant it touches.

        The watch of a finished run is kept in the run dir (`platform_watch.json`): a cleanup replay judges the
        run it replays, so it must know what that run watched, not only what the replayed cleanup steps say."""
        watch = {"definitions": [], "instances": []}
        for source in (self.platform_watch, self._watch_of_processes()):
            for key in ("definitions", "instances"):
                for name in source.get(key) or []:
                    if name not in watch[key]:
                        watch[key].append(name)
        return watch

    def _watch_of_processes(self) -> dict:
        """-> the watch of the process blocks of this run."""
        watch = {"definitions": [], "instances": []}
        for proc in self.processes:
            block = proc.get("platform_residue") or {}
            for key in ("definitions", "instances"):
                for name in block.get(key) or []:
                    if name not in watch[key]:
                        watch[key].append(name)
        return watch

    def _save_platform_watch(self):
        """Keep the watch of the run and the instances it started in the run dir: the cleanup replay of an
        interrupted run judges that run, so it needs both."""
        self._atomic_write("platform_watch.json", json.dumps(
            {"watch": self.platform_watch, "started": self.started_instances}, indent=2, ensure_ascii=False))

    def _restore_platform_watch(self) -> None:
        """Read the watch and the started instances of the run this replay cleans up."""
        try:
            state = json.loads((self.run_dir / "platform_watch.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        if not isinstance(state, dict):
            return
        watch = state.get("watch")
        if isinstance(watch, dict):
            self.platform_watch = {key: [n for n in (watch.get(key) or []) if isinstance(n, str)]
                                   for key in ("definitions", "instances")}
        self.started_instances = [i for i in (state.get("started") or [])
                                  if isinstance(i, dict) and isinstance(i.get("instance_id"), str)]

    def _definition_baseline(self, group, watch) -> dict:
        """-> {"role": ..., "active": {name: [ids of the active version rows]}} of the platform tenant, read by an
        actor of that tenant that may read the definitions. An actor that may not is not the reader: the next one is."""
        names = watch["definitions"]
        if not names:
            return None
        role = None
        for candidate in group["platform"]:
            status, _, _ = self.request(candidate, "GET", "/api/v1/definitions?status=active&page_size=1")
            if status != 403:
                role = candidate
                break
        if role is None:
            raise RunnerError("no actor of this tenant may read the definitions")
        return {"role": role, "active": {name: self._active_definitions(role, name) for name in names}}

    def _active_definitions(self, role, name) -> list:
        """-> the ids of the ACTIVE version rows of the definition `name` of the current tenant.

        The id of the row is the version: a rollback activates the row it had before, so the id of the active
        row is what tells whether the definition is back on its previous version."""
        ids, cursor = [], None
        while True:
            path = "/api/v1/definitions?status=active&page_size=100"
            if name:
                path += "&name=" + urllib.parse.quote(name, safe="")
            if cursor:
                path += "&cursor=" + urllib.parse.quote(cursor, safe="")
            status, body, _ = self.request(role, "GET", path)
            if status != 200 or not isinstance(body, dict):
                raise RunnerError(f"the definitions list answered {status}")
            for row in body.get("items") or []:
                if isinstance(row, dict) and str(row.get("name") or "") == name and row.get("id") is not None:
                    ids.append(str(row["id"]))
            cursor = body.get("next_cursor")
            if not cursor:
                return sorted(ids)

    def _instance_status(self, role, instance_id):
        """-> the status of one instance of the current tenant; None when it does not exist."""
        path = f"/api/v1/instances/{urllib.parse.quote(str(instance_id), safe='')}"
        status, body, _ = self.request(role, "GET", path)
        if status == 404:
            return None
        if status != 200 or not isinstance(body, dict):
            raise RunnerError(f"the instance {instance_id} answered {status}")
        return str(body.get("status") or "")

    def _watched_instances(self, tenant, watch) -> list:
        """-> the instances of the platform tenant the run watches: the ones it started and the ones the
        `platform_residue` block names."""
        out = []
        for entry in self.started_instances:
            if entry["tenant"] == tenant and entry["instance_id"] not in [i["instance_id"] for i in out]:
                out.append(entry)
        for name in watch["instances"]:
            if self._blocked_names(name):
                continue  # the step that saves it was never run (blocked): there is no instance to watch
            try:
                instance_id = str(substitute(name, self._watch_context()))
            except RunnerError:
                raise RunnerError(f"the platform_residue block names an unknown instance: {name}") from None
            if instance_id and instance_id not in [i["instance_id"] for i in out]:
                out.append({"instance_id": instance_id, "tenant": tenant, "base_url": None, "role": None})
        return out

    def _watch_context(self) -> dict:
        """The names a `platform_residue` block may read: the final context and the frozen context of every
        process of the run (a process of a chain keeps its own names)."""
        ctx = dict(self.ctx)
        for entry in self.entries:
            for key, value in (entry.get("ctx") or {}).items():
                ctx.setdefault(key, value)
        return ctx

    def _platform_residue_of(self, tenant, before, watch) -> list:
        """-> the residue of the platform tenant: a watched definition that is not on the version it had before
        the run, and an instance of the run that is still open."""
        found = []
        definitions = before.get("definitions") or {}
        for name, ids in (definitions.get("active") or {}).items():
            now = self._active_definitions(definitions["role"], name)
            if now != ids:
                found.append(f"definition {name} was on the version {', '.join(ids) or 'none'} before the run, "
                             f"it is on the version {', '.join(now) or 'none'} now")
        if watch["definitions"] or watch["instances"]:
            for entry in self._watched_instances(tenant, watch):
                role = entry.get("role") or before["role"]
                status = self._instance_status(role, entry["instance_id"])
                if status and status.upper() == "ACTIVE":
                    found.append(f"instance {entry['instance_id']} is still open ({status})")
        return found

    @contextlib.contextmanager
    def _switch(self, tenant, base_url, actors):
        keep = (self.tenant, self.base_url, self.actors)
        try:
            actors = normalize_actors(actors or {}, "the actors of this tenant")
        except ConfigError as err:
            raise RunnerError(str(err)) from None
        self.tenant, self.base_url, self.actors = tenant, base_url, actors
        try:
            yield
        finally:
            self.tenant, self.base_url, self.actors = keep

    def _open_tasks(self):
        """Open task ids, without paging closed history. An expired cursor restarts the whole listing at most
        three times; partial ids from the abandoned attempt must not survive into the baseline."""
        tasks, cursor, restarts = set(), None, 0
        while True:
            path = "/api/v1/tasks?status=PENDING&page_size=200" + (f"&cursor={cursor}" if cursor else "")
            status, body, _ = self.request("admin", "GET", path)
            if status == 410 and cursor:
                if restarts >= RESIDUE_CURSOR_RESTARTS:
                    raise RunnerError(f"open tasks answered 410 after {restarts} pagination restarts")
                restarts += 1
                tasks, cursor = set(), None
                continue
            if status != 200 or not isinstance(body, dict):
                raise RunnerError(f"open tasks answered {status}")
            for item in body.get("items") or []:
                if isinstance(item, dict) and item.get("id") is not None and str(item.get("status", "PENDING")).upper() == "PENDING":
                    tasks.add(str(item["id"]))
            cursor = body.get("next_cursor")
            if not cursor:
                return sorted(tasks)

    def _snapshot(self):
        """-> (non-final documents with their state, open task ids) of the current tenant as admin; (None, why) when
        there is no admin or the document list is absent/refused. The caller fails the run on every unreadable snapshot."""
        if "admin" not in self.actors:
            return None, "no admin actor for this tenant"
        docs, cursor = {}, None
        while len(docs) < RESIDUE_DOC_LIMIT:
            path = f"/api/v1/modules/stock/documents?limit=100" + (f"&cursor={cursor}" if cursor else "")
            status, body, _ = self.request("admin", "GET", path)
            if status in (403, 404):
                return None, f"documents list answered {status}"
            if status != 200 or not isinstance(body, dict):
                raise RunnerError(f"documents list answered {status}")
            for row in body.get("rows") or []:
                if (isinstance(row, dict) and row.get("id") is not None
                        and str(row.get("state")) not in RESIDUE_FINAL_STATES):
                    docs[str(row["id"])] = {"number": row.get("number"), "kind": row.get("kind"), "state": row.get("state")}
            cursor = body.get("next_cursor")
            if not cursor or not body.get("rows"):
                break
        return docs, self._open_tasks()

    def _platform_tenants(self, role):
        """-> {slug: status} of the tenants of the registry, as the platform administrator sees them;
        None when this actor may not read it (a tenant administrator: there is no platform registry)."""
        tenants, cursor = {}, None
        while True:
            path = TENANT_REGISTRY_PATH + (f"?cursor={urllib.parse.quote(cursor)}" if cursor else "")
            status, body, _ = self.request(role, "GET", path)
            if status == 403:
                return None
            if status != 200 or not isinstance(body, dict):
                raise RunnerError(f"the tenant registry answered {status}")
            for row in body.get("items") or []:
                if isinstance(row, dict) and isinstance(row.get("slug"), str):
                    tenants[row["slug"]] = str(row.get("status") or "")
            cursor = body.get("next_cursor")
            if not cursor:
                return tenants

    def _residue_line(self, verdict, started, error=None, step="tenant residue check"):
        record = {"ts": now_utc(), "phase": "residue", "step": step, "actor": "admin", "verdict": verdict,
                  "ms": int((time.monotonic() - started) * 1000), "process": self.label}
        if error:
            record["error"] = error
        self.write_line(record)
        return verdict not in ("fail", "error")

    def record_residue_baseline(self) -> bool:
        """Before the first process: record the existing documents and open tasks of every tenant the run touches,
        and the throwaway platform tenants that exist already. An unreadable baseline is a failing residue row,
        never a skipped check: without it no later listing can prove that the run was clean.

        A run that watches the platform (a `platform_residue` block) also records the active version of the
        definitions it names: the run must leave them on the version they had."""
        ok = True
        watch = self._platform_residue_watch()
        watched = bool(watch["definitions"] or watch["instances"])
        self.platform_watch = watch
        unreadable = []
        for group in self._residue_groups():
            tenant = group["tenant"]
            started = time.monotonic()
            if group["platform"]:
                try:
                    with self._switch(tenant, group["base_url"], group["actors"]):
                        role, tenants = self._registry_of(group)
                        definitions = self._definition_baseline(group, watch) if tenants is not None else None
                except RunnerError as err:
                    ok = self._residue_line("fail", started, f"baseline unavailable: tenant {tenant}: {err}") and ok
                    continue
                if tenants is not None:
                    self.platform_before[tenant] = {"base_url": group["base_url"], "actors": group["actors"],
                                                    "role": role,
                                                    "tenants": {slug: status for slug, status in tenants.items()
                                                                if slug.startswith(PLATFORM_TENANT_PREFIX)}}
                    if definitions is not None:
                        self.platform_before[tenant]["definitions"] = definitions
                elif watched:
                    # This group's actors may not read the registry. That is not a failure of the run: another
                    # group of the run may be the platform tenant and may read it. Only a run in which NO group
                    # can read the registry cannot watch the platform tenant (the check below).
                    unreadable.append(tenant)
            if not group["plain"]:
                continue  # a tenant with only actor objects: the platform check above is its check
            started = time.monotonic()
            try:
                with self._switch(tenant, group["base_url"], group["actors"]):
                    docs, tasks = self._snapshot()
            except RunnerError as err:
                ok = self._residue_line("fail", started, f"baseline unavailable: tenant {tenant}: {err}") and ok
                continue
            if docs is None:
                ok = self._residue_line("fail", started, f"baseline unavailable: tenant {tenant}: {tasks}") and ok
                continue
            self.residue_before[tenant] = {"base_url": group["base_url"], "actors": group["actors"],
                                            "docs": docs, "tasks": tasks}
        if watched and not self.platform_before:
            started = time.monotonic()
            where = f" (tenant {', '.join(unreadable)})" if unreadable else ""
            ok = self._residue_line("fail", started, "baseline unavailable: the tenant registry is not readable"
                                  f"{where}, no actor of this run reads the platform tenant, the run cannot "
                                  "watch it") and ok
        if self.residue_before:
            self._atomic_write("residue_before.json", json.dumps(self.residue_before, indent=2, ensure_ascii=False))
        if self.platform_before:
            self._atomic_write("platform_before.json", json.dumps(self.platform_before, indent=2, ensure_ascii=False))
        if watched:
            self._save_platform_watch()
        return ok

    def check_residue(self) -> bool:
        """After the last cleanup: every document or open task that was not there before the run is residue, unless
        the document is in a final state (reversed, cancelled, rejected), and every throwaway platform tenant the
        run left active is residue. A run that watches the platform also fails when a watched definition is not on
        its previous version or when an instance of the run is left open. One row for the run; it fails on residue.
        A baseline the replay cannot find is residue it cannot judge: the row fails (G-08)."""
        started = time.monotonic()
        if not self.residue_before and not self.platform_before and not self.baseline_problems:
            return True  # an unreadable baseline already wrote its failing row (or the check is off)
        found, failed, platform = [], list(self.baseline_problems), []
        watch = self._platform_residue_watch()
        for tenant, before in self.residue_before.items():
            try:
                with self._switch(tenant, before["base_url"], before["actors"]):
                    docs, tasks = self._snapshot()
            except RunnerError as err:
                failed.append(f"final listing unavailable: tenant {tenant}: {err}")
                continue
            if docs is None:
                failed.append(f"final listing unavailable: tenant {tenant}: {tasks}")
                continue
            for doc_id, doc in docs.items():
                if doc_id not in before["docs"] and str(doc.get("state")) not in RESIDUE_FINAL_STATES:
                    found.append(f"{tenant}: document {doc.get('number') or doc_id} ({doc.get('kind')}, state {doc.get('state')}, id {doc_id})")
            for task_id in tasks:
                if task_id not in before["tasks"]:
                    found.append(f"{tenant}: open task {task_id}")
        for tenant, before in self.platform_before.items():
            try:
                with self._switch(tenant, before["base_url"], before["actors"]):
                    tenants = self._platform_tenants(before["role"])
                    if tenants is None:
                        raise RunnerError("the tenant registry is not readable")
                    platform += self._platform_residue_of(tenant, before, watch)
            except RunnerError as err:
                failed.append(f"final listing unavailable: tenant {tenant}: {err}")
                continue
            for slug, status in tenants.items():
                if not slug.startswith(PLATFORM_TENANT_PREFIX) or slug == PLATFORM_FIXTURE_TENANT:
                    continue  # the fixed fixture tenant is never residue
                if slug in before["tenants"]:
                    continue  # it existed before the run
                if str(status) in PLATFORM_TENANT_FINAL_STATUSES:
                    continue  # a deactivated tenant is final
                platform.append(f"leftover platform tenant {slug}")
        if not found and not failed and not platform:
            return self._residue_line("pass", started)
        parts = []
        if found:
            parts.append("residue left by the run: " + "; ".join(found))
        parts += platform + failed
        return self._residue_line("fail", started, "; ".join(parts))

    # -- the safety checks of a run and of its cleanup replay (G-08) ----------------------------

    def _build_check(self, sha_start, sha_end) -> bool:
        """The build must not move while the runner works: a step that ran against another build is no result of
        this one. One row, whether it passed or failed, so a reader sees that the check was made."""
        moved = sha_end != sha_start
        row = {"phase": "preflight", "step": "build", "actor": "-", "verdict": "fail" if moved else "pass",
               "sha": sha_end, "ms": 0}
        if moved:
            row["error"] = f"build moved: {sha_start} -> {sha_end}"
        self.write_line(row)
        return not moved

    def _save_safety_expectations(self):
        """What the cleanup replay of this run has to judge: the baselines it must find and the platform watch
        it must keep. A replay without them cannot say whether the run was clean, so it fails closed."""
        groups = self._residue_groups()
        self._atomic_write("safety.json", json.dumps({
            "residue_tenants": sorted({g["tenant"] for g in groups if g["plain"]}),
            "platform_tenants": sorted(self.platform_before),
            "watch": self._platform_residue_watch(),
        }, indent=2, ensure_ascii=False))

    def _replay_baseline_problems(self) -> list:
        """What the replay of this run cannot judge: the run dir does not say what the run did, or a baseline the
        run promised is gone. Every answer here is a failing residue row, never a skipped check."""
        try:
            state = json.loads((self.run_dir / "safety.json").read_text(encoding="utf-8"))
        except (OSError, ValueError) as err:
            return [f"the run dir has no safety expectations ({err}): the replay cannot judge the run"]
        if not isinstance(state, dict):
            return ["the safety expectations of the run are not an object: the replay cannot judge the run"]
        problems = []
        for tenant in state.get("residue_tenants") or []:
            if tenant not in self.residue_before:
                problems.append(f"the residue baseline of tenant {tenant} is gone: the replay cannot judge the run")
        for tenant in state.get("platform_tenants") or []:
            if tenant not in self.platform_before:
                problems.append(f"the platform baseline of tenant {tenant} is gone: the replay cannot judge the run")
        promised = self._watch_names(state.get("watch") or {})
        if promised:
            if not self.platform_before:
                problems.append("the run watched the platform tenant but no platform baseline is there: "
                                "the replay cannot judge the run")
            if promised != self._watch_names(self.platform_watch):
                problems.append("the platform watch of the run is gone: the replay cannot judge the run")
        return problems

    @staticmethod
    def _watch_names(watch) -> list:
        """The names a platform watch holds, in the order of the watch."""
        names = []
        for key in ("definitions", "instances"):
            for name in (watch or {}).get(key) or []:
                names.append(f"{key}:{name}")
        return names

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
        cleanup_ok = True
        residue_ok = self.record_residue_baseline()
        self._save_safety_expectations()  # what a cleanup replay of this run has to judge (G-08)
        try:
            for fixture in self.fixtures:
                if stopped:
                    self.process = {"id": "fixture:" + fixture["id"]}
                    self.write_line({"phase": "step", "step": "-", "actor": "-", "verdict": "skipped", "ms": 0,
                                     "error": "an earlier fixture failed"})
                    continue
                results["fixture:" + fixture["id"]] = self.run_fixture(fixture)
                stopped = not results["fixture:" + fixture["id"]]
            for process in self.processes:
                if stopped:
                    self.process = process
                    self.write_line({"phase": "step", "step": "-", "actor": "-", "verdict": "skipped", "ms": 0,
                                     "error": "an earlier process failed"})
                    results[process["id"]] = None
                    continue
                results[process["id"]] = self.run_process(process, isolated=len(self.processes) > 1)
                if self.cleanup_mode == "per_process":
                    # the cleanup of this process runs now, with its own context; a failing cleanup
                    # fails the process and the run, but the next processes still run
                    cleanup_ok = self._cleanup_of(process) and cleanup_ok
                stopped = not results[process["id"]] and not self.keep_going
            # The final context is a report of the run. These outputs were not visible to later processes
            # unless their `pass` list copied them into the shared context above.
            self.ctx.update(self.process_outputs)
            self.save_context()
        finally:
            cleanup_ok = self.cleanup_all(skip_cleaned=self.cleanup_mode == "per_process") and cleanup_ok
        self.process = {"id": self.label}
        sha_end = health_sha(self.health_url)
        build_ok = self._build_check(sha_start, sha_end)
        build_moved = not build_ok
        residue_ok = self.check_residue() and residue_ok
        steps_ok = all(v is True for v in results.values())
        if self.file_issues:
            self._file_issues()
        self.save_context()
        ok = steps_ok and cleanup_ok and residue_ok and not build_moved
        self._summary(started_at, sha_start, sha_end, steps_ok, cleanup_ok, build_moved, residue_ok=residue_ok)
        print(f"{self.label}: {'PASS' if ok else 'FAIL'} (run dir {self.run_dir})", file=self.out, flush=True)
        return 0 if ok else 1

    def replay_cleanup(self) -> int:
        """Run the cleanup list of an aborted run again (cleanup.json of the run directory).

        The replay judges the run it cleans up, so it makes the same safety checks as the run itself (G-08):
        the preflight of every tenant the run touched, the build that must not move while the replay works and
        the residue check. A baseline the run promised and that is gone is a failing residue row, never a
        skipped check."""
        try:
            entries = json.loads((self.run_dir / "cleanup.json").read_text(encoding="utf-8"))
        except (OSError, ValueError) as err:
            print(f"runner.py: cannot read {self.run_dir}/cleanup.json: {err}", file=sys.stderr)
            return 2
        self.entries = [e for e in entries if isinstance(e, dict) and "cleanup" in e]
        self.replay = True
        try:  # an interrupted run left its baseline: the replay compares against it
            before = json.loads((self.run_dir / "residue_before.json").read_text(encoding="utf-8"))
            self.residue_before = before if isinstance(before, dict) else {}
        except (OSError, ValueError):
            self.residue_before = {}
        try:
            platform = json.loads((self.run_dir / "platform_before.json").read_text(encoding="utf-8"))
            self.platform_before = platform if isinstance(platform, dict) else {}
        except (OSError, ValueError):
            self.platform_before = {}
        # The run this replay cleans up watched the platform tenant and started instances: the replay judges
        # that run, so it reads the watch of the run from the run dir.
        self._restore_platform_watch()
        # What the run promised the replay (G-08): without it the replay cannot judge the run.
        self.baseline_problems = self._replay_baseline_problems()
        started_at = now_utc()
        self.label = f"cleanup of {self.run_dir.name}"
        self.process = {"id": "cleanup"}
        self.processes = [{"id": e["process"], "steps": [], "cleanup": e["cleanup"]} for e in self.entries]
        pre_ok, sha = self.preflight(check_stable=False, subject="the replay")
        if not pre_ok:
            self._summary(started_at, sha, sha, False, True, False, name="summary-cleanup.md", residue_ok=False)
            print(f"cleanup of {self.run_dir}: FAIL (preflight; run dir {self.run_dir})", file=self.out, flush=True)
            return 1
        ok = self.cleanup_all()
        sha_end = health_sha(self.health_url)
        build_ok = self._build_check(sha, sha_end)
        residue_ok = self.check_residue()
        left = [e["process"] for e in self.entries if not e["done"]]
        self._summary(started_at, sha, sha_end, True, ok, not build_ok, name="summary-cleanup.md", residue_ok=residue_ok)
        ok = ok and residue_ok and build_ok
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

    def _summary(self, started_at, sha_start, sha_end, steps_ok, cleanup_ok, build_moved, name="summary.md", residue_ok=True):
        ok = steps_ok and cleanup_ok and residue_ok and not build_moved and sha_start is not None
        first = next((r for r in self.records if r.get("verdict") in ("fail", "error")), None)
        lines = [
            f"# UAT run {self.label}",
            "",
            f"- run id: {self.run_id}",
            f"- tenant: {self.tenant}   base url: {self.base_url}",
            f"- started: {started_at}   duration: {int((time.monotonic() - self.started_mono) * 1000)} ms",
            f"- build sha at start: {sha_start}   at end: {sha_end}" + ("   **build moved: the run fails**" if build_moved else ""),
            f"- steps: {'pass' if steps_ok else 'FAIL'}   cleanup: {'pass' if cleanup_ok else 'FAIL'}",
            f"- cleanup mode: {self.cleanup_mode}",
            f"- tenant residue: {'pass' if residue_ok else 'FAIL'}",
            f"- steps not run (blocked_by): {sum(1 for r in self.records if r.get('verdict') == 'blocked')}",
            f"- verdict: **{'PASS' if ok else 'FAIL'}**"
            + (f" ({sum(1 for r in self.records if r.get('verdict') == 'blocked')} steps NOT RUN, blocked)"
               if any(r.get('verdict') == 'blocked' for r in self.records) else ""),
        ]
        if first:
            what = f"{first.get('process', '')} {first.get('phase', '')} {first.get('step', '')}".strip()
            lines += ["", f"> **FIRST FAILING STEP: {what}** - {first.get('error', first.get('verdict'))}"]
        lines += ["", "## Processes", "", "| process | tenant | verdict | steps | cleanup | duration ms | first failing step |",
                  "|---|---|---|---|---|---|---|"]
        for pid in dict.fromkeys(r["process"] for r in self.records if r.get("phase") in ("step", "cleanup", "inputs", "outputs")):
            mine = [r for r in self.records if r.get("process") == pid and r.get("phase") in ("step", "cleanup", "inputs", "outputs")]
            bad = [r for r in mine if r.get("verdict") in ("fail", "error")]
            bad_steps = [r for r in bad if r["phase"] != "cleanup"]
            bad_clean = [r for r in bad if r["phase"] == "cleanup"]
            skipped = bool(mine) and all(r.get("verdict") == "skipped" for r in mine)
            verdict = "SKIPPED" if skipped else ("FAIL" if bad else "pass")
            lines.append(f"| {pid} | {self.process_tenants.get(pid, '')} | {verdict} | {'FAIL' if bad_steps else ('skipped' if skipped else 'pass')} | "
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
        cleanups = [r for r in self.records if r.get("phase") == "cleanup"]
        if cleanups:
            lines += ["", "## Cleanup (the order it ran)", "", "| # | process | step | verdict | note |",
                      "|---|---|---|---|---|"]
            for number, r in enumerate(cleanups, 1):
                lines.append(f"| {number} | {r.get('process', '')} | {r.get('step', '')} | {r.get('verdict', '')} | "
                             f"{str(r.get('error', '')).replace('|', '/')} |")
        outputs = {}
        for p in self.processes:
            outputs.update({k: self.ctx.get(k) for k in (p.get("outputs") or {}) if k in self.ctx})
        lines += ["", "## Outputs", "", "```json", json.dumps(redact(outputs), indent=2, default=str), "```", ""]
        for key in ("balance_before", "balance_after", "balance_end"):
            if key in self.ctx:
                lines.append(f"- {key}: {self.ctx[key]}")
        if self.issues:
            lines += ["", "## Issues", ""] + [f"- {pid}: {url}" for pid, url in self.issues.items()]
        lines += ["", "## Context at the end", "", "```json", json.dumps(redact(self.ctx), indent=2, default=str, ensure_ascii=False), "```", ""]
        (self.run_dir / name).write_text(self.scrub("\n".join(lines) + "\n"), encoding="utf-8")


# -- loading ------------------------------------------------------------------------------------

PLACEHOLDER_LITERAL = re.compile(r"REPLACE-WITH-[A-Za-z0-9_-]+")


def refuse_placeholders(text: str, source) -> None:
    """A manual fill-in marker must never reach QA as a real request value (exit 2 / a static problem)."""
    match = PLACEHOLDER_LITERAL.search(text)
    if match:
        raise ConfigError(f"{source}: placeholder {match.group()!r} is not allowed; use an input or a fixture")


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
    elif kind == "wait_mail":
        spec = do["wait_mail"]
        if not isinstance(spec, dict) or not all(isinstance(spec.get(key), str) and spec.get(key).strip()
                                                  for key in ("recipient", "subject")):
            raise ConfigError(f"{where}: wait_mail needs a recipient and a subject")
        for key in ("within_s", "interval_s"):
            if key in spec and not wait_time_ok(spec[key]):
                raise ConfigError(f"{where}: wait_mail {key} must be a number "
                                  "(a ${name} of the context is read as one)")
        if "trap_url" in spec and not isinstance(spec["trap_url"], str):
            raise ConfigError(f"{where}: wait_mail trap_url must be a text")
        if isinstance(spec.get("trap_url"), str) and spec["trap_url"].strip():
            why = trap_problem(spec["trap_url"].strip().rstrip("/"))
            if why:
                raise ConfigError(f"{where}: wait_mail {why}")
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
    if "poll" in step:
        conf = step["poll"]
        if kind not in ("api", "assert_only") or not isinstance(conf, dict) or (
                kind == "api" and str(do["api"]).upper() != "GET") or "expect" not in step:
            raise ConfigError(f"{where}: poll is an object on a GET step with an expect")
        for key in ("within_s", "interval_s"):
            if key in conf and not wait_time_ok(conf[key]):
                raise ConfigError(f"{where}: poll {key} must be a number")
    for key in ("requires", "skip_if"):
        if key in step and not (isinstance(step[key], list) and all(isinstance(n, str) for n in step[key])):
            raise ConfigError(f"{where}: {key} is a list of names")
    if "blocked_by" in step and not (isinstance(step["blocked_by"], str) and step["blocked_by"].strip()):
        raise ConfigError(f"{where}: blocked_by is a non-empty text (what the step waits for)")
    if "refusal_probe" in step and step["refusal_probe"] is not True:
        raise ConfigError(f"{where}: refusal_probe can only be true")
    if "refusal_probe" in step and "expect_refused" not in step:
        raise ConfigError(f"{where}: refusal_probe belongs on an expect_refused step")
    if "http_as" in step and step["http_as"] != "shared_access":
        raise ConfigError(f"{where}: http_as can only be shared_access")
    if "http_as" not in step and not step.get("actor"):
        raise ConfigError(f"{where}: every step needs id, actor and do")
    if "expect_refused" in step and "expect" in step:
        raise ConfigError(f"{where}: give expect or expect_refused, not both")


def validate_platform_residue(doc, where) -> None:
    """The `platform_residue` block of a process: what the run watches on the platform tenant (G18)."""
    block = doc.get("platform_residue")
    if block is None:
        return
    if not isinstance(block, dict):
        raise ConfigError(f"{where}: platform_residue must be an object")
    unknown = set(block) - {"definitions", "instances"}
    if unknown:
        raise ConfigError(f"{where}: platform_residue has unknown keys: " + ", ".join(sorted(unknown)))
    for key in ("definitions", "instances"):
        value = block.get(key)
        if value is None:
            continue
        if not isinstance(value, list) or not all(isinstance(v, str) and v.strip() for v in value):
            raise ConfigError(f"{where}: platform_residue.{key} must be a list of names")


def load_process(path) -> dict:
    try:
        text = Path(path).read_text(encoding="utf-8")
        refuse_placeholders(text, path)
        process = json.loads(text)
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
    validate_platform_residue(process, f"process {process['id']}")
    return process


FIXTURE_KEYS = ("description", "leaves", "provides")


def fixtures_dir_for(path) -> Path:
    """test/uat/processes/X.json and test/uat/chains/X.json both keep their fixtures in test/uat/fixtures."""
    return Path(path).resolve().parent.parent / "fixtures"


def load_fixture(path) -> dict:
    """A fixture file: a process-like file (steps, cleanup, inputs) plus `description`, `leaves` (what stays if
    the cleanup cannot remove it), `provides` (the context names it saves) and optional `needs` (fixtures
    that run before it)."""
    doc = load_process(path)
    name = Path(path).stem
    if doc["id"] != name:
        raise ConfigError(f"fixture {name}: id must be the file name ({doc['id']!r})")
    for key in ("description", "leaves"):
        if not isinstance(doc.get(key), str) or not doc[key].strip():
            raise ConfigError(f"fixture {name}: {key} is needed (a sentence)")
    for key in ("provides", "needs"):
        value = doc.get(key, [] if key == "needs" else None)
        if not isinstance(value, list) or not all(isinstance(n, str) for n in value) or (key == "provides" and not value):
            raise ConfigError(f"fixture {name}: {key} must be a list of names" + (" (not empty)" if key == "provides" else ""))
    return doc


def expand_fixtures(names, fixtures_dir, loaded=None, _stack=()) -> list:
    """Fixture names -> fixture documents in run order: the `needs` of a fixture first, each fixture once per run.
    An unknown name is a ConfigError (exit 2: nothing runs)."""
    loaded = {} if loaded is None else loaded
    for name in names:
        if name in loaded:
            continue
        if name in _stack:
            raise ConfigError("fixtures: a cycle through " + " -> ".join(_stack + (name,)))
        file = Path(fixtures_dir) / (str(name) + ".json")
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", name) or not file.is_file():
            raise ConfigError(f"fixtures: unknown fixture {name!r} (no {file})")
        doc = load_fixture(file)
        expand_fixtures(doc.get("needs") or [], fixtures_dir, loaded, _stack + (name,))
        loaded[name] = doc
    return list(loaded.values())


def fixtures_for(processes, fixtures_dir) -> list:
    names = []
    for p in processes:
        value = p.get("fixtures") or []
        if not isinstance(value, list) or not all(isinstance(n, str) for n in value):
            raise ConfigError(f"{p['id']}: fixtures is a list of fixture names")
        names += value
    return expand_fixtures(names, fixtures_dir)


def load_chain(path) -> tuple:
    """-> (chain document, [process documents]). `processes` are names resolved in ../processes (with or
    without .json, or a stem such as BP-01), or paths relative to the chain file."""
    try:
        text = Path(path).read_text(encoding="utf-8")
        refuse_placeholders(text, path)
        chain = json.loads(text)
    except (OSError, ValueError) as err:
        raise ConfigError(f"cannot read chain file {path}: {err}") from None
    names = chain.get("processes") if isinstance(chain, dict) else None
    if not chain.get("id") or not isinstance(names, list) or not names:
        raise ConfigError("a chain file needs an id and a non-empty processes list")
    mode = chain.get("cleanup", "end")
    if mode not in CLEANUP_MODES:
        raise ConfigError(f"chain: cleanup must be one of {', '.join(CLEANUP_MODES)}, got {mode!r}")
    here = Path(path).resolve().parent
    processes = []
    for entry in names:
        if isinstance(entry, dict):
            if not isinstance(entry.get("process"), str) or not entry["process"]:
                raise ConfigError("chain: an object entry needs a process name")
            name = entry["process"]
        else:
            name = entry
        found = resolve_process_file(here, str(name))
        process = load_process(found)
        why = blocked_reason(process)
        if why:
            print(f"chain: SKIPPED {process['id']}: blocked_by {why} (never run)", flush=True)
            continue
        processes.append(process)
    if not processes:
        raise ConfigError("every process of the chain is blocked_by something: nothing to run")
    ids = [p["id"] for p in processes]
    if len(set(ids)) != len(ids):
        raise ConfigError("a process appears twice in the chain: " + ", ".join(sorted({i for i in ids if ids.count(i) > 1})))
    validate_pass_map(chain, processes)
    chain_overrides(chain, processes)
    return chain, processes


OVERRIDE_KEYS = ("tenant", "actors", "old_base_url", "base_url", "inputs")


def chain_overrides(chain, processes, base_url_template=None) -> dict:
    """{process id: {tenant, actors, old_base_url, base_url, inputs}} for the object entries of a chain
    ({"process": "BP-08", "dry_run": true} takes the process's own dry_run block; explicit keys win).
    A process with an override runs on its own tenant with its own inputs only; other entries are not listed."""
    by_id = {p["id"]: p for p in processes}
    found = {}
    for entry in chain.get("processes") or []:
        if not isinstance(entry, dict):
            continue
        extra = set(entry) - {"process", "dry_run", *OVERRIDE_KEYS}
        if extra:
            raise ConfigError(f"chain: entry {entry['process']!r} has unknown keys: " + ", ".join(sorted(extra)))
        process = next((p for p in processes if p["id"] == entry["process"] or p["id"].startswith(entry["process"] + "-")), None)
        if process is None:
            continue  # blocked_by: never run
        block = dict(process.get("dry_run") or {}) if entry.get("dry_run") else {}
        block.update({k: entry[k] for k in OVERRIDE_KEYS if k in entry})
        tenant = block.get("tenant")
        if not tenant or not isinstance(block.get("actors"), dict) or not block["actors"]:
            raise ConfigError(f"chain: entry {process['id']} needs a tenant and actors (its dry_run block or the entry)")
        block["actors"] = normalize_actors(block["actors"], f"chain entry {process['id']} actors")
        block.setdefault("inputs", {})
        block.setdefault("base_url", base_url_for(tenant, base_url_template))
        found[by_id[process["id"]]["id"]] = block
    return found


def validate_pass_map(chain, processes) -> dict:
    """The chain's optional `pass`: {source process id: [output names later processes may read]}"""
    value = chain.get("pass", {})
    if not isinstance(value, dict):
        raise ConfigError("chain: pass must be an object {process id: [output names]}")
    by_id = {p["id"]: p for p in processes}
    for pid, names in value.items():
        if pid not in by_id:
            raise ConfigError(f"chain: pass names unknown process {pid!r}")
        if not isinstance(names, list) or not all(isinstance(n, str) and n for n in names):
            raise ConfigError(f"chain: pass.{pid} must be a list of output names")
        unknown = set(names) - set(by_id[pid].get("outputs") or {})
        if unknown:
            raise ConfigError(f"chain: pass.{pid} names non-outputs: " + ", ".join(sorted(unknown)))
    return value


def resolve_process_file(chain_dir: Path, name: str) -> Path:
    candidates = [chain_dir / name, chain_dir.parent / "processes" / name, chain_dir.parent / "processes" / (name + ".json")]
    candidates += sorted((chain_dir.parent / "processes").glob(name + "-*.json"))
    for c in candidates:
        if c.is_file():
            return c
    raise ConfigError(f"chain: no process file for {name!r} (looked in {chain_dir.parent / 'processes'})")


def check_chain_inputs(processes, provided: set, fixtures=(), pass_map=None, overrides=None) -> None:
    """Every process finds its inputs in the caller/fixtures or the earlier outputs explicitly named by `pass`.
    Fixtures run first: what they `provide` is available to everything after them. Working/default names stay local."""
    available = set(provided) | set(BUILTIN_NAMES)
    for f in fixtures:
        missing = set(f.get("inputs") or []) - available - set(f.get("defaults") or {})
        if missing:
            raise ConfigError(f"fixture {f['id']}: inputs missing: " + ", ".join(sorted(missing)))
        available |= set(f.get("provides") or []) | set(f.get("defaults") or {})
    for p in processes:
        mine = available
        if p["id"] in (overrides or {}):  # another tenant: its own inputs only, no ids of the first tenant
            mine = set(overrides[p["id"]].get("inputs") or {}) | set(BUILTIN_NAMES)
        missing = set(p.get("inputs") or []) - mine - set(p.get("defaults") or {})
        if missing:
            raise ConfigError(f"{p['id']}: inputs missing: " + ", ".join(sorted(missing)))
        available |= set((pass_map or {}).get(p["id"], []))


def parse_pairs(items, what) -> dict:
    out = {}
    for item in items:
        name, sep, value = item.partition("=")
        if not sep or not name:
            raise ConfigError(f"{what}: expected name=value, got {item!r}")
        out[name] = value
    return out


def parse_actors(raw, what="--actors") -> dict:
    """The actors of the command line: "a=user,b=user", or one JSON map with the actor objects of
    another tenant ({"a": {"user": ..., "tenant": ..., "base_url": ...}})."""
    raw = (raw or "").strip()
    if not raw:
        return {}
    if raw.startswith("{"):
        try:
            given = json.loads(raw)
        except ValueError:
            raise ConfigError(f"{what} is not valid JSON") from None
        if not isinstance(given, dict):
            raise ConfigError(f"{what} must be an object {{actor: user name}}")
        return given
    return parse_pairs([a for a in raw.split(",") if a], what)


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


def default_run_dir(run_id: str) -> Path:
    """An absolute run directory outside the checkout; only an explicit CLI option may choose one inside it."""
    configured = os.environ.get("UAT_RUN_DIR_ROOT")
    task_dir = os.environ.get("TEAM_TASKDIR")
    if configured:
        root = Path(configured)
    elif task_dir:
        root = Path(task_dir) / "uat-runs"
    else:
        root = Path(tempfile.gettempdir()) / "letflow-uat-runs"
    return root.expanduser().resolve() / run_id


def load_retired_checked(root=None) -> dict:
    import retired

    try:
        return retired.load_retired(root)
    except retired.RetiredError as err:
        raise ConfigError(str(err)) from None


def refuse_retired(retired_map, tenant, actors, base_urls=(), docs=()):
    """Exit-2 guard (T-2538): a retired tenant, a user of one or a base url naming one stops the run before any
    request. An actor object names the tenant it lives on and its own address: both are checked too.
    docs: [(name, document)] of process, chain and fixture files."""
    import retired

    found = []
    slug = retired.retired_tenant_of(tenant, retired_map)
    if slug:
        found.append(f"tenant {slug!r} is retired")
    for actor, spec in (actors or {}).items():
        user = spec.get("user") if isinstance(spec, dict) else spec
        slug = retired.retired_tenant_of_user(user, retired_map)
        if slug:
            found.append(f"actor {actor!r} names the user {user!r} of the retired tenant {slug!r}")
        if isinstance(spec, dict):
            slug = retired.retired_tenant_of(spec.get("tenant"), retired_map)
            if slug:
                found.append(f"actor {actor!r} lives on the retired tenant {slug!r}")
            slug = retired.retired_tenant_of_url(spec.get("base_url"), retired_map)
            if slug:
                found.append(f"actor {actor!r} has a base url at the retired tenant {slug!r}")
    for url in base_urls:
        slug = retired.retired_tenant_of_url(url, retired_map)
        if slug:
            found.append(f"base url {url!r} points at the retired tenant {slug!r}")
    for name, doc in docs:
        found += retired.violations(doc, name, retired_map)
    if found:
        raise ConfigError("refused, a retired tenant (test/uat/retired-tenants.json), nothing was requested: " + "; ".join(found))


def blocked_reason(doc):
    if isinstance(doc, dict) and "do" in doc:  # a step: its own blocked_by marker
        reason = doc.get("blocked_by")
        return reason if isinstance(reason, str) and reason.strip() else None
    block = doc.get("dry_run") if isinstance(doc, dict) else None
    reason = block.get("blocked_by") if isinstance(block, dict) else None
    return reason if isinstance(reason, str) and reason.strip() else None


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
    import retired

    try:
        retired_map = load_retired_checked(repo)
    except ConfigError as err:
        print(f"dry-run: {err}", file=out)
        return 2
    refused = []
    for path in files:
        refused += retired.violations_in_file(path, retired_map)
        try:
            doc = json.loads(Path(path).read_text(encoding="utf-8"))
            if isinstance(doc, dict) and "processes" in doc:
                _chain, processes = load_chain(path)
                docs = processes + [doc]
                for pid, over in chain_overrides(_chain, processes, args.base_url_template).items():
                    try:
                        refuse_retired(retired_map, over["tenant"], over["actors"], [over["base_url"], over.get("old_base_url")], [])
                    except ConfigError as err:
                        refused.append(f"{path} entry {pid}: {err}")
            else:
                processes = [load_process(path)]
                docs = processes
            for fx in fixtures_for(docs, fixtures_dir_for(path)):
                refused += retired.violations(fx, "fixture " + str(fx.get("id")), retired_map)
            for pdoc in processes:
                refused += retired.violations(pdoc, str(pdoc.get("id")), retired_map)
        except (OSError, ValueError, KeyError, ConfigError, TypeError):
            pass  # the static check reports these
    if refused:
        print("dry-run: REFUSED, a retired tenant is named (test/uat/retired-tenants.json); nothing was requested:", file=out)
        for line in refused:
            print("  " + line, file=out)
        return 2

    problems = check_processes.check_files(files, root=repo, strict=True)
    if problems:
        print("dry-run: the static check fails, nothing was run:", file=out)
        for p in problems:
            print("  " + p, file=out)
        return 1
    runnable = []
    for path in files:
        doc = json.loads(path.read_text(encoding="utf-8"))
        why = blocked_reason(doc)
        if why:
            print(f"dry-run: SKIPPED {path.name}: blocked_by {why} (never run)", file=out)
        else:
            runnable.append(path)
    files = runnable
    if not files:
        print("dry-run: PASS (every file is blocked: nothing to run)", file=out)
        return 0
    entries = []
    for path in files:
        doc = json.loads(path.read_text(encoding="utf-8"))
        block = doc.get("dry_run") or {}
        entries.append((path.name, block.get("tenant") or doc.get("tenant"), block.get("actors") or doc.get("actors") or {}))
    for line in retired.batch_lines(entries, retired_map):
        print("dry-run: " + line, file=out)
    run_id = "dry-run-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    root_dir = Path(args.run_dir_root) if args.run_dir_root else default_run_dir(run_id)
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
                overrides = chain_overrides(chain, processes, args.base_url_template)
            else:
                chain, processes, label, overrides = {}, [load_process(path)], doc["id"], {}
            actors = normalize_actors(actors, f"{path.name} actors")
            fixtures = fixtures_for([p for p in processes if p["id"] not in overrides] + ([doc] if "processes" in doc else []),
                                    fixtures_dir_for(path))
            check_chain_inputs(processes, set(inputs), fixtures, chain.get("pass"), overrides)
        except ConfigError as err:
            print(f"dry-run: {path.name}: {err}", file=out)
            worst = 1
            continue
        print(f"dry-run: {path.name} on {tenant} ({base})", file=out, flush=True)
        runner = Runner(processes, base_url=base, tenant=tenant, actors=actors, run_dir=root_dir / path.stem,
                        inputs=inputs, health_url=args.health_url, poll_interval=args.poll_interval, out=out,
                        build_sha=args.build_sha, old_base_url=block.get("old_base_url") or args.old_base_url,
                        keep_going=False, label=label, file_issues=False, fixtures=fixtures, pass_map=chain.get("pass"),
                        overrides=overrides, cleanup_mode=chain.get("cleanup", "end"),
                        allow_create=getattr(args, "allow_create", False),
                        mail_trap_url=getattr(args, "mail_trap_url", None))
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
    p.add_argument("--run-dir", help="where run.jsonl, context.json and summary.md go (default: UAT_RUN_DIR_ROOT, TEAM_TASKDIR/uat-runs, or the temp directory)")
    p.add_argument("--health-url", help="build sha source (default <base-url>/health)")
    p.add_argument("--poll-interval", type=float, help="seconds between task polls (default: the step's interval_s, 2)")
    p.add_argument("--build-sha", help="the build the run is for: /health must report it (a prefix is enough)")
    p.add_argument("--no-stable-check", action="store_true", help="do not call project/scripts/qa_stable.sh --wait")
    p.add_argument("--old-base-url", help="the old address, e.g. https://qa.bizdala.com/qoimeks/<slug>/api (http_as steps)")
    p.add_argument("--file-issues", action="store_true", help="open one GitHub issue per failed process with gh")
    p.add_argument("--repo", help="the repository for --file-issues (default env UAT_ISSUE_REPO or gh's own)")
    p.add_argument("--gh", help="the gh command (default env UAT_GH or gh)")
    p.add_argument("--allow-create", action="store_true",
                   help="let a step create a tenant (POST /api/v1/tenants); without it the step is skipped")
    p.add_argument("--mail-trap-url", help="the mail trap (Mailpit) a wait_mail step reads "
                                            "(default env MAIL_TRAP_URL or " + MAIL_TRAP_URL_DEFAULT + ")")


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
    dry.add_argument("--run-dir-root", help="a directory for the run directories (one per file; default: UAT_RUN_DIR_ROOT, TEAM_TASKDIR/uat-runs, or the temp directory)")
    dry.add_argument("--base-url", help="the same base url for every file (default: the dry_run block, then the template)")
    dry.add_argument("--base-url-template", help="URL with {tenant}")
    dry.add_argument("--health-url")
    dry.add_argument("--poll-interval", type=float)
    dry.add_argument("--build-sha")
    dry.add_argument("--no-stable-check", action="store_true")
    dry.add_argument("--old-base-url")
    dry.add_argument("--allow-create", action="store_true",
                     help="let a step create a tenant (POST /api/v1/tenants); without it the step is skipped")
    dry.add_argument("--mail-trap-url", help="the mail trap (Mailpit) a wait_mail step reads "
                                            "(default env MAIL_TRAP_URL or " + MAIL_TRAP_URL_DEFAULT + ")")
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
    run_dir = Path(args.run_dir) if args.run_dir else default_run_dir(run_id)
    if (run_dir / "run.jsonl").exists():
        raise ConfigError(f"{run_dir}/run.jsonl exists: use a new --run-dir")
    return run_dir


def main_run(args) -> int:
    try:
        if args.command == "chain":
            chain, processes = load_chain(args.chain)
            label = chain["id"]
            overrides = chain_overrides(chain, processes, args.base_url_template)
            fixtures = fixtures_for([p for p in processes if p["id"] not in overrides] + [chain], fixtures_dir_for(args.chain))
        else:
            chain, processes, overrides = {}, [load_process(args.process)], {}
            label = processes[0]["id"]
            fixtures = fixtures_for(processes, fixtures_dir_for(args.process))
        inputs = dict(chain.get("inputs") or {})
        inputs.update(read_inputs(args))
        tenant = args.tenant or chain.get("tenant")
        if not tenant:
            raise ConfigError("--tenant is needed")
        actors = dict(chain.get("actors") or {})
        actors.update(parse_actors(args.actors))
        actors = normalize_actors(actors, f"{label} actors")
        own = [p for p in processes if p["id"] not in overrides]
        needed = {s.get("actor") for p in fixtures + own for s in p["steps"] + (p.get("cleanup") or []) if not s.get("http_as")}
        needed |= {c["actor"] for p in fixtures + processes for s in p["steps"] + (p.get("cleanup") or [])
                   for c in s["do"].get("parallel", []) if c.get("actor")}
        needed.discard(None)
        if needed - actors.keys():
            raise ConfigError("actors missing in --actors: " + ", ".join(sorted(needed - actors.keys())))
        for p in processes:
            if p["id"] in overrides:
                need = {s.get("actor") for s in p["steps"] + (p.get("cleanup") or []) if not s.get("http_as")} - {None}
                if need - overrides[p["id"]]["actors"].keys():
                    raise ConfigError(f"{p['id']}: actors missing for its tenant: " + ", ".join(sorted(need - overrides[p["id"]]["actors"].keys())))
        check_chain_inputs(processes, set(inputs), fixtures, chain.get("pass"), overrides)
        base_url = args.base_url or chain.get("base_url") or base_url_for(tenant, args.base_url_template)
        import retired

        retired_map = load_retired_checked()
        refuse_retired(retired_map, tenant, actors, [base_url, args.old_base_url or chain.get("old_base_url")],
                       [(str(d.get("id")), d) for d in fixtures + processes + ([chain] if chain else [])])
        for pid, over in overrides.items():  # T-2538 guard for every entry, before any request
            refuse_retired(retired_map, over["tenant"], over["actors"], [over["base_url"], over.get("old_base_url")], [])
        if args.command != "chain":
            why = blocked_reason(processes[0])
            if why:
                raise ConfigError(f"{label} is blocked_by {why}: it is never run")
        for line in retired.batch_lines([(label, tenant, actors)], retired_map):
            print("runner.py: " + line, flush=True)
        run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + secrets.token_hex(3)
        run_dir = new_run_dir(args, run_id)
    except ConfigError as err:
        print(f"runner.py: {err}", file=sys.stderr)
        return 2
    runner = Runner(processes, base_url=base_url, tenant=tenant, actors=actors, run_dir=run_dir, inputs=inputs,
                    health_url=args.health_url, poll_interval=args.poll_interval, run_id=run_id, build_sha=args.build_sha,
                    old_base_url=args.old_base_url or chain.get("old_base_url"), keep_going=getattr(args, "keep_going", False),
                    label=label, file_issues=args.file_issues, repo=args.repo, gh_cmd=args.gh, fixtures=fixtures,
                    pass_map=chain.get("pass"), overrides=overrides, cleanup_mode=chain.get("cleanup", "end"),
                    residue_check=chain.get("residue_check") is not False,
                    allow_create=getattr(args, "allow_create", False),
                    mail_trap_url=getattr(args, "mail_trap_url", None))
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
        actors.update(parse_actors(args.actors))
        refuse_retired(load_retired_checked(), meta.get("tenant"), actors,
                       [args.base_url or meta.get("base_url"), args.old_base_url or meta.get("old_base_url")])
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
