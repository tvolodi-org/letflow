"""T-2543: the chain coverage rule of check_catalog.py (every SEC file in exactly one of rc-sss / rc-sec)."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "check_catalog", Path(__file__).resolve().parents[1] / "check_catalog.py")
cc = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(cc)


def run_rule(sec, chains):
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        (root / "test/uat/processes").mkdir(parents=True)
        (root / "test/uat/chains").mkdir(parents=True)
        for s in sec:
            (root / "test/uat/processes" / f"{s}.json").write_text("{}")
        for name, entries in chains.items():
            (root / "test/uat/chains" / f"{name}.json").write_text(json.dumps({"processes": entries}))
        errors = []
        cc.check_chain_coverage(root, errors)
        return errors


class ChainCoverage(unittest.TestCase):
    def test_ok_with_string_and_object_entries(self):
        self.assertEqual(run_rule(["SEC-A-01-x", "SEC-A-02-y"],
                                  {"rc-sss": ["SEC-A-01"], "rc-sec": [{"process": "SEC-A-02"}]}), [])

    def test_missing(self):
        errs = run_rule(["SEC-A-01-x", "SEC-A-02-y"], {"rc-sss": ["SEC-A-01"], "rc-sec": []})
        self.assertEqual(len(errs), 1)
        self.assertIn("SEC-A-02-y.json", errs[0])

    def test_duplicate(self):
        errs = run_rule(["SEC-A-01-x"], {"rc-sss": ["SEC-A-01"], "rc-sec": [{"process": "SEC-A-01"}]})
        self.assertEqual(len(errs), 1)
        self.assertIn("more than one", errs[0])

    def test_unknown_entry(self):
        errs = run_rule(["SEC-A-01-x"], {"rc-sss": ["SEC-A-01", "SEC-Q-09"], "rc-sec": []})
        self.assertEqual(len(errs), 1)
        self.assertIn("SEC-Q-09", errs[0])


if __name__ == "__main__":
    unittest.main()
