"""Tests of scripts/bp/dead_code.py (D-172): the function-level dead-code inventory.

The tests run on a fixture project (no network, no database, no mix): the source of the
fixture is scanned and a fixture xref dump stands for the call graph of `mix xref`. The
last test runs the real `mix xref` dump on the fixture project (it is skipped when mix
is not on PATH).

Run: python3 -B -m unittest -v scripts/bp/tests/test_dead_code.py   (from the repository root)
"""

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import dead_code  # noqa: E402

FIXTURE = HERE / "fixtures" / "proj"
XREF = HERE / "fixtures" / "xref-calls.json"


class ToolCase(unittest.TestCase):
    """A copy of the fixture project the tool runs on."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="dead-code-test-"))
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.root = self.dir / "proj"
        shutil.copytree(FIXTURE, self.root)

    def run_tool(self, *args):
        """Run the tool on the fixture; returns (exit code, stdout)."""
        argv = ["--root", str(self.root), "--xref-file", str(XREF)] + list(args)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = dead_code.main(argv)
        return code, out.getvalue()

    def report(self, *args):
        code, _out = self.run_tool(*args)
        self.assertEqual(code, 0)
        return json.loads((self.root / "docs/bp/dead-code.json").read_text(encoding="utf-8"))

    def entry(self, report, module, function):
        for item in report["functions"]:
            if item["module"] == module and item["function"] == function:
                return item
        return None


class Inventory(ToolCase):
    def test_a_public_function_without_a_caller_is_no_caller(self):
        report = self.report()
        entry = self.entry(report, "Alpha.Worker", "nobody_calls")
        self.assertIsNotNone(entry, "the function nobody calls must be reported")
        self.assertEqual(entry["reason"], "no_caller")
        self.assertEqual(entry["arity"], 0)
        self.assertEqual(entry["file"], "lib/letflow/alpha/worker.ex")
        self.assertEqual(entry["kind"], "def")
        self.assertTrue(entry["line"] > 0)

    def test_a_private_function_is_not_in_the_report(self):
        report = self.report()
        self.assertIsNone(self.entry(report, "Alpha.Worker", "private_helper"))

    def test_a_function_called_only_from_a_test_is_test_only(self):
        report = self.report()
        entry = self.entry(report, "Alpha.Worker", "only_in_test")
        self.assertIsNotNone(entry, "a function only a test calls must be reported")
        self.assertEqual(entry["reason"], "test_only")

    def test_a_function_called_from_lib_is_not_reported(self):
        report = self.report()
        self.assertIsNone(self.entry(report, "Alpha.Worker", "used_by_consumer"))

    def test_a_caller_from_the_xref_graph_counts(self):
        # Alpha.Remote.only_in_graph is called nowhere in the source: only the xref dump
        # knows the caller, so the tool must not report it.
        report = self.report()
        self.assertIsNone(self.entry(report, "Alpha.Remote", "only_in_graph"))

    def test_a_delegate_calls_the_function_it_delegates_to(self):
        # Alpha.Worker.delegated/0 delegates to Alpha.Remote.delegated/0
        report = self.report()
        self.assertIsNone(self.entry(report, "Alpha.Remote", "delegated"))

    def test_an_impl_is_not_reported(self):
        report = self.report()
        self.assertIsNone(self.entry(report, "Beta.Worker", "init"))
        self.assertIsNone(self.entry(report, "Beta.Worker", "handle_call"))

    def test_a_public_function_of_a_behaviour_module_is_reported(self):
        report = self.report()
        entry = self.entry(report, "Beta.Worker", "orphan")
        self.assertIsNotNone(entry, "a public function nobody calls must be reported")
        self.assertEqual(entry["reason"], "no_caller")

    def test_apply_with_a_variable_is_a_dynamic_call_site(self):
        report = self.report()
        kinds = {(site["file"], site["line"], site["kind"]) for site in report["dynamic_call_sites"]}
        self.assertIn(("lib/letflow/beta/dynamic.ex", 5, "apply_variable"), kinds)

    def test_a_function_of_a_dynamic_target_is_dynamic_suspect(self):
        # apply(Beta.LineEvents, operation, args): the module is known, the function is
        # not, so the tool cannot prove that the functions of the module are dead.
        report = self.report()
        entry = self.entry(report, "Beta.LineEvents", "unused_helper")
        self.assertIsNotNone(entry)
        self.assertEqual(entry["reason"], "dynamic_suspect")

    def test_the_summary_counts_per_area_and_per_reason(self):
        report = self.report()
        summary = report["summary"]
        self.assertEqual(summary["total"], len(report["functions"]))
        self.assertEqual(sum(summary["by_area"].values()), summary["total"])
        self.assertEqual(sum(summary["by_reason"].values()), summary["total"])
        self.assertEqual(summary["by_reason"]["no_caller"], 6)   # nobody_calls, orphan, ...
        self.assertEqual(summary["by_reason"]["test_only"], 1)   # only_in_test
        self.assertEqual(summary["by_reason"]["dynamic_suspect"], 2)  # the LineEvents module

    def test_the_area_of_a_file_no_area_owns_is_unassigned(self):
        report = self.report()
        entry = self.entry(report, "Alpha.Worker", "nobody_calls")
        self.assertEqual(entry["area"], "unassigned")


class AllowList(ToolCase):
    def test_an_allowed_function_is_not_reported(self):
        allow = self.root / "docs/bp/dead-code-allow.json"
        allow.parent.mkdir(parents=True, exist_ok=True)
        allow.write_text(json.dumps([
            {"module": "Alpha.Worker", "function": "nobody_calls", "arity": 0,
             "reason": "kept for the next requirement"},
        ]), encoding="utf-8")
        report = self.report()
        self.assertIsNone(self.entry(report, "Alpha.Worker", "nobody_calls"))

    def test_the_tool_never_writes_the_allow_list(self):
        allow = self.root / "docs/bp/dead-code-allow.json"
        allow.parent.mkdir(parents=True, exist_ok=True)
        text = json.dumps([{"module": "Alpha.Worker", "function": "nobody_calls",
                            "arity": 0, "reason": "kept"}])
        allow.write_text(text, encoding="utf-8")
        self.run_tool()
        self.assertEqual(allow.read_text(encoding="utf-8"), text)

    def test_an_allow_entry_without_a_reason_is_an_error(self):
        allow = self.root / "docs/bp/dead-code-allow.json"
        allow.parent.mkdir(parents=True, exist_ok=True)
        allow.write_text(json.dumps([{"module": "Alpha.Worker", "function": "nobody_calls"}]),
                         encoding="utf-8")
        _code, out = self.run_tool()
        self.assertIn("a reason is required", out)


class Baseline(ToolCase):
    def write_baseline(self, entries):
        path = self.root / "docs/bp/dead-code-baseline.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(entries, indent=1, sort_keys=True) + "\n", encoding="utf-8")

    def test_the_check_passes_when_every_dead_function_is_in_the_baseline(self):
        report = self.report()
        self.write_baseline(report["functions"])
        code, out = self.run_tool("--check")
        self.assertEqual(code, 0, out)
        self.assertIn("dead_code --check: PASS", out)

    def test_the_check_fails_on_a_new_dead_function(self):
        report = self.report()
        self.write_baseline(report["functions"])
        worker = self.root / "lib/letflow/alpha/worker.ex"
        text = worker.read_text(encoding="utf-8")
        worker.write_text(text.replace("\nend\n", "\n  def brand_new, do: :new\nend\n"),
                          encoding="utf-8")
        code, out = self.run_tool("--check")
        self.assertEqual(code, 1, out)
        self.assertIn("dead_code --check: FAIL", out)
        self.assertIn("Alpha.Worker.brand_new", out)

    def test_the_check_passes_when_a_dead_function_is_gone(self):
        report = self.report()
        self.write_baseline(report["functions"])
        worker = self.root / "lib/letflow/alpha/worker.ex"
        worker.write_text(worker.read_text(encoding="utf-8").replace(
            "  def nobody_calls do\n    :nobody\n  end\n\n", ""), encoding="utf-8")
        code, out = self.run_tool("--check")
        self.assertEqual(code, 0, out)

    def test_the_check_does_not_write_the_report(self):
        report = self.report()
        self.write_baseline(report["functions"])
        before = (self.root / "docs/bp/dead-code.json").read_bytes()
        self.run_tool("--check")
        self.assertEqual((self.root / "docs/bp/dead-code.json").read_bytes(), before)


class Determinism(ToolCase):
    def test_two_runs_give_the_same_bytes(self):
        self.run_tool()
        first = (self.root / "docs/bp/dead-code.json").read_bytes()
        self.run_tool()
        second = (self.root / "docs/bp/dead-code.json").read_bytes()
        self.assertEqual(first, second)

    def test_the_report_is_sorted(self):
        report = self.report()
        keys = [(f["area"], f["module"], f["function"], f["arity"]) for f in report["functions"]]
        self.assertEqual(keys, sorted(keys))


class NoWrites(ToolCase):
    def test_the_tool_changes_nothing_in_lib(self):
        before = {p: p.read_bytes() for p in sorted(self.root.rglob("lib/**/*")) if p.is_file()}
        self.run_tool()
        after = {p: p.read_bytes() for p in sorted(self.root.rglob("lib/**/*")) if p.is_file()}
        self.assertEqual(before, after)


class XrefDump(unittest.TestCase):
    """The real `mix xref` dump of a small project (no network, no database)."""

    def test_the_dump_of_the_fixture_project_lists_the_calls(self):
        if not shutil.which("mix"):
            self.skipTest("mix is not on PATH")
        work = Path(tempfile.mkdtemp(prefix="dead-code-xref-"))
        self.addCleanup(shutil.rmtree, work, True)
        project = work / "proj"
        shutil.copytree(FIXTURE, project)
        script = project / "scripts" / "bp" / "xref_calls.exs"
        script.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(HERE.parent / "xref_calls.exs", script)
        dump = project / "_build" / "xref-calls.json"
        env = dict(os.environ, LETFLOW_XREF_OUT=str(dump))
        done = subprocess.run(["mix", "run", "--no-start", str(script)], cwd=str(project),
                              capture_output=True, text=True, timeout=240, env=env, check=False)
        self.assertEqual(done.returncode, 0, done.stderr[-2000:])
        calls = json.loads(dump.read_text(encoding="utf-8"))
        callees = {call["callee"] for call in calls}
        self.assertIn("Alpha.Worker.used_by_consumer", callees)
        for call in calls:
            self.assertIn("file", call)
            self.assertIn("line", call)
            self.assertIsInstance(call["arity"], int)


if __name__ == "__main__":
    unittest.main()
