#!/usr/bin/env python3
"""Run a CI shell step within the remaining job budget (T-2155).

The first step records an absolute deadline with a 45-second reporting/cleanup
reserve. This watchdog includes setup/compile time, unlike the runner's 1800s
partition watchdog. GitHub's job timeout remains the final backstop. No retries.
"""
import glob
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time


def unfinished_files():
    plan = os.environ.get("TEST_PARALLEL_PLAN")
    if not plan or not Path(plan).is_file():
        return ["No explicit test plan in this step (setup/static/frontend/mobile or extended CI)."]
    shard = int(os.environ.get("TEST_PARALLEL_SHARD", "1/1").split("/")[0])
    width = int(os.environ.get("TEST_PARALLEL_N", "4"))
    first, last = (shard - 1) * width + 1, shard * width
    dirs = glob.glob(os.path.join(os.environ.get("TMPDIR", "/tmp"), "letflow_test_parallel.*"))
    latest = max(dirs, key=os.path.getmtime) if dirs else None
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


def report():
    label = os.environ.get("CI_JOB_LABEL", os.environ.get("GITHUB_JOB", "unknown job"))
    limit = int(os.environ.get("CI_JOB_LIMIT_MINUTES", "10")) * 60
    message = (f"::error::{label}: {limit} s job limit approaching; stopping before GitHub cancellation. "
               "Shorten/split tests or move overflow to nightly; do not retry or raise the limit.\n"
               "Unfinished test files (running or pending in partitions without Result):\n" +
               "\n".join("- " + f for f in unfinished_files()))
    print(message, flush=True)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(message + "\n")


def main():
    command = sys.argv[1:]
    if command[:1] == ["--"]:
        command = command[1:]
    deadline = os.environ.get("CI_JOB_DEADLINE_S")
    if not deadline:
        raise SystemExit("CI_JOB_DEADLINE_S missing; refusing an unbounded CI shell")
    remaining = float(deadline) - time.time()
    if remaining <= 0:
        report()
        return 124
    child = subprocess.Popen(command, start_new_session=True)
    try:
        return child.wait(timeout=remaining)
    except subprocess.TimeoutExpired:
        # Report BEFORE termination so logs survive even if the child ignores TERM.
        report()
        os.killpg(child.pid, signal.SIGTERM)
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
        return 124


if __name__ == "__main__":
    sys.exit(main())
