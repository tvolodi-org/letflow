"""Tests of the fixtures of scripts/uat/runner.py: they run before the steps, once per run, share the context,
clean up after the process cleanup in reverse order, are idempotent, and a failing one fails the run but still
cleans up. The static check of fixture files. A fake server on 127.0.0.1, no model.

Run: python3 -B -m unittest -v scripts/uat/tests/test_fixtures.py   (from the repository root)
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
import check_processes  # noqa: E402
import runner  # noqa: E402
from fakes import USERS, FakeServerCase  # noqa: E402

REPO = HERE.parent.parent.parent


def fx_steps(name, provides, uses=""):
    """find (optional save), make unless found, both through the fake fx routes."""
    return [
        {"id": "f1", "actor": "admin", "positional_ok": "the find is filtered by name to its own row", "do": {"api": "POST", "path": "/api/v1/fx/find", "body": {"name": name}},
         "expect": {"status": 200}, "save": {provides: {"pick": "$.items[0].record_id", "optional": True}}},
        {"id": "f2", "actor": "admin", "skip_if": [provides], "do": {"api": "POST", "path": "/api/v1/fx/make", "body": {"name": name}},
         "expect": {"status": 201}, "save": {provides: "$.record_id", f"{provides}_created": "yes"}},
    ]


def fixture(name, provides, needs=None, steps=None, inputs=None):
    doc = {"id": name, "description": f"fixture {name}", "leaves": "nothing", "provides": [provides],
           "steps": steps or fx_steps(name, provides),
           "cleanup": [{"id": "c1", "actor": "admin", "requires": [f"{provides}_created"],
                        "do": {"api": "POST", "path": "/api/v1/fx/drop", "body": {"name": name}}, "expect": {"status": 200}}]}
    if needs:
        doc["needs"] = needs
    if inputs:
        doc["inputs"] = inputs
    return doc


def process(pid="P", fixtures=("fa", "fb"), fail=False):
    steps = [{"id": "s1", "actor": "admin", "do": {"api": "POST", "path": "/api/v1/echo", "body": {"a": "${a_id}", "b": "${b_id}"}},
              "expect": {"status": 404 if fail else 200}}]
    cleanup = [{"id": "c1", "actor": "admin", "do": {"api": "POST", "path": "/api/v1/echo", "body": {"cleanup": "process"}},
                "expect": {"status": 200}}]
    return {"id": pid, "fixtures": list(fixtures), "inputs": ["a_id", "b_id"], "steps": steps, "cleanup": cleanup}


class FixtureCase(FakeServerCase):
    def setUp(self):
        super().setUp()
        self.tree = Path(self.tmp.name) / "uat"
        (self.tree / "fixtures").mkdir(parents=True)
        (self.tree / "processes").mkdir()
        self.write_fixture(fixture("fa", "a_id"))
        self.write_fixture(fixture("fb", "b_id"))

    def write_fixture(self, doc):
        (self.tree / "fixtures" / (doc["id"] + ".json")).write_text(json.dumps(doc))

    def write_process(self, doc):
        path = self.tree / "processes" / (doc["id"] + ".json")
        path.write_text(json.dumps(doc))
        return path

    def play(self, doc, run_dir=None):
        path = self.write_process(doc)
        proc = runner.load_process(path)
        fixtures = runner.fixtures_for([proc], runner.fixtures_dir_for(path))
        runner.check_chain_inputs([proc], set(), fixtures)
        out = io.StringIO()
        self.run_dir = run_dir or self.run_dir
        r = runner.Runner(proc, base_url=self.base, tenant="qoimeks-qa2", actors=USERS, run_dir=self.run_dir,
                          inputs={}, poll_interval=0.01, out=out, fixtures=fixtures)
        return r.run(), r

    def order(self):
        """cleanup calls in the order they reached the server: fx drops and the process cleanup."""
        seen = []
        for c in self.state.log:
            if c[1].endswith("/fx/drop"):
                seen.append("drop:" + c[3]["name"])
            elif c[1].endswith("/echo") and c[3] and c[3].get("cleanup"):
                seen.append("process-cleanup")
        return seen


class FixtureRunTests(FixtureCase):
    def test_fixtures_run_before_steps_and_ids_reach_the_context(self):
        code, r = self.play(process())
        self.assertEqual(code, 0)
        steps = [(x["process"], x["step"]) for x in self.lines() if x["phase"] == "step"]
        self.assertEqual(steps, [("fixture:fa", "f1"), ("fixture:fa", "f2"), ("fixture:fb", "f1"), ("fixture:fb", "f2"), ("P", "s1")])
        echo = [c for c in self.state.log if c[1].endswith("/echo") and c[3].get("a")]
        self.assertEqual(echo[0][3], {"a": "rec-fa", "b": "rec-fb"})
        ctx = json.loads((self.run_dir / "context.json").read_text())
        self.assertEqual((ctx["a_id"], ctx["b_id"]), ("rec-fa", "rec-fb"))

    def test_cleanup_runs_after_the_process_cleanup_in_reverse_order(self):
        code, _ = self.play(process())
        self.assertEqual(code, 0)
        self.assertEqual(self.order(), ["process-cleanup", "drop:fb", "drop:fa"])
        self.assertEqual(self.state.fx, {})

    def test_a_fixture_runs_once_per_run_and_needs_run_first(self):
        self.write_fixture(fixture("fb", "b_id", needs=["fa"], steps=fx_steps("fb", "b_id")))
        two = process("P1", fixtures=["fb", "fa"])
        code, _ = self.play(two)
        self.assertEqual(code, 0)
        self.assertEqual(self.state.fx_log[:2], [("make", "fa"), ("make", "fb")])
        self.assertEqual(sum(1 for x in self.state.fx_log if x == ("make", "fa")), 1)

    def test_the_second_run_reuses_what_is_there_and_deletes_nothing(self):
        self.state.fx = {"fa": "rec-fa-old", "fb": "rec-fb-old"}  # records of an earlier run that were left
        code, _ = self.play(process())
        self.assertEqual(code, 0)
        self.assertEqual(self.state.fx_log, [])  # nothing made, nothing dropped: it did not create them
        echo = [c for c in self.state.log if c[1].endswith("/echo") and c[3].get("a")]
        self.assertEqual(echo[0][3], {"a": "rec-fa-old", "b": "rec-fb-old"})
        verdicts = {(x["process"], x["step"]): x["verdict"] for x in self.lines() if x["phase"] == "step"}
        self.assertEqual(verdicts[("fixture:fa", "f2")], "skipped")

    def test_two_runs_in_a_row_make_once_when_cleanup_cannot_remove(self):
        # a fixture whose cleanup does not drop (a retired card stays): the second run finds it by its reference
        keep = fixture("fa", "a_id")
        keep["cleanup"][0]["do"]["path"] = "/api/v1/echo"
        keep["cleanup"][0]["do"]["body"] = {"cleanup": "keep"}
        self.write_fixture(keep)
        self.assertEqual(self.play(process(fixtures=["fa", "fb"]))[0], 0)
        self.assertEqual(self.play(process(fixtures=["fa", "fb"]), run_dir=Path(self.tmp.name) / "run2")[0], 0)
        self.assertEqual([x for x in self.state.fx_log if x[1] == "fa"], [("make", "fa")])

    def test_a_failing_fixture_fails_the_run_and_still_cleans_up(self):
        bad = fixture("fb", "b_id")
        bad["steps"][1]["expect"] = {"status": 500}  # the make answers 201: a failed step after the first fixture
        self.write_fixture(bad)
        code, _ = self.play(process())
        self.assertEqual(code, 1)
        v = {(x["process"], x["step"]): x["verdict"] for x in self.lines() if x["phase"] == "step"}
        self.assertEqual(v[("fixture:fb", "f2")], "fail")
        self.assertEqual(v[("P", "-")], "skipped")
        self.assertNotIn(("P", "s1"), v)
        # fb's own record was made though its step failed: no `created` mark, so nothing of fb is dropped; fa is
        self.assertEqual(self.order(), ["drop:fa"])

    def test_a_fixture_that_does_not_provide_its_name_fails(self):
        liar = fixture("fb", "b_id")
        liar["provides"] = ["b_id", "never_saved"]
        self.write_fixture(liar)
        code, _ = self.play(process())
        self.assertEqual(code, 1)
        self.assertIn("never_saved", json.dumps(self.lines()))

    def test_a_refused_create_fails_the_fixture(self):
        self.state.fx_make_status = 422
        code, _ = self.play(process())
        self.assertEqual(code, 1)
        self.assertEqual(self.order(), [])

    def test_the_process_failing_still_runs_every_cleanup(self):
        code, _ = self.play(process(fail=True))
        self.assertEqual(code, 1)
        self.assertEqual(self.order(), ["process-cleanup", "drop:fb", "drop:fa"])

    def test_the_cleanup_replay_of_an_aborted_run_covers_fixtures(self):
        self.play(process())
        entries = json.loads((self.run_dir / "cleanup.json").read_text())
        self.assertEqual([e["process"] for e in entries], ["fixture:fa", "fixture:fb", "P"])


class FixtureLoadTests(FixtureCase):
    def test_an_unknown_fixture_name_is_exit_2_before_anything_runs(self):
        path = self.write_process(process(fixtures=["fa", "nope"]))
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code = runner.main(["run", str(path), "--tenant", "qoimeks-qa2", "--actors", "admin=u",
                                "--base-url", self.base, "--run-dir", str(self.run_dir), "--no-stable-check"])
        self.assertEqual(code, 2)
        self.assertIn("unknown fixture 'nope'", err.getvalue())
        self.assertEqual(self.state.log, [])

    def test_a_cycle_and_a_name_with_a_slash_are_refused(self):
        self.write_fixture(fixture("fa", "a_id", needs=["fb"]))
        self.write_fixture(fixture("fb", "b_id", needs=["fa"]))
        with self.assertRaises(runner.ConfigError):
            runner.expand_fixtures(["fa"], self.tree / "fixtures")
        with self.assertRaises(runner.ConfigError):
            runner.expand_fixtures(["../processes/P"], self.tree / "fixtures")

    def test_a_fixture_file_needs_description_leaves_and_provides(self):
        for key in ("description", "leaves", "provides"):
            doc = fixture("fa", "a_id")
            del doc[key]
            self.write_fixture(doc)
            with self.assertRaises(runner.ConfigError, msg=key):
                runner.load_fixture(self.tree / "fixtures" / "fa.json")

    def test_run_end_to_end_through_the_cli(self):
        path = self.write_process(process())
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = runner.main(["run", str(path), "--tenant", "qoimeks-qa2", "--actors", "admin=" + USERS["admin"],
                                "--base-url", self.base, "--run-dir", str(self.run_dir), "--no-stable-check", "--poll-interval", "0.01"])
        self.assertEqual(code, 0, out.getvalue())
        self.assertEqual(self.order(), ["process-cleanup", "drop:fb", "drop:fa"])


class FixtureStaticCheckTests(FixtureCase):
    def check(self, *files):
        return check_processes.check_files([Path(f) for f in files], root=self.tree)

    def test_the_good_tree_has_no_problem(self):
        path = self.write_process(process())
        self.assertEqual(self.check(path, self.tree / "fixtures" / "fa.json"), [])

    def test_unknown_fixture_in_a_process(self):
        path = self.write_process(process(fixtures=["fa", "nope"]))
        self.assertTrue(any("unknown fixture 'nope'" in p for p in self.check(path)))

    def test_a_name_no_fixture_or_input_provides_is_reported(self):
        doc = process(fixtures=["fa"])  # b_id is an input of the process but fb is not listed: it is an input, so fine
        doc["inputs"] = ["a_id"]
        doc["steps"][0]["do"]["body"] = {"x": "${b_id}"}
        path = self.write_process(doc)
        self.assertTrue(any("${b_id}" in p for p in self.check(path)))
        doc["fixtures"] = ["fa", "fb"]
        path = self.write_process(doc)
        self.assertEqual(self.check(path), [])

    def test_provides_must_be_saved_and_cleanup_needs_requires(self):
        doc = fixture("fa", "a_id")
        doc["provides"] = ["a_id", "ghost"]
        del doc["cleanup"][0]["requires"]
        self.write_fixture(doc)
        problems = self.check(self.tree / "fixtures" / "fa.json")
        self.assertTrue(any("provides 'ghost'" in p for p in problems), problems)
        self.assertTrue(any("needs `requires`" in p for p in problems), problems)

    def test_a_fixture_reading_a_name_nobody_provides(self):
        doc = fixture("fa", "a_id")
        doc["steps"][0]["do"]["body"] = {"name": "${y}"}
        self.write_fixture(doc)
        self.assertTrue(any("${y}" in p for p in self.check(self.tree / "fixtures" / "fa.json")))
        doc["inputs"] = ["y"]  # an input of the fixture is fine statically; the run checks it is given
        self.write_fixture(doc)
        self.assertEqual(self.check(self.tree / "fixtures" / "fa.json"), [])

    def test_a_missing_fixture_input_stops_before_the_run(self):
        self.write_fixture(fixture("fa", "a_id", inputs=["org"]))
        proc = runner.load_process(self.write_process(process(fixtures=["fa"])))
        fixtures = runner.fixtures_for([proc], self.tree / "fixtures")
        with self.assertRaises(runner.ConfigError):
            runner.check_chain_inputs([proc], set(), fixtures)

    def test_the_shipped_asset_fixtures_pass_the_static_check(self):
        files = sorted((REPO / "test/uat/fixtures").glob("*.json"))
        self.assertEqual({f.stem for f in files} >= {"asset_card", "asset_opening_doc", "second_place"}, True)
        self.assertEqual(check_processes.check_files(files, root=REPO), [])
        for f in files:
            runner.load_fixture(f)
        order = [d["id"] for d in runner.expand_fixtures(["asset_opening_doc"], REPO / "test/uat/fixtures")]
        self.assertEqual(order, ["asset_card", "asset_opening_doc"])


class SecondPlaceFixtureTests(FakeServerCase):
    FIXTURE = REPO / "test/uat/fixtures/second_place.json"

    def play(self, run_dir=None):
        fixture = runner.load_fixture(self.FIXTURE)
        process = {"id": "P", "steps": [{"id": "s1", "actor": "admin",
                   "do": {"api": "POST", "path": "/api/v1/echo",
                          "body": {"from": "${place_from}", "to": "${place_to}"}}, "expect": {"status": 200}}]}
        self.run_dir = run_dir or self.run_dir
        r = runner.Runner(process, base_url=self.base, tenant="qoimeks-qa2", actors=USERS, run_dir=self.run_dir,
                          inputs={"place": "source-place", "org_unit": "org-1"}, poll_interval=0.01,
                          out=io.StringIO(), fixtures=[fixture])
        return r.run(), r

    def test_two_runs_create_a_fresh_place_after_retiring_the_first(self):
        code, first = self.play()
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        first_id = first.ctx["place_to"]
        self.assertEqual(first.ctx["place_from"], "source-place")
        self.assertFalse(self.state.location_nodes[first_id]["active"])
        code, second = self.play(Path(self.tmp.name) / "run2")
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        second_id = second.ctx["place_to"]
        self.assertNotEqual(second_id, first_id)  # the retired fixture cannot be un-retired
        self.assertFalse(self.state.location_nodes[second_id]["active"])
        echo = [c[3] for c in self.state.calls("POST", "/echo") if c[3] and "from" in c[3]]
        self.assertEqual(echo, [{"from": "source-place", "to": first_id},
                                {"from": "source-place", "to": second_id}])

    def test_an_existing_active_place_and_link_are_left_in_place(self):
        marker = "UAT-FIX-second_place-qoimeks-qa2"
        self.state.location_nodes["existing"] = {"record_id": "existing", "active": True,
                                                 "external_ref_system": marker}
        self.state.location_links["existing-link"] = {"record_id": "existing-link", "active": True,
                                                      "location_id": "existing", "org_unit_id": "org-1"}
        code, run = self.play()
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        self.assertEqual(run.ctx["place_to"], "existing")
        self.assertTrue(self.state.location_nodes["existing"]["active"])
        self.assertTrue(self.state.location_links["existing-link"]["active"])
        self.assertEqual(len(self.state.location_nodes), 1)


if __name__ == "__main__":
    unittest.main()
