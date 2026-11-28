"""tenant_retention (T-3203): retire the throwaway tenants a runner left on QA, through the product's own process.

Every throwaway tenant costs tables and catalog memory on the QA database (35,970 tables for about 55 tenants was
the QA crash of 28 Nov). A scenario's cleanup only knows its own tenant, so older ones pile up. This module is the
`tenant_retention` step kind of the runner (a cleanup step of a platform scenario, as the platform administrator):

    "do": {"tenant_retention": {"days": 1, "max_per_run": 20, "dry_run": false}}

It lists the tenant registry (GET /api/v1/tenants), keeps the CANDIDATES (a slug on the allow-list, not on any
exclusion, older than `days` by `inserted_at`), and for at most `max_per_run` of them, oldest first, starts the seeded
process platform.tenant_lifecycle (T-2972: platform-admin started, destructive, audited): `suspend` when the tenant
is still active, then `purge` with the slug as confirmation. Never SQL. The product's own retention rule
(LETFLOW_PROVISIONER_RETENTION_DAYS) decides the purge: an ERROR instance ("not eligible yet") is reported as LEFT,
not as a failed run (the next run tries again). `dry_run` lists the candidates and starts nothing.

Allow-list (a tenant matching none is never touched): `uat-tmp-<anything>` and `uat-<8 digit date>-<id>`, plus the
slugs of test/uat/sweeps/tenant-retention-extra.json (empty: a reviewed per-tenant entry, added only after the PM's
word). Exclusions (each has a test): the fixed fixture tenant `uat-tmp-fixture` and `uat-tmp-admin`, the fixture
tenants of the config (qoimeks-qa2, sss-rehearsal2, bpm-default), `owner-*`, every retired tenant of
test/uat/retired-tenants.json, a tenant whose registry row says `tenant_type` other than `test`, the tenant of the
acting administrator, and every run that is not on a QA host (or loopback for the tests).
"""

from __future__ import annotations

import json
import os
import re
import tempfile
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

DEFAULT_DAYS = 1
DEFAULT_MAX_PER_RUN = 20
HARD_MAX_PER_RUN = 25
RETENTION_SETTING = "LETFLOW_PROVISIONER_RETENTION_DAYS"
POLL_S = 60  # one lifecycle instance is polled for at most this long
LOCK_STALE_S = 1800
ALLOW_RES = (re.compile(r"uat-tmp-[a-z0-9][a-z0-9-]*"), re.compile(r"uat-\d{8}-[a-z0-9][a-z0-9-]*"))
EXCLUDED_SLUGS = ("uat-tmp-fixture", "uat-tmp-admin", "qoimeks-qa2", "sss-rehearsal2", "bpm-default",
                  "qoimeks-qa", "qoimeks-client1-qa")
EXCLUDED_PREFIXES = ("owner-",)
QA_HOSTS = (re.compile(r"^https://qa\.bizdala\.com/?$"), re.compile(r"^https://[a-z0-9-]+\.letflow\.qa\.bizdala\.com/?$"),
            re.compile(r"^http://(127\.0\.0\.1|localhost)(:\d+)?/?$"))
EXTRA_FILE = Path(__file__).resolve().parents[2] / "test" / "uat" / "sweeps" / "tenant-retention-extra.json"
SPEC_KEYS = {"days", "max_per_run", "dry_run"}
NAMESPACE = uuid.UUID("5c1c6f0e-3203-4b7e-9d1a-7a1f6f3b2203")


def spec_problem(spec):
    """-> an error text, or None. Shared by the config check and the step."""
    if not isinstance(spec, dict) or set(spec) - SPEC_KEYS:
        return "tenant_retention is {days?, max_per_run?, dry_run?}"
    days, cap, dry = spec.get("days", DEFAULT_DAYS), spec.get("max_per_run", DEFAULT_MAX_PER_RUN), spec.get("dry_run", False)
    if isinstance(days, bool) or not isinstance(days, int) or not 1 <= days <= 365:
        return "tenant_retention days is a whole number of 1 to 365"
    if isinstance(cap, bool) or not isinstance(cap, int) or not 1 <= cap <= HARD_MAX_PER_RUN:
        return f"tenant_retention max_per_run is a whole number of 1 to {HARD_MAX_PER_RUN}"
    if not isinstance(dry, bool):
        return "tenant_retention dry_run is true or false"
    return None


def load_extra(path=None):
    """The reviewed extra allow-list: {"extra_allow": ["slug", ...]}. A missing file is an empty list."""
    path = Path(path or EXTRA_FILE)
    if not path.is_file():
        return []
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
        slugs = doc["extra_allow"]
    except (OSError, ValueError, KeyError, TypeError) as err:
        raise ValueError(f"cannot read {path}: {err}") from None
    if not isinstance(slugs, list) or not all(isinstance(s, str) and re.fullmatch(r"[a-z0-9][a-z0-9-]{1,62}", s) for s in slugs):
        raise ValueError(f"{path}: extra_allow is a list of tenant slugs")
    return slugs


def host_problem(base_url):
    if not any(r.match(base_url or "") for r in QA_HOSTS):
        return f"base url {base_url!r} is not a QA host: refused"
    return None


def parse_ts(text):
    try:
        ts = datetime.fromisoformat(str(text).replace("Z", "+00:00"))
    except ValueError:
        return None
    return ts if ts.tzinfo else ts.replace(tzinfo=timezone.utc)


def exclusion(row, retired, own_tenant, extra):
    """-> why this registry row is never touched, or None when it may be (it is a candidate before the age test)."""
    slug = row.get("slug")
    if not isinstance(slug, str):
        return "no slug"
    if slug in EXCLUDED_SLUGS:
        return "fixture tenant"
    if slug.startswith(EXCLUDED_PREFIXES):
        return "owner tenant"
    if slug in retired:
        return "retired tenant"
    if slug == own_tenant:
        return "the tenant of the acting administrator"
    if not (any(r.fullmatch(slug) for r in ALLOW_RES) or slug in extra):
        return "not on the allow-list"
    if row.get("tenant_type") not in (None, "test"):
        return f"tenant_type {row.get('tenant_type')}"
    return None


def candidates(rows, now, days, retired, own_tenant, extra=()):
    """-> ([(slug, status, inserted_at)] oldest first, kept: {slug: reason})."""
    cutoff = now - timedelta(days=days)
    out, kept = [], {}
    for row in rows:
        if not isinstance(row, dict):
            continue
        why = exclusion(row, retired, own_tenant, extra)
        if why:
            kept[str(row.get("slug"))] = why
            continue
        ts = parse_ts(row.get("inserted_at"))
        if ts is None:
            kept[row["slug"]] = "no readable inserted_at"
        elif ts > cutoff:
            kept[row["slug"]] = "younger than the retention"
        else:
            out.append((row["slug"], str(row.get("status") or ""), ts))
    out.sort(key=lambda c: (c[2], c[0]))
    return out, kept


class Lock:
    """One lock file per tenant, so two runs do not purge the same tenant. A lock older than LOCK_STALE_S is a
    crashed run's and is taken over."""

    def __init__(self, slug, root=None):
        self.path = Path(root or Path(tempfile.gettempdir()) / "uat-tenant-retention-locks") / f"{slug}.lock"
        self.held = False

    def acquire(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        for _ in range(2):
            try:
                os.close(os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
                self.held = True
                return True
            except FileExistsError:
                try:
                    if time.time() - self.path.stat().st_mtime < LOCK_STALE_S:
                        return False
                    self.path.unlink()
                except FileNotFoundError:
                    pass
        return False

    def release(self):
        if self.held:
            self.held = False
            try:
                self.path.unlink()
            except FileNotFoundError:
                pass


def list_registry(request):
    rows, cursor = [], None
    for _ in range(50):
        status, body, _ = request("GET", "/api/v1/tenants" + (f"?cursor={cursor}" if cursor else ""))
        if status != 200 or not isinstance(body, dict):
            raise RuntimeError(f"the tenant registry answered {status}")
        rows += [r for r in body.get("items") or [] if isinstance(r, dict)]
        cursor = body.get("next_cursor")
        if not cursor:
            return rows
    raise RuntimeError("more than 50 pages of tenants: refused")


def run_action(request, slug, action, sleep=time.sleep, poll_s=POLL_S):
    """Start platform.tenant_lifecycle for one tenant and wait for its end. -> (state, detail).
    The request id is fixed per tenant and action, so a second start of the same call is one call of the product."""
    body = {"definition_name": "platform.tenant_lifecycle",
            "initial_variables": {"slug": slug, "action": action, "confirm": slug,
                                  "request_id": str(uuid.uuid5(NAMESPACE, f"{slug}:{action}"))}}
    status, answer, _ = request("POST", "/api/v1/instances", body)
    if status not in (200, 201) or not isinstance(answer, dict) or not answer.get("instance_id"):
        return "refused", f"start answered {status}"
    instance = str(answer["instance_id"])
    if not re.fullmatch(r"[A-Za-z0-9-]{1,64}", instance):
        return "refused", "instance id is not a plain id"
    deadline = time.monotonic() + poll_s
    while True:
        status, got, _ = request("GET", f"/api/v1/instances/{instance}")
        state = str(got.get("status")) if status == 200 and isinstance(got, dict) else f"read {status}"
        if state in ("COMPLETED", "ERROR", "CANCELLED", "TERMINATED"):
            return state, instance
        if time.monotonic() >= deadline:
            return "timeout", instance
        sleep(1)


def retire(request, slug, status, sleep=time.sleep, poll_s=POLL_S):
    """-> (outcome, line): outcome is 'purged', 'left' or 'failed'. An ACTIVE tenant is deactivated (the lifecycle
    action `suspend`: status inactive, platform-admin, audited) FIRST; purge is never started on a tenant that is
    not known to be inactive. A purge the product refuses as not eligible (409: the retention days have not run out,
    so LETFLOW_PROVISIONER_RETENTION_DAYS is not applied on this host) is a loud FAILED outcome, tried once."""
    if status not in ("active", "inactive"):
        return "left", f"{slug}: LEFT, status {status or 'unknown'} is neither active nor inactive"
    if status == "active":
        state, detail = run_action(request, slug, "suspend", sleep, poll_s)
        if state != "COMPLETED":
            return "left", f"{slug}: LEFT, deactivate (suspend) ended {state} ({detail}); purge not started"
    state, detail = run_action(request, slug, "purge", sleep, poll_s)
    if state == "COMPLETED":
        return "purged", f"{slug}: purged through tenant.purge (instance {detail})"
    if state == "ERROR":
        return "failed", (f"FAILED {slug}: purge refused as not eligible (409 not_eligible, instance {detail}): "
                          f"the retention days have not run out; check that {RETENTION_SETTING} is applied on this host")
    return "left", f"{slug}: LEFT, purge ended {state} ({detail}); the next run tries again"


def execute(request, spec, own_tenant, base_url, retired, now=None, lock_root=None, extra=None, sleep=time.sleep,
            poll_s=POLL_S, out=print):
    """The step. -> {"purged": n, "left": m, "candidates": k, "dry_run": bool, "lines": [...]}. Raises ValueError for
    a refused spec or host (before any request)."""
    problem = spec_problem(spec) or host_problem(base_url)
    if problem:
        raise ValueError(problem)
    days = spec.get("days", DEFAULT_DAYS)
    cap = spec.get("max_per_run", DEFAULT_MAX_PER_RUN)
    dry = spec.get("dry_run", False)
    extra = load_extra() if extra is None else extra
    now = now or datetime.now(timezone.utc)
    found, _kept = candidates(list_registry(request), now, days, retired, own_tenant, extra)
    lines, purged, left, failed = [], 0, 0, 0

    def say(text):
        lines.append(text)
        out(text)

    say(f"tenant retention: {len(found)} candidate(s) older than {days} day(s)" + (" (dry run: nothing is purged)" if dry else ""))
    for slug, status, ts in found:
        if dry:
            say(f"{slug}: candidate, {status or 'unknown status'}, created {ts.strftime('%Y-%m-%dT%H:%MZ')}")
    if not dry:
        taken = 0
        for slug, status, _ts in found:
            if taken >= cap:
                say(f"retention stopped at {cap} tenant(s) per run: the rest stays for the next run")
                break
            lock = Lock(slug, lock_root)
            if not lock.acquire():
                say(f"{slug}: skipped, another run holds it")
                continue
            taken += 1
            try:
                outcome, line = retire(request, slug, status, sleep, poll_s)
            finally:
                lock.release()
            say(line)
            purged += outcome == "purged"
            left += outcome == "left"
            failed += outcome == "failed"
            if outcome == "failed":
                say(f"retention stopped after the first not-eligible purge: the setting {RETENTION_SETTING} is not "
                    "applied, so the rest would be refused too (no retry)")
                break
    say(f"tenant retention: {purged} purged, {left} left, {failed} failed, {len(found)} candidate(s)")
    return {"purged": purged, "left": left, "failed": failed, "candidates": len(found), "dry_run": dry, "lines": lines}
