#!/usr/bin/env python3
"""client1_workbook.py -- the synthetic Client 1 workbook set for the runner's `upload` step (T-2864, D-208, D-050).

No real data: scripts/pilot/qoimeks_gen.py makes the fictitious extract from a seed (134 places, 666 items, 600
balances) and scripts/pilot/qoimeks_convert.py turns it into the import workbooks (xlsx) a Client 1 load uses. Both are
deterministic (fixed zip timestamps), so the set is BUILT AT RUN TIME from the seed and never committed (about 70 files
of xlsx would only age): the runner builds it under <run dir>/generated-fixtures/client1 the first time a step names a
file under `generated/client1/`. The files carry no secret.

  python3 -I scripts/uat/client1_workbook.py --out DIR [--seed N]
"""

import argparse
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PILOT = REPO / "scripts" / "pilot"
DEFAULT_SEED = 42
RECEIVED_ON = "2026-01-01"  # a fixed opening date: the set must be byte-identical for one seed
TIMEOUT_S = 120


class BuildError(Exception):
    pass


def _run(args):
    done = subprocess.run([sys.executable, "-I", *map(str, args)], capture_output=True, text=True, timeout=TIMEOUT_S,
                          stdin=subprocess.DEVNULL)
    if done.returncode != 0:
        raise BuildError(f"{Path(str(args[0])).name} failed (exit {done.returncode}): {(done.stderr or done.stdout)[-300:]}")


def build(out, seed=DEFAULT_SEED) -> list:
    """Write the workbook set (+ manifest.json, expected_counts.txt) into `out`; -> the sorted file names."""
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    csv = out / "csv"  # T-2857: kept, the compare tools read the generated extract
    _run([PILOT / "qoimeks_gen.py", "--out", csv, "--seed", seed])
    _run([PILOT / "qoimeks_convert.py", "convert", "--in", csv, "--out", out, "--system", "client1",
          "--org-unit-ext", "client1-ou", "--responsible-ext", "client1-resp", "--received-on", RECEIVED_ON,
          "--allow-drops"])
    return sorted(p.name for p in out.iterdir() if p.is_file())


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", required=True)
    ap.add_argument("--seed", type=int, default=DEFAULT_SEED)
    a = ap.parse_args(argv)
    for name in build(a.out, a.seed):
        print(name)


if __name__ == "__main__":
    main()
