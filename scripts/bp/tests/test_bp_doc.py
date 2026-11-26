"""Tests of scripts/bp/bp_doc.py (D-173): the business-process map rendered in plain words.

The tests run on a small fake checkout (no network, no database, no model): a fixture map of
three processes, an orphan file, a runner scenario and a runner verdict file. The last test
runs the check on the REAL checkout: the committed `docs/bp/<area>.md` must equal the render
of the committed maps -- the gate the CI runs.

Run: python3 -B -m unittest -v scripts/bp/tests/test_bp_doc.py   (from the repository root)
"""

import contextlib
import io
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import bp_doc  # noqa: E402

FIXTURE = HERE / "fixtures" / "bp"
ROOT = HERE.parents[2]


class ToolCase(unittest.TestCase):
    """A copy of the fixture checkout the tool runs on."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="bp-doc-test-"))
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.root = self.dir / "proj"
        shutil.copytree(FIXTURE, self.root)

    def run_tool(self, *args):
        """Run the tool on the fixture; returns (exit code, stdout)."""
        argv = ["--root", str(self.root)] + list(args)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = bp_doc.main(argv)
        return code, out.getvalue()

    def render(self, area="demo"):
        """The document of the area, as the tool writes it."""
        code, out = self.run_tool(area)
        self.assertEqual(code, 0, out)
        return (self.root / "docs/bp" / f"{area}.md").read_text(encoding="utf-8")

    def map_of(self, area="demo"):
        path = self.root / "docs/bp" / f"{area}.json"
        return json.loads(path.read_text(encoding="utf-8"))

    def write_map(self, entries, area="demo"):
        path = self.root / "docs/bp" / f"{area}.json"
        path.write_text(json.dumps(entries, indent=2), encoding="utf-8")


class Render(ToolCase):
    def test_the_fixture_map_renders_to_the_expected_document(self):
        expected = (FIXTURE / "expected/demo.md").read_text(encoding="utf-8")
        self.assertEqual(self.render(), expected)

    def test_the_document_is_written_next_to_the_map(self):
        code, out = self.run_tool("demo")
        self.assertEqual(code, 0, out)
        self.assertIn("wrote docs/bp/demo.md", out)
        self.assertTrue((self.root / "docs/bp/demo.md").is_file())

    def test_two_runs_give_the_same_bytes(self):
        first = self.render()
        second = self.render()
        self.assertEqual(first, second)

    def test_the_table_holds_every_process_with_its_status_and_actors(self):
        text = self.render()
        self.assertIn(
            "| id | name | in one line | actors | status | executed by | scenario | security | machine-proven |",
            text,
        )
        self.assertIn("| BP-DEMO-01 | Receive goods |", text)
        self.assertIn("| STOREKEEPER, TENANT_ADMIN | implemented | direct | no | yes | see report |", text)
        self.assertIn("| BP-DEMO-02 | Security: another company's card is not reachable |", text)
        self.assertIn("| BP-DEMO-03 | Export the balances of a place |", text)

    def test_the_executed_by_column_names_the_definition_and_reads_a_missing_field_as_direct(self):
        text = self.render()
        # BP-DEMO-01 names a definition; BP-DEMO-02 has no field at all: it is `direct`.
        self.assertIn("| implemented | definition:demo.receive_goods | yes | no | see report |", text)
        self.assertIn("| implemented | direct | no | yes | see report |", text)
        self.assertIn("| planned | direct | no | no | see report |", text)

    def test_the_head_of_the_document_counts_the_direct_and_the_definition_processes(self):
        text = self.render()
        self.assertIn("Executed by: 2 direct, 1 definition.", text)

    def test_a_process_is_rendered_with_its_steps_refusals_tests_and_scenario(self):
        text = self.render()
        self.assertIn("## BP-DEMO-01 -- Receive goods", text)
        self.assertIn("- `STOREKEEPER` -- StockPost", text)
        self.assertIn("1. **STOREKEEPER**: screen `admin/stock/documents/new`, call `POST /api/v1/modules/stock/documents`", text)
        self.assertIn("Result: a draft receipt with a document id", text)
        self.assertIn("- a role without StockPost is refused with 403", text)
        self.assertIn("- `test/letflow/modules/stock/router_test.exs`", text)
        self.assertIn("- `test/uat/processes/DEMO-01.json` (runner id `DEMO-01`)", text)

    def test_the_orphan_rows_of_the_area_are_rendered(self):
        text = self.render()
        self.assertIn("## Orphans (docs/bp/orphans-demo.md)", text)
        self.assertIn("Letflow.Demo.Helpers.old_place", text)
        self.assertIn("give a process", text)

    def test_the_gaps_of_the_area_are_rendered(self):
        text = self.render()
        self.assertIn("## Gaps of the area", text)
        self.assertIn("no runner scenario yet", text)
        self.assertIn("BP-DEMO-03", text)


class Check(ToolCase):
    def test_the_check_passes_when_the_document_equals_the_render(self):
        self.run_tool("all")
        code, out = self.run_tool("--check")
        self.assertEqual(code, 0, out)
        self.assertIn("bp_doc --check: PASS", out)

    def test_the_check_fails_after_a_manual_edit_of_the_document(self):
        self.run_tool("all")
        path = self.root / "docs/bp/demo.md"
        path.write_text(path.read_text(encoding="utf-8") + "\nA line a writer added by hand.\n", encoding="utf-8")
        code, out = self.run_tool("--check")
        self.assertEqual(code, 1)
        self.assertIn("docs/bp/demo.md: differs from the render", out)
        self.assertIn("A line a writer added by hand.", out)  # the difference is shown
        self.assertIn("bp_doc --check: FAIL", out)

    def test_the_check_fails_after_a_change_of_the_map(self):
        self.run_tool("all")
        entries = self.map_of()
        entries[0]["title"] = "Receive the goods"
        self.write_map(entries)
        code, out = self.run_tool("--check")
        self.assertEqual(code, 1)
        self.assertIn("docs/bp/demo.md: differs from the render", out)
        self.assertIn("Receive the goods", out)  # the difference is shown
        self.assertIn("bp_doc --check: FAIL", out)

    def test_the_check_fails_when_a_map_has_no_document(self):
        self.run_tool("all")
        (self.root / "docs/bp/demo.md").unlink()
        code, out = self.run_tool("--check")
        self.assertEqual(code, 1)
        self.assertIn("docs/bp/demo.md: missing", out)
        self.assertIn("bp_doc --check: FAIL", out)

    def test_the_check_of_one_area_leaves_the_other_alone(self):
        self.run_tool("all")
        path = self.root / "docs/bp/demo.md"
        path.write_text(path.read_text(encoding="utf-8") + "\nA line a writer added by hand.\n", encoding="utf-8")
        code, out = self.run_tool("--check", "other")
        self.assertEqual(code, 0, out)
        self.assertIn("bp_doc --check: PASS", out)

    def test_an_unknown_area_is_a_usage_error(self):
        code, _out = self.run_tool("nonsense")
        self.assertEqual(code, 2)


class Proof(ToolCase):
    def test_the_proof_column_is_filled_from_the_verdict_files(self):
        code, out = self.run_tool("demo", "--proof", str(FIXTURE / "verdicts"))
        self.assertEqual(code, 0, out)
        self.assertIn("| BP-DEMO-01 | Receive goods |", out)
        self.assertIn("PASS on abc1234 2026-11-20", out)

    def test_the_static_render_points_at_the_report(self):
        self.assertIn("see report", self.render())

    def test_the_proof_mode_never_writes_into_the_checkout(self):
        code, _out = self.run_tool("demo", "--proof", str(FIXTURE / "verdicts"))
        self.assertEqual(code, 0)
        self.assertFalse((self.root / "docs/bp/demo.md").exists())

    def test_the_proof_mode_refuses_to_write_inside_the_checkout(self):
        code, _out = self.run_tool(
            "demo", "--proof", str(FIXTURE / "verdicts"), "--out", str(self.root / "docs/bp/demo.md")
        )
        self.assertEqual(code, 2)
        self.assertFalse((self.root / "docs/bp/demo.md").exists())


class Product(unittest.TestCase):
    """The committed documents of the product must equal the render of the committed maps."""

    def test_the_committed_documents_equal_the_render(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = bp_doc.main(["--root", str(ROOT), "--check"])
        self.assertEqual(code, 0, out.getvalue())


if __name__ == "__main__":
    unittest.main()
