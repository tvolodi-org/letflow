"""Tests of the pilot scenario list reader and the verdict line (T-2823). No network.

Run: python3 -B -m unittest -v scripts/uat/tests/test_pilot_list.py   (from the repository root)
"""
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import pilot_list  # noqa: E402

ROOT = HERE.parents[2]


def tree(listing, files=()):
    d = Path(tempfile.mkdtemp())
    (d / "test/uat/processes").mkdir(parents=True)
    if listing is not None:
        (d / "test/uat/pilot-scenarios.txt").write_text(listing)
    for f in files:
        (d / "test/uat/processes" / f).write_text("{}")
    return d


class ReadList(unittest.TestCase):
    def test_the_shipped_list_names_01_02_24_and_every_listed_file_exists(self):
        got = pilot_list.read_list(ROOT)
        self.assertEqual(["BP-PLATFORM-01", "BP-PLATFORM-02", "BP-PLATFORM-24"], [g[0] for g in got])
        self.assertIsNotNone(got[0][1])
        self.assertIsNotNone(got[2][1])

    def test_planned_has_no_file_and_does_not_need_one(self):
        d = tree("# c\nBP-X-01 planned\n")
        self.assertEqual([("BP-X-01", None)], pilot_list.read_list(d))

    def test_a_listed_id_without_a_file_fails(self):
        with self.assertRaises(pilot_list.ListError):
            pilot_list.read_list(tree("BP-X-01\n"))

    def test_missing_list_and_bad_line_fail(self):
        with self.assertRaises(pilot_list.ListError):
            pilot_list.read_list(tree(None))
        with self.assertRaises(pilot_list.ListError):
            pilot_list.read_list(tree("BP-X-01 maybe\n"))

    def test_file_found_by_id_prefix(self):
        d = tree("BP-X-01\n", ["BP-X-01-name.json"])
        self.assertEqual("BP-X-01-name.json", pilot_list.read_list(d)[0][1].name)


class Verdict(unittest.TestCase):
    def test_not_run_passes_by_default_and_says_so(self):
        v, line = pilot_list.verdict_line("S", 10, 0, 28)
        self.assertEqual("PASS", v)
        self.assertIn("PASS (28 steps NOT RUN", line)
        self.assertIn("not run: 28", line)

    def test_require_zero_blocked_turns_not_run_into_fail(self):
        self.assertEqual("FAIL", pilot_list.verdict_line("S", 10, 0, 1, True)[0])
        self.assertEqual("PASS", pilot_list.verdict_line("S", 10, 0, 0, True)[0])

    def test_a_failed_step_fails_and_planned_never_fails(self):
        self.assertEqual("FAIL", pilot_list.verdict_line("S", 1, 1, 0)[0])
        v, line = pilot_list.verdict_line("S", 0, 0, 0, True, planned=True)
        self.assertEqual(("PASS", "S: not run: planned"), (v, line))

    def test_cli_exit_codes(self):
        self.assertEqual(1, pilot_list.main(["x", "verdict", "S", "1", "0", "2", "--require-zero-blocked"]))
        self.assertEqual(0, pilot_list.main(["x", "verdict", "S", "1", "0", "2"]))
        self.assertEqual(2, pilot_list.main(["x", "list", str(tree("BP-X-01\n"))]))


if __name__ == "__main__":
    unittest.main()
