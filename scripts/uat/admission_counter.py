#!/usr/bin/env python3
"""admission_counter (T-3034): the read-only admission counters of the QA node.

The node answers 503 "server at capacity, retry shortly" when the global admission budget is
exhausted -- 25 of the 26 recorded refusals of the QA evidence were that one, on a stable build,
while a single smoke ran. This reads the counters the node publishes on its PUBLIC `/health` route
(`GET /health` -> `"admission"`): the budget that is actually applied (pool_size, reserved_headroom,
cap), the units in use, the fair-share divisor and the refusals since the node started.

Read-only and secret-free by construction: the section carries aggregate figures of the NODE and no
tenant identifier, no route of any tenant's traffic and no token; the read itself is an
unauthenticated GET of the liveness route, which is outside the admission pipeline -- so the counter
is still readable when the node is at capacity, which is exactly when it is needed.

The runner reads it at the START of each tenant's leg and at EVERY 503 whose body says capacity, and
saves the answer in the run dir: `admission_counter_start.json` (the first tenant of the run; a
further tenant gets `admission_counter_start_2.json`) and `admission_counter_503_<n>.json` for the
n-th refusal. At most TEN counter files per run (the start files and the refusal files share the
budget). A read that fails, or that takes longer than 60 s, is a NOTE in the summary -- it never
changes the verdict of the run.
"""

from __future__ import annotations

import json
import threading

TIMEOUT_S = 60
MAX_FILES = 10
ANONYMOUS = "anonymous"


def read_counters(run):
    """-> the admission section of the node's /health, or None when the node publishes none.

    The liveness route is public: the read carries no token and needs no actor."""
    status, parsed, _text = run.request(ANONYMOUS, "GET", "/health")
    if status != 200 or not isinstance(parsed, dict):
        return None
    section = parsed.get("admission")
    return section if isinstance(section, dict) else None


def file_name(run, kind):
    """-> the name of the file this read is saved in (the caller adds it to the run's set).

    The name never carries the tenant slug, and it never has two dots: a name with three dot-separated
    segments has the shape of a JWT, and the runner's own redaction masks it -- the path of the file must
    stay readable in the summary, because it is what a reader of the summary opens. A second tenant of the
    run gets a numbered variant (`admission_counter_start_2.json`); the tenant itself is inside the file.
    """
    names = run._admission_counter_files

    if kind == "start":
        base = "admission_counter_start"
        name = base + ".json"
        if name not in names:
            return name
        run._admission_start_seq = getattr(run, "_admission_start_seq", 1) + 1
        return f"{base}_{run._admission_start_seq}.json"

    run._admission_503_seq = getattr(run, "_admission_503_seq", 0) + 1
    return f"admission_counter_503_{run._admission_503_seq}.json"


def capture(run, kind, tenant):
    """-> (path or None, note). Read-only, bounded by TIMEOUT_S, never raises: a failure is a note.

    `tenant` is the tenant of the leg that reads the counters (the run's own tenant, or the tenant of a
    chain entry that runs on its own): it names the file and the saved answer, it is not a request
    parameter -- the read itself is the public liveness route of the node.
    """

    if kind not in ("start", "503"):
        raise ValueError(kind)

    try:
        names = getattr(run, "_admission_counter_files", None)
        if names is None:
            names = set()
            run._admission_counter_files = names

        if len(names) >= MAX_FILES:
            return None, (f"{tenant}: admission counter ({kind}) not read: the run already holds "
                          f"{len(names)} counter files")

        box = {}

        def work():
            try:
                box["section"] = read_counters(run)
            except BaseException as err:  # noqa: BLE001 - reported as a note
                box["err"] = err

        thread = threading.Thread(target=work, daemon=True)
        thread.start()
        thread.join(TIMEOUT_S)

        if thread.is_alive():
            return None, f"{tenant}: admission counter ({kind}) timed out after {TIMEOUT_S} s"

        if "err" in box:
            return None, f"{tenant}: admission counter ({kind}) failed: {box['err']}"

        section = box["section"]

        if section is None:
            return None, (f"{tenant}: admission counter ({kind}) not read: the node publishes no "
                          f"admission counters")

        name = file_name(run, kind)
        names.add(name)
        run._atomic_write(name, json.dumps({"tenant": tenant, "kind": kind, "counters": section},
                                           indent=2, sort_keys=True))
        return str((run.run_dir / name).resolve()), None
    except Exception as err:  # noqa: BLE001 - never a verdict
        return None, f"{tenant}: admission counter ({kind}) failed: {err}"
