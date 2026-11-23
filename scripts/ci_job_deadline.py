#!/usr/bin/env python3
"""Run a CI shell step within the remaining job budget (T-2155).

The first step records an absolute deadline with a 45-second reporting/cleanup
reserve. This watchdog includes setup/compile time, unlike the runner's 1800s
partition watchdog. GitHub's job timeout remains the final backstop.

Retries (T-2224): only with `--retry-downloads`, used by the steps that download
dependencies (mix deps.get, npm ci, flutter pub get, Gradle through flutter build).
A failed command is run ONCE more, after a short pause, and only when its output matches
a download/network pattern (DOWNLOAD_FLAKE_PATTERNS); a compile or test failure, or a
timeout, is never retried. The pause and the second run count against the same job
deadline. The retry is logged as `retry 1/1: <pattern>` and added to the step summary.
"""
import glob
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time

# (label, regex) pairs; the label is what the log shows.
DOWNLOAD_FLAKE_PATTERNS = [
    ("Could not resolve", r"Could not resolve"),
    ("Could not find", r"Could not find "),
    ("Could not GET", r"Could not GET"),
    ("Could not parse POM", r"Could not parse POM"),
    ("timeout", r"(?i)timed? ?out|timeout"),
    ("5xx", r"(?i)(HTTP(/\d(\.\d)?)? |status code |error: |response code: )5\d\d\b"),
    ("ECONNRESET", r"ECONNRESET|ETIMEDOUT|ENOTFOUND|EAI_AGAIN|Connection reset"),
]
RETRY_PAUSE_S = 15
MIN_REMAINING_AFTER_PAUSE_S = 60


def match_download_flake(text):
    """Return the label of the first download/network pattern found in text, else None."""
    for label, rx in DOWNLOAD_FLAKE_PATTERNS:
        if re.search(rx, text):
            return label
    return None


def latest_tmp_dir():
    dirs = glob.glob(os.path.join(os.environ.get("TMPDIR", "/tmp"), "letflow_test_parallel.*"))
    return max(dirs, key=os.path.getmtime) if dirs else None


def unfinished_files():
    plan = os.environ.get("TEST_PARALLEL_PLAN")
    if not plan or not Path(plan).is_file():
        return ["No explicit test plan in this step (setup/static/frontend/mobile or extended CI)."]
    shard = int(os.environ.get("TEST_PARALLEL_SHARD", "1/1").split("/")[0])
    width = int(os.environ.get("TEST_PARALLEL_N", "4"))
    first, last = (shard - 1) * width + 1, shard * width
    latest = latest_tmp_dir()
    completed = set()
    if latest:
        for log in Path(latest).glob("partition-*.log"):
            if re.search(r"^Result:", log.read_text(errors="replace"), re.M):
                completed.add(int(log.stem.split("-")[-1]))
    pending = []
    for line in Path(plan).read_text().splitlines():
        part, test = line.split()
        if first <= int(part) <= last and int(part) not in completed:
            pending.append(test)
    return pending or ["All planned partitions reported completion; inspect the current shell step."]


def running_state(tail_lines=10):
    """What each partition of this shard was doing when the deadline hit.

    T-2652: a shard that runs into the job limit used to say only WHICH test
    files were unfinished; it never said WHICH FILE WAS RUNNING, which tests had
    started in it, or what the partition log's last lines said. Run 45010058431
    (shard 3/8, 2026-11-22) hung for its whole 2700 s budget and left exactly
    that question open -- the hang was in the create/migrate phase, before any
    partition had launched, so there was no partition log at all.
    """
    latest = latest_tmp_dir()
    if not latest:
        return []
    root = Path(latest)
    lines = []
    for log in sorted(root.glob("partition-*.log")):
        index = int(log.stem.split("-")[-1])
        lines.append(f"- partition {index}:")
        marker = root / "markers" / f"current-{index}.txt"
        if marker.is_file():
            for line in marker.read_text(errors="replace").splitlines():
                if line.strip():
                    lines.append(f"  - {line.strip()}")
        else:
            lines.append("  - running test file marker: none published")
        for line in log.read_text(errors="replace").splitlines()[-tail_lines:]:
            lines.append(f"  | {line}")
    # A shard that hung in the create/migrate phase has no partition log at all:
    # the create logs are the only evidence there is.
    for create in sorted(root.glob("create-*.log")):
        lines.append(f"- {create.name} (create/migrate phase):")
        for line in create.read_text(errors="replace").splitlines()[-tail_lines:]:
            lines.append(f"  | {line}")
    return lines


def report():
    label = os.environ.get("CI_JOB_LABEL", os.environ.get("GITHUB_JOB", "unknown job"))
    limit = int(os.environ.get("CI_JOB_LIMIT_MINUTES", "10")) * 60
    message = (f"::error::{label}: {limit} s job limit approaching; stopping before GitHub cancellation. "
               "Shorten/split tests or move overflow to nightly; do not retry or raise the limit.\n"
               "Unfinished test files (running or pending in partitions without Result):\n" +
               "\n".join("- " + f for f in unfinished_files()))
    state = running_state()
    if state:
        message += ("\nRunning state per partition (which file was running, which tests had "
                    "started, last log lines):\n" + "\n".join(state))
    print(message, flush=True)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(message + "\n")


def run_once(command, remaining, capture):
    """Run command within `remaining` seconds. Returns (code, tail_text, timed_out)."""
    if not capture:
        child = subprocess.Popen(command, start_new_session=True)
        reader = None
    else:
        child = subprocess.Popen(command, start_new_session=True, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True, errors="replace")
    tail = []

    def pump():
        for line in child.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            tail.append(line)
            del tail[:-500]

    if capture:
        reader = threading.Thread(target=pump, daemon=True)
        reader.start()
    try:
        code = child.wait(timeout=remaining)
        timed_out = False
    except subprocess.TimeoutExpired:
        # Report BEFORE termination so logs survive even if the child ignores TERM.
        report()
        os.killpg(child.pid, signal.SIGTERM)
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
        code, timed_out = 124, True
    if reader:
        reader.join(timeout=5)
    return code, "".join(tail), timed_out


def note_retry(label):
    message = f"retry 1/1: {label}"
    print(message, flush=True)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(f"{message} (download flake; step re-run once)\n")


def main():
    command = sys.argv[1:]
    retry = False
    if command[:1] == ["--retry-downloads"]:
        retry, command = True, command[1:]
    if command[:1] == ["--"]:
        command = command[1:]
    deadline = os.environ.get("CI_JOB_DEADLINE_S")
    if not deadline:
        raise SystemExit("CI_JOB_DEADLINE_S missing; refusing an unbounded CI shell")
    remaining = float(deadline) - time.time()
    if remaining <= 0:
        report()
        return 124
    code, tail, timed_out = run_once(command, remaining, retry)
    if not retry or code == 0 or timed_out:
        return code
    label = match_download_flake(tail)
    pause = float(os.environ.get("CI_RETRY_PAUSE_S", RETRY_PAUSE_S))
    remaining = float(deadline) - time.time() - pause
    if label is None or remaining < float(os.environ.get("CI_RETRY_MIN_REMAINING_S", MIN_REMAINING_AFTER_PAUSE_S)):
        return code
    note_retry(label)
    time.sleep(pause)
    code, _tail, _timed_out = run_once(command, float(deadline) - time.time(), True)
    return code


if __name__ == "__main__":
    sys.exit(main())
