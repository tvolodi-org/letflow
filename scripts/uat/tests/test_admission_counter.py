"""T-3034: the run path reads the admission counters of the node at the start of every tenant's leg
and at every 503 whose body says capacity, and saves them in the run dir. Fake API only.

Run: python3 -B -m unittest -v scripts/uat/tests/test_admission_counter.py   (from the repository root)
"""

import contextlib
import io
import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import admission_counter  # noqa: E402
import runner  # noqa: E402
from fakes import SECRET, FakeServerCase  # noqa: E402


class AdmissionCounterCase(FakeServerCase):
    def summary(self):
        return (self.run_dir / "summary.md").read_text()

    def counters(self, name):
        return json.loads((self.run_dir / name).read_text())

    def main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = runner.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def test_the_start_of_the_leg_is_read_and_saved(self):
        code, _ = self.run_process()
        self.assertEqual(code, 0)
        path = self.run_dir / "admission_counter_start.json"
        self.assertTrue(path.is_file())
        data = self.counters("admission_counter_start.json")
        self.assertEqual(data["tenant"], "qoimeks-qa2")
        self.assertEqual(data["kind"], "start")
        self.assertEqual(data["counters"]["cap"], 28)
        self.assertEqual(data["counters"]["pool_size"], 30)
        self.assertIn(str(path.resolve()), self.summary())

    def test_a_capacity_503_reads_the_counters_again(self):
        self.state.capacity_503 = True
        code, _ = self.run_process()
        self.assertEqual(code, 1)  # the step that got the 503 fails; the read is not the reason
        path = self.run_dir / "admission_counter_503_1.json"
        self.assertTrue(path.is_file())
        data = self.counters("admission_counter_503_1.json")
        self.assertEqual(data["kind"], "503")
        self.assertEqual(data["tenant"], "qoimeks-qa2")
        self.assertIn(str(path.resolve()), self.summary())
        self.assertIn("admission_counter_503_1.json", self.summary())

    def test_a_503_that_is_not_a_capacity_refusal_reads_nothing(self):
        code, _ = self.run_process()
        self.assertEqual(code, 0)
        self.assertFalse((self.run_dir / "admission_counter_503_1.json").exists())

    def test_the_files_hold_no_secret(self):
        self.state.capacity_503 = True
        self.run_process()
        for name in ("admission_counter_start.json", "admission_counter_503_1.json"):
            self.assertNotIn(SECRET, (self.run_dir / name).read_text())

    def test_a_node_without_the_counters_is_a_note_and_not_a_verdict(self):
        ok_code, _ = self.run_process()
        self.state.admission_missing = True
        self.run_dir = self.run_dir.parent / "run2"
        code, _ = self.run_process()
        self.assertEqual(code, ok_code)
        self.assertFalse((self.run_dir / "admission_counter_start.json").exists())
        self.assertIn("NOTE", self.summary())

    def test_a_failing_read_is_a_note_and_not_a_verdict(self):
        ok_code, _ = self.run_process()
        old = admission_counter.read_counters

        def boom(run):
            raise RuntimeError("the node is not there")

        admission_counter.read_counters = boom
        self.addCleanup(setattr, admission_counter, "read_counters", old)
        self.run_dir = self.run_dir.parent / "run2"
        code, _ = self.run_process()
        self.assertEqual(code, ok_code)
        self.assertFalse((self.run_dir / "admission_counter_start.json").exists())
        self.assertIn("NOTE", self.summary())

    def test_a_timeout_is_a_note(self):
        old = admission_counter.TIMEOUT_S
        admission_counter.TIMEOUT_S = 0.05
        self.addCleanup(setattr, admission_counter, "TIMEOUT_S", old)
        old_read = admission_counter.read_counters
        import time

        def slow(run):
            time.sleep(0.5)
            return {}

        admission_counter.read_counters = slow
        self.addCleanup(setattr, admission_counter, "read_counters", old_read)
        self.run_dir = self.run_dir.parent / "run2"
        code, _ = self.run_process()
        self.assertEqual(code, 0)
        self.assertFalse((self.run_dir / "admission_counter_start.json").exists())
        self.assertIn("timed out", self.summary())

    def test_at_most_ten_counter_files_per_run(self):
        self.state.capacity_503 = True
        self.run_process()
        files = [p for p in self.run_dir.iterdir() if p.name.startswith("admission_counter")]
        self.assertLessEqual(len(files), admission_counter.MAX_FILES)

    def test_the_cap_stops_the_reads(self):
        self.state.capacity_503 = True
        code, _ = self.run_process()
        self.assertEqual(code, 1)
        names = sorted(p.name for p in self.run_dir.iterdir() if p.name.startswith("admission_counter"))
        self.assertIn("admission_counter_start.json", names)
        self.assertTrue(all(n.startswith("admission_counter_") for n in names))

    def test_a_second_tenant_leg_gets_its_own_start_file(self):
        """T-3034: the counters are read at the START of each tenant's leg: a chain entry that runs on
        its own tenant gets its own read and its own file."""
        base = Path(self.tmp.name) / "repo" / "test" / "uat"
        (base / "processes").mkdir(parents=True, exist_ok=True)
        (base / "chains").mkdir(parents=True, exist_ok=True)
        step = {"id": "s1", "actor": "admin",
                "do": {"api": "POST", "path": "/api/v1/echo", "body": {"p": "x"}},
                "expect": {"status": 200}}
        for pid in ("BP-A", "BP-B"):
            (base / "processes" / f"{pid}-name.json").write_text(json.dumps({"id": pid, "steps": [step]}))
        chain = {"id": "chain-x",
                 "processes": ["BP-A",
                               {"process": "BP-B", "tenant": "other-qa", "actors": {"admin": "adm"},
                                "base_url": self.base}]}
        path = base / "chains" / "c.json"
        path.write_text(json.dumps(chain))

        code, out, err = self.main("chain", str(path), "--tenant", "qoimeks-qa2", "--base-url", self.base,
                                    "--actors", "admin=adm", "--run-dir", str(self.run_dir),
                                    "--poll-interval", "0.01")
        self.assertEqual(code, 0, out + err)

        names = sorted(p.name for p in self.run_dir.iterdir() if p.name.startswith("admission_counter_start"))
        self.assertEqual(names, ["admission_counter_start.json", "admission_counter_start_2.json"])
        self.assertEqual(self.counters("admission_counter_start_2.json")["tenant"], "other-qa")
        # the path of the file stays readable in the summary (a file name with two dots would read
        # like a JWT and the runner's own redaction would mask it)
        self.assertIn("admission_counter_start_2.json", self.summary())
        self.assertNotIn("***", self.summary().split("## Admission counters")[1].split("## Processes")[0])


if __name__ == "__main__":
    unittest.main()
