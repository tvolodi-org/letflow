#!/usr/bin/env python3
"""Reader of the pilot scenario list (T-2823): test/uat/pilot-scenarios.txt and the smoke verdict line.

CLI (used by the engine's uat_smoke): `pilot_list.py list <repo_root>` prints `<id>\t<file or planned>` per line and
exits 2 when a listed id has no file. `pilot_list.py verdict <id> <passed> <failed> <not_run> [--require-zero-blocked]`
prints the verdict line and exits 1 on FAIL.
"""
import sys
from pathlib import Path

LIST = Path("test") / "uat" / "pilot-scenarios.txt"
PROCESSES = Path("test") / "uat" / "processes"


class ListError(Exception):
    pass


def read_list(root):
    """-> [(id, Path | None)]; None means planned. A missing list or a missing file raises ListError."""
    root = Path(root)
    f = root / LIST
    if not f.is_file():
        raise ListError(f"pilot list missing: {LIST}")
    out = []
    for raw in f.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) > 2 or (len(parts) == 2 and parts[1] != "planned"):
            raise ListError(f"bad line in {LIST}: {raw!r}")
        sid = parts[0]
        if len(parts) == 2:
            out.append((sid, None))
            continue
        found = sorted((root / PROCESSES).glob(sid + "-*.json"))
        if not found:
            raise ListError(f"scenario file of {sid} missing in {PROCESSES}")
        out.append((sid, found[0]))
    return out


def verdict_line(sid, passed, failed, not_run, require_zero_blocked=False, planned=False):
    """One verdict line per scenario: failures fail; not-run steps pass unless require_zero_blocked."""
    if planned:
        return "PASS", f"{sid}: not run: planned"
    if failed:
        return "FAIL", f"{sid}: FAIL (steps passed: {passed}, failed: {failed}, not run: {not_run})"
    if not_run:
        if require_zero_blocked:
            return "FAIL", f"{sid}: FAIL ({not_run} steps NOT RUN, zero required; passed: {passed}, not run: {not_run})"
        return "PASS", f"{sid}: PASS ({not_run} steps NOT RUN; passed: {passed}, not run: {not_run})"
    return "PASS", f"{sid}: PASS (steps passed: {passed}, not run: 0)"


def main(argv):
    if len(argv) >= 3 and argv[1] == "list":
        try:
            for sid, f in read_list(argv[2]):
                print(f"{sid}\t{f if f else 'planned'}")
        except ListError as e:
            print(e, file=sys.stderr)
            return 2
        return 0
    if len(argv) >= 6 and argv[1] == "verdict":
        v, line = verdict_line(argv[2], int(argv[3]), int(argv[4]), int(argv[5]), "--require-zero-blocked" in argv)
        print(line)
        return 0 if v == "PASS" else 1
    print(__doc__, file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
