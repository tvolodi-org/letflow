"""Tests of the M1 core of scripts/uat/runner.py: chains with a shared context, cleanup (reverse order,
replay of an aborted run), preflight, the step kinds, the log. A fake server on 127.0.0.1, no model.

Run: python3 -B -m unittest -v scripts/uat/tests/test_chain.py   (from the repository root)
"""

import contextlib
import io
import json
import os
import stat
import sys
import unittest
from decimal import Decimal
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import runner  # noqa: E402
from fakes import INPUTS, PROCESS_FILE, SECRET, SHARED_VALUE, USERS, FakeServerCase  # noqa: E402


def call(sid, method, path, body=None, expect=None, actor="admin", **extra):
    do = {"api": method, "path": path}
    if body is not None:
        do["body"] = body
    step = {"id": sid, "actor": actor, "do": do, "expect": expect if expect is not None else {"status": 200}}
    step.update(extra)
    return step


def proc(pid, steps, cleanup=None, inputs=None, outputs=None, defaults=None):
    doc = {"id": pid, "steps": steps}
    for key, value in (("cleanup", cleanup), ("inputs", inputs), ("outputs", outputs), ("defaults", defaults)):
        if value:
            doc[key] = value
    return doc


def tagged(pid, tag, fail_after=False):
    """A process that saves who=<tag> and whose cleanup posts {cleanup: ${who}} to the echo route."""
    steps = [call("s1", "POST", "/api/v1/echo", {"step": pid}, save={"who": tag})]
    if fail_after:
        steps.append(call("s2", "POST", "/api/v1/echo", {"step": pid}, {"status": 404}))
    cleanup = [{"id": "c1", "actor": "admin", "requires": ["who"],
                "do": {"api": "POST", "path": "/api/v1/echo", "body": {"cleanup": "${who}"}}, "expect": {"status": 200}}]
    return proc(pid, steps, cleanup, outputs={f"out_{tag}": "${who}"})


class ChainCase(FakeServerCase):
    def keyed(self):
        return {(x["process"], x["phase"], x["step"]): x["verdict"] for x in self.lines()}

    def cleanups(self):
        return [c[3]["cleanup"] for c in self.state.calls("POST", "/echo") if c[3] and "cleanup" in c[3]]

    def stable_script(self, text):
        path = Path(self.team_root) / "project" / "scripts" / "qa_stable.sh"
        path.write_text(text)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return path


class Chains(ChainCase):
    def test_outputs_of_one_process_are_inputs_of_the_next_and_cleanup_waits_for_the_end(self):
        reader = proc("BP-X", [call("s1", "GET", "/api/v1/modules/stock/documents/${receipt_doc_id}",
                                    expect={"status": 200, "json": {"state": "posted"}})],
                      inputs=["receipt_doc_id"], outputs={"seen": "${receipt_doc_id}"})
        code, _ = self.run_process([runner.load_process(PROCESS_FILE), reader], inputs=INPUTS,
                                   pass_map={"BP-01": ["receipt_doc_id"]})
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        keyed = self.keyed()
        self.assertEqual(keyed[("BP-X", "step", "s1")], "pass")  # the receipt was still posted: BP-01 had not cleaned up yet
        self.assertEqual(self.state.qty, Decimal("7"))  # the end of the chain reversed it
        self.assertEqual(len(self.state.calls("POST", "/reverse")), 1)
        paths = [c[1] for c in self.state.log]
        self.assertLess(paths.index("/api/v1/modules/stock/documents/doc-1"),
                        next(i for i, p in enumerate(paths) if p.endswith("/reverse")))
        ctx = json.loads((self.run_dir / "context.json").read_text())
        self.assertEqual((ctx["receipt_doc_id"], ctx["seen"]), ("doc-1", "doc-1"))

    def test_a_missing_input_that_no_earlier_process_gives_is_an_error_of_that_process(self):
        reader = proc("BP-X", [call("s1", "GET", "/api/v1/echo")], inputs=["receipt_doc_id"])
        code, _ = self.run_process([reader], inputs={})
        self.assertEqual(code, 1)
        self.assertEqual(self.keyed()[("BP-X", "inputs", "inputs")], "error")
        self.assertEqual(self.state.calls("GET", "/echo"), [])

    def test_only_outputs_named_by_pass_reach_the_next_process(self):
        reader = proc("BP-R", [call("s1", "POST", "/api/v1/echo", {"receipt": "${out_A}"})],
                      inputs=["out_A"], cleanup=[{"id": "c1", "actor": "admin", "requires": ["who"],
                      "do": {"api": "POST", "path": "/api/v1/echo", "body": {"cleanup": "wrong-context"}},
                      "expect": {"status": 200}}])
        code, _ = self.run_process([tagged("PA", "A"), reader], inputs={})
        self.assertEqual(code, 1)  # no pass list: even out_A is not an input of BP-R
        self.assertEqual(self.keyed()[("BP-R", "inputs", "inputs")], "error")

        self.run_dir = self.run_dir.parent / "run-pass"
        self.state.log.clear()
        code, _ = self.run_process([tagged("PA", "A"), reader], inputs={}, pass_map={"PA": ["out_A"]})
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        self.assertEqual(self.keyed()[("BP-R", "step", "s1")], "pass")
        # `who` is PA's private working value, not an output: BP-R's cleanup must not inherit it.
        skipped = next(x for x in self.lines() if x["process"] == "BP-R" and x["phase"] == "cleanup")
        self.assertEqual((skipped["verdict"], skipped["error"]), ("skipped", "requires who"))
        self.assertEqual(self.cleanups(), ["A"])

    def test_a_cleanup_with_requires_skips_and_names_every_missing_value(self):
        process = proc("PA", [call("s1", "POST", "/api/v1/echo", {}, save={"own": "yes"})],
                       cleanup=[{"id": "c1", "actor": "admin", "requires": ["own", "balance_to_before"],
                                 "do": {"api": "POST", "path": "/api/v1/echo", "body": {"cleanup": "bad"}},
                                 "expect": {"status": 200}}])
        code, _ = self.run_process(process, inputs={})
        self.assertEqual(code, 0)
        line = next(x for x in self.lines() if x["phase"] == "cleanup")
        self.assertEqual((line["verdict"], line["error"]), ("skipped", "requires balance_to_before"))
        self.assertEqual(self.cleanups(), [])

    def test_cleanups_run_in_reverse_order_each_with_its_own_context(self):
        code, _ = self.run_process([tagged("PA", "A"), tagged("PB", "B"), tagged("PC", "C")], inputs={})
        self.assertEqual(code, 0)
        # B overwrote `who` after A: A still cleans up with its own value
        self.assertEqual(self.cleanups(), ["C", "B", "A"])
        ctx = json.loads((self.run_dir / "context.json").read_text())
        self.assertEqual((ctx["out_A"], ctx["out_B"], ctx["out_C"]), ("A", "B", "C"))

    def test_the_same_chain_can_run_twice_without_residue(self):
        process = runner.load_process(PROCESS_FILE)
        code, _ = self.run_process(process, inputs=INPUTS)
        self.assertEqual(code, 0)
        self.assertEqual(self.state.qty, Decimal("7"))
        self.run_dir = self.run_dir.parent / "run-second"
        code, _ = self.run_process(process, inputs=INPUTS)
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        self.assertEqual(self.state.qty, Decimal("7"))
        self.assertEqual(len(self.state.calls("POST", "/reverse")), 2)

    def test_a_failing_process_stops_the_chain_and_the_cleanup_of_the_ones_already_run_still_happens(self):
        code, _ = self.run_process([tagged("PA", "A"), tagged("PB", "B", fail_after=True), tagged("PC", "C")], inputs={})
        self.assertEqual(code, 1)
        keyed = self.keyed()
        self.assertEqual(keyed[("PB", "step", "s2")], "fail")
        self.assertEqual(keyed[("PC", "step", "-")], "skipped")
        self.assertEqual(self.cleanups(), ["B", "A"])  # PC never started: no cleanup; the rest in reverse
        summary = (self.run_dir / "summary.md").read_text()
        self.assertIn("SKIPPED", summary)

    def test_keep_going_runs_the_next_process_after_a_failure(self):
        code, _ = self.run_process([tagged("PA", "A", fail_after=True), tagged("PC", "C")], inputs={}, keep_going=True)
        self.assertEqual(code, 1)
        self.assertEqual(self.keyed()[("PC", "step", "s1")], "pass")
        self.assertEqual(self.cleanups(), ["C", "A"])

    def test_a_failing_cleanup_does_not_stop_the_other_cleanups_and_fails_the_run(self):
        bad = tagged("PB", "B")
        bad["cleanup"][0]["expect"] = {"status": 404}
        code, _ = self.run_process([tagged("PA", "A"), bad], inputs={})
        self.assertEqual(code, 1)
        self.assertEqual(self.cleanups(), ["B", "A"])
        self.assertEqual(self.keyed()[("PB", "cleanup", "c1")], "fail")
        self.assertEqual(self.keyed()[("PA", "cleanup", "c1")], "pass")

    def test_build_moved_at_the_end_of_a_chain_fails_the_run(self):
        self.state.sha_at_end = "def456"
        code, _ = self.run_process([tagged("PA", "A")], inputs={})
        self.assertEqual(code, 1)
        self.assertEqual(self.keyed()[("PA", "step", "s1")], "pass")
        self.assertIn("build moved: abc123 -> def456", (self.run_dir / "summary.md").read_text())


class PerProcessCleanup(ChainCase):
    """T-2545: a chain may clean up after every process ("cleanup": "per_process"), so that the next
    process meets the tenant without what the previous one created (a shared value, for example)."""

    def maker(self, cleanup_expect=None):
        """The first process: it creates the tenant's one shared value; its cleanup revokes it."""
        cleanup = [{"id": "c1", "actor": "admin", "requires": ["created"],
                    "do": {"api": "POST", "path": "/api/v1/fx/drop", "body": {"name": "singleton"}},
                    "expect": cleanup_expect or {"status": 200}}]
        return proc("SEC-01", [call("s1", "POST", "/api/v1/fx/make", {"name": "singleton"}, {"status": 201},
                                    save={"created": "yes"})], cleanup=cleanup)

    def checker(self, pid="SEC-02"):
        """The second process: it expects that no shared value exists."""
        return proc(pid, [call("s1", "POST", "/api/v1/fx/find", {"name": "singleton"},
                               {"status": 200, "json": {"$.items": []}})])

    def order(self):
        """The (process, phase, step) rows of the log, in the order they ran."""
        return [(x["process"], x["phase"], x["step"]) for x in self.lines()]

    def test_a_chain_whose_first_process_creates_a_singleton_passes_with_per_process_and_fails_with_the_end_cleanup(self):
        code, _ = self.run_process([self.maker(), self.checker()], inputs={}, cleanup_mode="per_process")
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        self.assertEqual(self.keyed()[("SEC-02", "step", "s1")], "pass")
        self.assertEqual(self.state.fx, {})  # the value was revoked before the second process ran

        # the same chain with the default cleanup: the value is still there when the second process runs
        self.run_dir = self.run_dir.parent / "run-end"
        self.state.fx.clear()
        self.state.fx_log.clear()
        code, _ = self.run_process([self.maker(), self.checker()], inputs={})
        self.assertEqual(code, 1)
        self.assertEqual(self.keyed()[("SEC-02", "step", "s1")], "fail")

    def test_the_cleanup_runs_right_after_its_process(self):
        code, _ = self.run_process([self.maker(), self.checker()], inputs={}, cleanup_mode="per_process")
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        order = self.order()
        self.assertLess(order.index(("SEC-01", "cleanup", "c1")), order.index(("SEC-02", "step", "s1")))
        summary = (self.run_dir / "summary.md").read_text()
        self.assertIn("- cleanup mode: per_process", summary)
        self.assertIn("## Cleanup (the order it ran)", summary)
        self.assertIn("| 1 | SEC-01 | c1 | pass |", summary)

    def test_the_cleanups_run_in_the_order_of_the_processes_and_the_summary_shows_it(self):
        code, _ = self.run_process([tagged("PA", "A"), tagged("PB", "B"), tagged("PC", "C")], inputs={},
                                   cleanup_mode="per_process")
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        self.assertEqual(self.cleanups(), ["A", "B", "C"])  # the order the processes ran, not the reverse
        summary = (self.run_dir / "summary.md").read_text()
        self.assertLess(summary.index("| 1 | PA | c1 |"), summary.index("| 2 | PB | c1 |"))
        self.assertLess(summary.index("| 2 | PB | c1 |"), summary.index("| 3 | PC | c1 |"))

    def test_the_default_cleans_up_at_the_end_of_the_chain(self):
        code, _ = self.run_process([self.maker(), self.checker()], inputs={})
        self.assertEqual(code, 1)
        order = self.order()
        self.assertLess(order.index(("SEC-02", "step", "s1")), order.index(("SEC-01", "cleanup", "c1")))
        self.assertIn("- cleanup mode: end", (self.run_dir / "summary.md").read_text())

    def test_the_cleanup_of_a_failed_process_runs_right_after_it(self):
        maker = self.maker()
        maker["steps"].append(call("s2", "POST", "/api/v1/fx/find", {"name": "singleton"}, {"status": 404}))
        code, _ = self.run_process([maker, self.checker()], inputs={}, cleanup_mode="per_process")
        self.assertEqual(code, 1)
        self.assertEqual(self.state.fx, {})  # the cleanup ran even though the process failed
        self.assertEqual(self.keyed()[("SEC-01", "step", "s2")], "fail")
        self.assertEqual(self.keyed()[("SEC-01", "cleanup", "c1")], "pass")
        self.assertEqual(self.keyed()[("SEC-02", "step", "-")], "skipped")  # the chain stopped

    def test_a_failing_cleanup_fails_the_run_and_the_next_process_still_runs(self):
        code, _ = self.run_process([self.maker(cleanup_expect={"status": 404}), self.checker()], inputs={},
                                   cleanup_mode="per_process")
        self.assertEqual(code, 1)
        self.assertEqual(self.keyed()[("SEC-01", "cleanup", "c1")], "fail")
        self.assertEqual(self.keyed()[("SEC-02", "step", "s1")], "pass")  # the chain went on
        self.assertIn("cleanup: FAIL", (self.run_dir / "summary.md").read_text())

    def test_the_outputs_the_chain_hands_on_survive_the_drop_of_the_working_values(self):
        maker = proc("SEC-01", [call("s1", "POST", "/api/v1/fx/make", {"name": "singleton"}, {"status": 201},
                                     save={"created": "yes", "made_id": "$.record_id"})],
                     cleanup=[{"id": "c1", "actor": "admin", "requires": ["created"],
                               "do": {"api": "POST", "path": "/api/v1/fx/drop", "body": {"name": "singleton"}},
                               "expect": {"status": 200}}],
                     outputs={"made": "${made_id}"})
        checker = proc("SEC-02", [call("s1", "POST", "/api/v1/fx/find", {"name": "singleton", "made": "${made}"},
                                       {"status": 200, "json": {"$.items": []}})],
                       inputs=["made"], outputs={"seen": "${made}"})
        code, _ = self.run_process([maker, checker], inputs={}, pass_map={"SEC-01": ["made"]},
                                   cleanup_mode="per_process")
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        ctx = json.loads((self.run_dir / "context.json").read_text())
        self.assertEqual(ctx["made"], "rec-singleton")  # the output the chain handed on is still there
        self.assertEqual(ctx["seen"], "rec-singleton")
        self.assertNotIn("created", ctx)  # the working value of the process left the chain context

    def test_the_working_values_of_a_process_leave_the_chain_context(self):
        """One process (no isolation): its working values are in the chain context and leave it when
        its cleanup has run; the declared output is still reported."""
        process = proc("SEC-01", [call("s1", "POST", "/api/v1/fx/make", {"name": "singleton"}, {"status": 201},
                                       save={"created": "yes", "made_id": "$.record_id"})],
                       cleanup=[{"id": "c1", "actor": "admin", "requires": ["created"],
                                 "do": {"api": "POST", "path": "/api/v1/fx/drop", "body": {"name": "singleton"}},
                                 "expect": {"status": 200}}],
                       outputs={"made": "${made_id}"})
        code, _ = self.run_process([process], inputs={}, cleanup_mode="per_process")
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        ctx = json.loads((self.run_dir / "context.json").read_text())
        self.assertNotIn("created", ctx)  # the working values left the chain context
        self.assertNotIn("made_id", ctx)
        self.assertEqual(ctx["made"], "rec-singleton")  # the declared output is still reported

    def test_the_cleanup_of_a_process_whose_step_failed_skips_the_steps_that_require_a_missing_value(self):
        maker = proc("SEC-01", [call("s1", "POST", "/api/v1/fx/find", {"name": "singleton"}, {"status": 404})],
                     cleanup=[{"id": "c1", "actor": "admin", "requires": ["created"],
                               "do": {"api": "POST", "path": "/api/v1/fx/drop", "body": {"name": "singleton"}},
                               "expect": {"status": 200}}])
        code, _ = self.run_process([maker, self.checker()], inputs={}, cleanup_mode="per_process")
        self.assertEqual(code, 1)
        line = next(x for x in self.lines() if x["phase"] == "cleanup")
        self.assertEqual((line["verdict"], line["error"]), ("skipped", "requires created"))
        self.assertEqual(self.state.fx_log, [])  # nothing was dropped that was never created

    def test_a_process_that_never_ran_has_no_cleanup(self):
        maker = self.maker()
        maker["steps"].append(call("s2", "POST", "/api/v1/fx/find", {"name": "singleton"}, {"status": 404}))
        code, _ = self.run_process([maker, self.checker(), self.checker("SEC-03")], inputs={},
                                   cleanup_mode="per_process")
        self.assertEqual(code, 1)
        cleanups = [x for x in self.lines() if x["phase"] == "cleanup"]
        self.assertEqual([x["process"] for x in cleanups], ["SEC-01"])  # the skipped process has none


class CleanupReplay(ChainCase):
    def abort_after_the_steps(self):
        """A run that died after BP-01 posted: the steps ran, the cleanup did not."""
        process = runner.load_process(PROCESS_FILE)
        r = runner.Runner([process], base_url=self.base, tenant="qoimeks-qa2", actors=USERS, run_dir=self.run_dir,
                          inputs=dict(INPUTS), poll_interval=0.01, out=io.StringIO())
        self.run_dir.mkdir(parents=True)
        r.save_meta("now")
        ok, _ = r.preflight()
        self.assertTrue(ok)
        self.assertTrue(r.run_process(process))
        return r

    def main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = runner.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def test_cleanup_command_replays_the_recorded_list_of_an_aborted_run(self):
        self.abort_after_the_steps()
        self.assertEqual(self.state.qty, Decimal("12"))  # the receipt is posted and nobody reversed it
        recorded = json.loads((self.run_dir / "cleanup.json").read_text())
        self.assertEqual([e["process"] for e in recorded], ["BP-01"])
        self.assertFalse(recorded[0]["done"])
        context_before = (self.run_dir / "context.json").read_text()
        code, out, err = self.main("cleanup", str(self.run_dir), "--poll-interval", "0.01")
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.state.qty, Decimal("7"))
        self.assertEqual(len(self.state.calls("POST", "/reverse")), 1)
        self.assertEqual(self.state.calls("POST", "/reverse")[0][3]["reason_code"], "other")
        self.assertTrue(json.loads((self.run_dir / "cleanup.json").read_text())[0]["done"])
        self.assertEqual((self.run_dir / "context.json").read_text(), context_before)  # the run's own context is kept
        self.assertIn("PASS", (self.run_dir / "summary-cleanup.md").read_text())
        replay = [x for x in self.lines() if x["phase"] == "cleanup"]
        self.assertEqual([x["step"] for x in replay], ["c1", "c2", "c3"])

    def test_the_dash_dash_cleanup_form_works_and_a_second_replay_does_nothing(self):
        self.abort_after_the_steps()
        code, out, err = self.main("--cleanup", str(self.run_dir), "--poll-interval", "0.01")
        self.assertEqual(code, 0, out + err)
        code, out, err = self.main("--cleanup", str(self.run_dir), "--poll-interval", "0.01")
        self.assertEqual(code, 0, out + err)
        self.assertEqual(len(self.state.calls("POST", "/reverse")), 1)  # the entry was done: not reversed twice

    def test_replay_skips_what_was_never_created(self):
        self.abort_after_the_steps()
        # an aborted run that died before the post: the cleanup list names a variable that does not exist
        recorded = json.loads((self.run_dir / "cleanup.json").read_text())
        del recorded[0]["ctx"]["posted_doc_id"]
        (self.run_dir / "cleanup.json").write_text(json.dumps(recorded))
        code, out, err = self.main("cleanup", str(self.run_dir), "--poll-interval", "0.01")
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.state.calls("POST", "/reverse"), [])
        self.assertEqual({x["verdict"] for x in self.lines() if x["phase"] == "cleanup"}, {"skipped"})

    def test_replay_of_a_directory_without_a_record_is_a_usage_error(self):
        self.run_dir.mkdir(parents=True)
        code, out, err = self.main("cleanup", str(self.run_dir))
        self.assertEqual(code, 2)
        self.assertIn("meta.json", err)

    def test_the_replay_fetches_tokens_again_and_writes_none(self):
        self.abort_after_the_steps()
        self.main("cleanup", str(self.run_dir), "--poll-interval", "0.01")
        text = "".join(p.read_text() for p in self.run_dir.iterdir() if p.is_file())
        self.assertNotIn(SECRET, text)


class Preflight(ChainCase):
    def test_wrong_build_sha_fails_before_any_step(self):
        code, _ = self.run_process(tagged("PA", "A"), inputs={}, build_sha="zzz999")
        self.assertEqual(code, 1)
        line = next(x for x in self.lines() if x["step"] == "build_sha")
        self.assertIn("expected zzz999", line["error"])
        self.assertEqual(self.state.log, [])
        self.assertNotIn("s1", [x["step"] for x in self.lines()])

    def test_the_expected_build_sha_may_be_a_prefix(self):
        code, _ = self.run_process(tagged("PA", "A"), inputs={}, build_sha="abc")
        self.assertEqual(code, 0)

    def test_every_actor_gets_a_token_before_the_first_step(self):
        script = Path(self.team_root) / "project" / "scripts" / "uat_creds.sh"
        script.write_text("#!/usr/bin/env bash\n[ \"$2\" = sk ] && { echo 'login refused' >&2; exit 1; }\n"
                          f"printf 'Token: TOKEN_%s_{SECRET}\\n' \"$2\"\n")
        process = proc("PA", [call("s1", "GET", "/api/v1/echo", actor="admin"), call("s2", "GET", "/api/v1/echo", actor="storekeeper")])
        code, _ = self.run_process(process, inputs={})
        self.assertEqual(code, 1)
        verdicts = {x["step"]: x["verdict"] for x in self.lines() if x["phase"] == "preflight"}
        self.assertEqual(verdicts["token:admin"], "pass")
        self.assertEqual(verdicts["token:storekeeper"], "error")
        self.assertEqual([c for c in self.state.log if c[1].startswith("/api/")], [])  # not even the admin's step ran

    def test_an_unreachable_tenant_fails_the_preflight(self):
        r = runner.Runner([tagged("PA", "A")], base_url="http://127.0.0.1:1", tenant="t", actors=USERS, run_dir=self.run_dir,
                          health_url=self.base + "/health", out=io.StringIO())
        self.assertEqual(r.run(), 1)
        line = next(x for x in self.lines() if x["step"] == "tenant")
        self.assertIn("not reachable", line["error"])

    def test_the_stable_check_runs_with_wait_and_the_qa_address(self):
        log = Path(self.tmp.name) / "stable.log"
        self.stable_script(f'#!/usr/bin/env bash\necho "$1 $QA_URL" >> {log}\necho "sha=abc123 stable"\n')
        code, _ = self.run_process(tagged("PA", "A"), inputs={})
        self.assertEqual(code, 0)
        self.assertEqual(log.read_text().strip(), f"--wait {self.base}")
        self.assertEqual({x["step"]: x["verdict"] for x in self.lines()}["stable"], "pass")

    def test_an_unstable_build_does_not_start_the_run(self):
        self.stable_script('#!/usr/bin/env bash\necho unstable\nexit 1\n')
        code, _ = self.run_process(tagged("PA", "A"), inputs={})
        self.assertEqual(code, 1)
        line = next(x for x in self.lines() if x["step"] == "stable")
        self.assertIn("not stable", line["error"])
        self.assertEqual([c for c in self.state.log if c[1].startswith("/api/")], [])

    def test_a_build_that_changed_while_waiting_fails_the_run(self):
        self.stable_script('#!/usr/bin/env bash\necho "sha=fff000 stable"\n')
        code, _ = self.run_process(tagged("PA", "A"), inputs={})
        self.assertEqual(code, 1)
        self.assertIn("changed while waiting", next(x for x in self.lines() if x["step"] == "stable")["error"])

    def test_without_team_root_the_stable_check_is_not_called(self):
        log = Path(self.tmp.name) / "stable.log"
        self.stable_script(f'#!/usr/bin/env bash\necho x >> {log}\necho "sha=abc123 stable"\n')
        r = runner.Runner([tagged("PA", "A")], base_url=self.base, tenant="t", actors=USERS, run_dir=self.run_dir,
                          out=io.StringIO())
        self.run_dir.mkdir(parents=True)
        with contextlib.ExitStack() as stack:
            from fakes import mock_env

            stack.enter_context(mock_env())
            os.environ.pop("TEAM_ROOT", None)
            ok, _ = r.preflight()
        self.assertFalse(log.exists())
        self.assertNotIn("stable", [x["step"] for x in r.records])
        self.assertFalse(ok)  # no TEAM_ROOT: no token command either
        self.assertTrue(any("TEAM_ROOT" in str(x.get("error")) for x in r.records))

    def test_the_check_can_be_switched_off(self):
        log = Path(self.tmp.name) / "stable.log"
        self.stable_script(f'#!/usr/bin/env bash\necho x >> {log}\necho "sha=abc123 stable"\n')
        r = runner.Runner([tagged("PA", "A")], base_url=self.base, tenant="t", actors=USERS, run_dir=self.run_dir,
                          out=io.StringIO())
        self.run_dir.mkdir(parents=True)
        ok, _ = r.preflight(check_stable=False)
        self.assertTrue(ok)
        self.assertFalse(log.exists())


class StepKinds(ChainCase):
    def run_steps(self, steps, cleanup=None, **kwargs):
        return self.run_process(proc("PK", steps, cleanup), inputs={}, **kwargs)

    def test_assert_only_is_a_read_with_an_assertion(self):
        ok = {"id": "s1", "actor": "admin", "do": {"assert_only": {"path": "/api/v1/modules/stock/balances"}},
              "expect": {"status": 200, "json": {"$.rows[0].sku": "item-1"}}}
        code, _ = self.run_steps([ok])
        self.assertEqual(code, 0)
        self.assertEqual(self.state.calls("GET", "/balances")[0][2], "admin")
        bad = dict(ok, expect={"status": 200, "json": {"$.rows[0].sku": "other"}})
        self.run_dir = self.run_dir.parent / "run2"
        code, _ = self.run_steps([bad])
        self.assertEqual(code, 1)

    def test_assert_only_refuses_a_body_a_write_method_and_a_missing_expect(self):
        for spec, extra in (({"path": "/p", "body": {}}, {"expect": {}}), ({"path": "/p", "api": "POST"}, {"expect": {}}),
                            ({"path": "/p"}, {})):
            step = {"id": "s", "actor": "a", "do": {"assert_only": spec}, **extra}
            with self.assertRaises(runner.ConfigError, msg=str(spec)):
                runner.validate_step(step, "step s")

    def test_repeat_sends_the_same_call_twice_and_checks_retry_semantics(self):
        import uuid

        step = call("s1", "POST", "/api/v1/once", {"id": "${uuid1}"}, {"status": 201}, expect_repeat={"status": 200, "json": {"n": 1}},
                    save={"op": "$.id"})
        step["do"] = {"repeat": step["do"]}
        code, _ = self.run_steps([step])
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        once = self.state.calls("POST", "/once")
        self.assertEqual(len(once), 2)
        self.assertEqual(once[0][3], once[1][3])  # the UUID stays stable on the retry
        line = next(x for x in self.lines() if x["step"] == "s1")
        self.assertEqual([c["status"] for c in line["calls"]], [201, 200])
        ctx = json.loads((self.run_dir / "context.json").read_text())
        self.assertEqual(ctx["op"], ctx["uuid1"])
        self.assertEqual(str(uuid.UUID(ctx["op"])), ctx["op"])

    def test_repeat_fails_when_the_second_answer_is_not_the_expected_one(self):
        step = call("s1", "POST", "/api/v1/once", {"id": "op-2"}, {"status": 201})
        step["do"] = {"repeat": step["do"]}  # the second call answers 200: the same expect (201) fails
        code, _ = self.run_steps([step])
        self.assertEqual(code, 1)
        line = next(x for x in self.lines() if x["step"] == "s1")
        self.assertEqual(line["verdict"], "fail")
        self.assertIn("call 2", line["asserted"][-1]["what"])

    def test_parallel_sends_calls_together_and_unordered_expectations_accept_any_order(self):
        step = {"id": "s1", "actor": "admin",
                "do": {"parallel": [{"api": "POST", "path": "/api/v1/race", "body": {"n": 1}},
                                    {"api": "POST", "path": "/api/v1/race", "body": {"n": 2}}]},
                "expect": {"unordered": [{"status": 201}, {"status": 409}]}}
        code, _ = self.run_steps([step])
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        self.assertEqual(self.state.race_hits, 2)
        line = next(x for x in self.lines() if x["step"] == "s1")
        self.assertEqual(sorted(c["status"] for c in line["calls"]), [201, 409])

    def test_parallel_fails_when_both_must_win(self):
        step = {"id": "s1", "actor": "admin",
                "do": {"parallel": [{"api": "POST", "path": "/api/v1/race"}, {"api": "POST", "path": "/api/v1/race"}]},
                "expect": [{"status": 201}, {"status": 201}]}
        code, _ = self.run_steps([step])
        self.assertEqual(code, 1)
        self.assertEqual(next(x for x in self.lines() if x["step"] == "s1")["verdict"], "fail")

    def test_expect_refused_wants_a_4xx_with_the_error_code(self):
        good = call("s1", "POST", "/api/v1/refuse", {}, expect_refused={"code": "output_refused", "status": 422})
        del good["expect"]
        code, _ = self.run_steps([good, dict(good, id="s2", expect_refused="output_refused")])
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())

    def test_expect_refused_fails_on_a_success_a_wrong_status_and_a_wrong_code(self):
        for name, spec, path in (("ok", {"code": "x"}, "/api/v1/echo"), ("status", {"status": 409}, "/api/v1/refuse"),
                                 ("code", {"code": "other_code"}, "/api/v1/refuse")):
            step = call("s1", "POST", path, {}, expect_refused=spec)
            del step["expect"]
            self.run_dir = self.run_dir.parent / f"run-{name}"
            code, _ = self.run_steps([step])
            self.assertEqual(code, 1, name)
        # a plain 4xx with no code asked for is enough
        step = call("s1", "POST", "/api/v1/refuse", {}, expect_refused={})
        del step["expect"]
        self.run_dir = self.run_dir.parent / "run-any"
        self.assertEqual(self.run_steps([step])[0], 0)

    def test_the_loader_refuses_bad_new_kinds(self):
        base = {"id": "s", "actor": "a"}
        for step in (dict(base, do={"parallel": [{"api": "GET", "path": "/p"}]}),
                     dict(base, do={"repeat": {"api": "GET"}}),
                     dict(base, do={"api": "GET", "path": "/p", "repeat": {"api": "GET", "path": "/p"}}),
                     dict(base, do={"api": "GET", "path": "/p"}, http_as="somebody"),
                     dict(base, do={"api": "GET", "path": "/p"}, expect={}, expect_refused="x"),
                     {"id": "s", "do": {"api": "GET", "path": "/p"}}):
            with self.assertRaises(runner.ConfigError, msg=str(step)):
                runner.validate_step(step, "step s")


class SharedAccess(ChainCase):
    def process(self, **over):
        create = call("s1", "POST", "/api/v1/identity/shared-stock-access", {}, {"status": 201},
                      save={"shared_created": "yes", "shared_access": {"secret": "$.value"}})
        read = {"id": "s2", "http_as": "shared_access", "do": {"api": "GET", "path": "/movements"}, "expect": {"status": 200}}
        revoke = {"id": "c1", "actor": "admin", "requires": ["shared_created"],
                  "do": {"api": "DELETE", "path": "/api/v1/identity/shared-stock-access"}, "expect": {"status": 204}}
        return proc("BP-08", over.get("steps", [create, read]), [revoke])

    def all_text(self, out):
        return out.getvalue() + "".join(p.read_text() for p in self.run_dir.iterdir() if p.is_file())

    def run_shared(self, process):
        out = io.StringIO()
        r = runner.Runner([process], base_url=self.base, tenant="qoimeks-qa2", actors=USERS, run_dir=self.run_dir,
                          old_base_url=self.base + "/qoimeks/qoimeks-qa2", poll_interval=0.01, out=out)
        return r.run(), r, out

    def test_the_old_address_is_called_with_the_value_created_by_the_process_and_revoked_after(self):
        code, r, out = self.run_shared(self.process())
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        self.assertEqual(self.state.shared_calls, [("GET", "/qoimeks/qoimeks-qa2/movements", True)])
        self.assertEqual(self.state.revoked, 1)
        self.assertIsNone(self.state.shared_value)
        self.assertEqual(r.secrets, {"shared_access": SHARED_VALUE})  # in memory
        self.assertEqual(json.loads((self.run_dir / "context.json").read_text()).get("shared_created"), "yes")

    def test_the_value_never_reaches_a_file_or_the_screen(self):
        code, r, out = self.run_shared(self.process())
        self.assertEqual(code, 0)
        self.assertNotIn(SHARED_VALUE, self.all_text(out))
        self.assertNotIn(SHARED_VALUE, (self.run_dir / "cleanup.json").read_text())

    def test_the_value_is_not_shown_when_the_creating_step_fails_or_a_later_one_does(self):
        create_bad = self.process()["steps"][0]
        create_bad["expect"] = {"status": 201, "json": {"$.value": "not-the-value"}}  # the create answers a value: fails
        code, r, out = self.run_shared(self.process(steps=[create_bad]))
        self.assertEqual(code, 1)
        line = next(x for x in self.lines() if x["step"] == "s1")
        self.assertEqual(line["verdict"], "fail")
        self.assertIn("withheld", line["response_excerpt"])
        self.assertNotIn(SHARED_VALUE, self.all_text(out))
        # a read of the old address that fails after the value was saved
        self.run_dir = self.run_dir.parent / "run-late"
        late = dict(self.process()["steps"][1], expect={"status": 200, "json": {"$.nope": "x"}})
        code, r, out = self.run_shared(self.process(steps=[self.process()["steps"][0], late]))
        self.assertEqual(code, 1)
        self.assertNotIn(SHARED_VALUE, self.all_text(out))

    def test_a_step_that_needs_the_value_before_it_exists_is_an_error(self):
        read = self.process()["steps"][1]
        code, r, out = self.run_shared(self.process(steps=[read]))
        self.assertEqual(code, 1)
        self.assertIn("no shared_access value yet", next(x for x in self.lines() if x["step"] == "s2")["error"])
        self.assertEqual(self.state.shared_calls, [])

    def test_the_revoke_is_in_the_cleanup_and_runs_when_a_later_step_fails(self):
        read = dict(self.process()["steps"][1], expect={"status": 201})
        code, r, out = self.run_shared(self.process(steps=[self.process()["steps"][0], read]))
        self.assertEqual(code, 1)
        self.assertEqual(self.state.revoked, 1)

    def test_an_actor_less_step_needs_no_token_and_no_actor_in_the_roster(self):
        self.assertEqual(runner.Runner([self.process()], base_url=self.base, tenant="t", actors=USERS,
                                       run_dir=self.run_dir, out=io.StringIO()).needed_roles(), ["admin"])


class LogAndSummary(ChainCase):
    def test_durations_context_and_first_failing_step(self):
        code, r = self.run_process([tagged("PA", "A"), tagged("PB", "B", fail_after=True)], inputs={})
        self.assertEqual(code, 1)
        text = (self.run_dir / "summary.md").read_text()
        self.assertIn("## Processes", text)
        self.assertRegex(text, r"\| PA \| [^|]+ \| pass \| pass \| pass \| \d+ \|")
        self.assertRegex(text, r"\| PB \| [^|]+ \| FAIL \| FAIL \| pass \| \d+ \| s2")
        self.assertIn("FIRST FAILING STEP: PB step s2", text)
        self.assertIn("**>>**", text)  # the row of that step is marked
        self.assertIn("duration:", text)
        context_block = text.split("## Context at the end")[1]
        self.assertIn('"out_A": "A"', context_block)
        self.assertNotIn('"who": "B"', context_block)  # PB's failed private working value is not a chain output
        self.assertIn("run_id", context_block)
        for line in self.lines():
            self.assertIn("ms", line)
            self.assertIsInstance(line["ms"], int)

    def test_a_passing_run_has_no_failing_marker(self):
        code, _ = self.run_process([tagged("PA", "A")], inputs={})
        self.assertEqual(code, 0)
        text = (self.run_dir / "summary.md").read_text()
        self.assertNotIn("FIRST FAILING", text)
        self.assertIn("verdict: **PASS**", text)


class ChainCli(ChainCase):
    def write_chain(self, procs, chain=None):
        base = Path(self.tmp.name) / "repo" / "test" / "uat"
        (base / "processes").mkdir(parents=True, exist_ok=True)
        (base / "chains").mkdir(parents=True, exist_ok=True)
        for p in procs:
            (base / "processes" / f"{p['id']}-name.json").write_text(json.dumps(p))
        path = base / "chains" / "c.json"
        path.write_text(json.dumps({"id": "chain-x", "processes": [p["id"] for p in procs], **(chain or {})}))
        return path

    def main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = runner.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def common(self):
        return ["--tenant", "qoimeks-qa2", "--base-url", self.base, "--actors", "admin=adm,storekeeper=sk",
                "--run-dir", str(self.run_dir), "--poll-interval", "0.01"]

    def test_chain_command_resolves_processes_by_id_and_runs_them(self):
        path = self.write_chain([tagged("BP-A", "A"), tagged("BP-B", "B")])
        code, out, err = self.main("chain", str(path), *self.common())
        self.assertEqual(code, 0, out + err)
        self.assertIn("chain-x: PASS", out)
        self.assertEqual(self.cleanups(), ["B", "A"])

    def test_a_chain_file_may_clean_up_after_every_process(self):
        path = self.write_chain([tagged("BP-A", "A"), tagged("BP-B", "B")], {"cleanup": "per_process"})
        code, out, err = self.main("chain", str(path), *self.common())
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.cleanups(), ["A", "B"])  # the order the processes ran, not the reverse
        self.assertIn("- cleanup mode: per_process", (self.run_dir / "summary.md").read_text())

    def test_a_chain_file_with_an_unknown_cleanup_mode_is_a_usage_error(self):
        path = self.write_chain([tagged("BP-A", "A")], {"cleanup": "per_prozess"})
        code, out, err = self.main("chain", str(path), *self.common())
        self.assertEqual(code, 2)
        self.assertIn("cleanup must be one of", err)
        self.assertEqual(self.state.log, [])

    def test_chain_file_may_carry_tenant_actors_and_inputs(self):
        reader = proc("BP-R", [call("s1", "POST", "/api/v1/echo", {})], inputs=["thing"])
        path = self.write_chain([reader], {"tenant": "qoimeks-qa2", "actors": USERS, "inputs": {"thing": "x"}})
        code, out, err = self.main("chain", str(path), "--base-url", self.base, "--run-dir", str(self.run_dir),
                                   "--poll-interval", "0.01")
        self.assertEqual(code, 0, out + err)

    def test_keep_going_flag(self):
        path = self.write_chain([tagged("BP-A", "A", fail_after=True), tagged("BP-B", "B")])
        code, out, err = self.main("chain", str(path), *self.common())
        self.assertEqual(code, 1)
        self.assertEqual(self.cleanups(), ["A"])
        self.run_dir = self.run_dir.parent / "run-kg"
        self.state.log.clear()
        code, out, err = self.main("chain", str(path), *self.common()[:-4], "--run-dir", str(self.run_dir),
                                   "--poll-interval", "0.01", "--keep-going")
        self.assertEqual(code, 1)
        self.assertEqual(self.cleanups(), ["B", "A"])

    def test_a_chain_that_needs_an_input_nobody_gives_runs_nothing(self):
        reader = proc("BP-R", [call("s1", "POST", "/api/v1/echo", {})], inputs=["thing"])
        path = self.write_chain([tagged("BP-A", "A"), reader])
        code, out, err = self.main("chain", str(path), *self.common())
        self.assertEqual(code, 2)
        self.assertIn("BP-R: inputs missing: thing", err)
        self.assertEqual(self.state.log, [])

    def test_a_later_process_may_read_only_a_passed_output_of_an_earlier_one(self):
        reader = proc("BP-R", [call("s1", "POST", "/api/v1/echo", {})], inputs=["out_A"])
        ok = self.write_chain([tagged("BP-A", "A"), reader], {"pass": {"BP-A": ["out_A"]}})
        self.assertEqual(self.main("chain", str(ok), *self.common())[0], 0)
        self.run_dir = self.run_dir.parent / "run-not-passed"
        not_passed = self.write_chain([tagged("BP-A", "A"), reader])
        self.assertEqual(self.main("chain", str(not_passed), *self.common())[0], 2)
        self.run_dir = self.run_dir.parent / "run-rev"
        wrong = self.write_chain([reader, tagged("BP-A", "A")], {"pass": {"BP-A": ["out_A"]}})
        self.assertEqual(self.main("chain", str(wrong), *self.common())[0], 2)

    def test_a_placeholder_in_a_chain_is_a_usage_error_before_anything_runs(self):
        reader = proc("BP-R", [call("s1", "POST", "/api/v1/echo", {})], inputs=["thing"])
        path = self.write_chain([reader], {"inputs": {"thing": "REPLACE-WITH-THING-ID"}})
        code, out, err = self.main("chain", str(path), *self.common())
        self.assertEqual(code, 2, out + err)
        self.assertIn("REPLACE-WITH-THING-ID", err)
        self.assertEqual(self.state.log, [])

    def test_an_unknown_process_or_a_missing_actor_is_a_usage_error(self):
        path = self.write_chain([tagged("BP-A", "A")], {"processes": ["BP-A", "BP-NOPE"]})
        code, out, err = self.main("chain", str(path), *self.common())
        self.assertEqual(code, 2)
        self.assertIn("BP-NOPE", err)
        path = self.write_chain([tagged("BP-A", "A")])
        code, out, err = self.main("chain", str(path), "--tenant", "t", "--base-url", self.base, "--actors", "storekeeper=sk")
        self.assertEqual(code, 2)
        self.assertIn("admin", err)

    def test_build_sha_and_old_base_url_options_reach_the_runner(self):
        path = self.write_chain([tagged("BP-A", "A")])
        code, out, err = self.main("chain", str(path), *self.common(), "--build-sha", "zzz")
        self.assertEqual(code, 1)
        self.assertIn("expected zzz", (self.run_dir / "run.jsonl").read_text())

    # -- T-2540: a chain entry that runs on its own tenant --------------------------------------

    def where(self, pid):
        """The tenant a process's echo step reported (its body carries ${tenant})."""
        return next(c[3]["t"] for c in self.state.calls("POST", "/echo") if c[3] and c[3].get("p") == pid)

    def tenant_proc(self, pid, inputs=None, dry_run=None):
        doc = proc(pid, [call("s1", "POST", "/api/v1/echo", {"p": pid, "t": "${tenant}"})], inputs=inputs)
        if dry_run:
            doc["dry_run"] = dry_run
        return doc

    def two_tenant_chain(self, entry, other_inputs=None, dry_run=None):
        dry = dry_run or {"tenant": "other-qa", "actors": {"admin": "adm"}, "inputs": {}, "base_url": self.base}
        procs = [self.tenant_proc("BP-A"), self.tenant_proc("BP-B", other_inputs, dry)]
        path = self.write_chain(procs, {"processes": ["BP-A", entry], "tenant": "main-qa", "inputs": {"thing": "main-id"},
                                        "actors": {"admin": "adm"}})
        return path

    def run_chain(self, path):
        return self.main("chain", str(path), "--base-url", self.base, "--run-dir", str(self.run_dir), "--poll-interval", "0.01")

    def test_a_two_tenant_chain_runs_each_process_against_its_tenant_and_lists_it(self):
        path = self.two_tenant_chain({"process": "BP-B", "dry_run": True})
        code, out, err = self.run_chain(path)
        self.assertEqual(code, 0, out + err)
        self.assertEqual((self.where("BP-A"), self.where("BP-B")), ("main-qa", "other-qa"))
        summary = (self.run_dir / "summary.md").read_text()
        self.assertIn("| BP-A | main-qa |", summary)
        self.assertIn("| BP-B | other-qa |", summary)

    def test_an_entry_may_name_its_own_tenant_and_actors_instead_of_dry_run(self):
        entry = {"process": "BP-B", "tenant": "third-qa", "actors": {"admin": "adm"}, "base_url": self.base}
        code, out, err = self.run_chain(self.two_tenant_chain(entry, dry_run={"tenant": "x"}))
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.where("BP-B"), "third-qa")

    def test_a_process_on_another_tenant_gets_no_ids_of_the_first_tenant(self):
        path = self.two_tenant_chain({"process": "BP-B", "dry_run": True}, other_inputs=["thing"])
        code, out, err = self.run_chain(path)
        self.assertEqual(code, 2, out + err)
        self.assertIn("BP-B: inputs missing: thing", err)
        self.assertEqual(self.state.log, [])

    def test_the_preflight_runs_per_distinct_tenant(self):
        path = self.two_tenant_chain({"process": "BP-B", "dry_run": True})
        code, out, err = self.run_chain(path)
        self.assertEqual(code, 0, out + err)
        steps = [x["step"] for x in self.lines() if x["phase"] == "preflight"]
        for step in ("tenant", "tenant:other-qa", "token:admin", "token:other-qa:admin"):
            self.assertIn(step, steps)

    def test_an_unreachable_second_tenant_fails_the_preflight_before_any_step(self):
        dry = {"tenant": "other-qa", "actors": {"admin": "adm"}, "inputs": {}, "base_url": "http://127.0.0.1:1"}
        code, out, err = self.run_chain(self.two_tenant_chain({"process": "BP-B", "dry_run": True}, dry_run=dry))
        self.assertEqual(code, 1, out + err)
        line = next(x for x in self.lines() if x["step"] == "tenant:other-qa")
        self.assertIn("not reachable", line["error"])
        self.assertEqual([c for c in self.state.log if c[1].startswith("/api/")], [])

    def test_a_retired_tenant_in_an_entry_exits_2_before_any_request(self):
        for entry, dry in (({"process": "BP-B", "tenant": "qoimeks-qa", "actors": {"admin": "adm"}}, None),
                           ({"process": "BP-B", "dry_run": True},
                            {"tenant": "qoimeks-qa", "actors": {"admin": "adm"}, "inputs": {}, "base_url": self.base}),
                           ({"process": "BP-B", "tenant": "ok-qa", "actors": {"admin": "qoimeks-qa-admin"}}, None)):
            self.state.log.clear()
            code, out, err = self.run_chain(self.two_tenant_chain(entry, dry_run=dry))
            self.assertEqual(code, 2, out + err)
            self.assertIn("retired", err)
            self.assertEqual(self.state.log, [])

    def test_the_shipped_rc_chain_runs_bp_08_on_its_own_tenant(self):
        chain, processes = runner.load_chain(HERE.parent.parent.parent / "test" / "uat" / "chains" / "rc-sss.json")
        over = runner.chain_overrides(chain, processes)
        self.assertEqual(list(over), ["BP-08"])
        self.assertEqual(over["BP-08"]["tenant"], "qoimeks-qa2")
        self.assertEqual(over["BP-08"]["inputs"], {})
        self.assertIn("qoimeks/qoimeks-qa2", over["BP-08"]["old_base_url"])

    def cleanups(self):
        return [c[3]["cleanup"] for c in self.state.calls("POST", "/echo") if c[3] and "cleanup" in c[3]]


if __name__ == "__main__":
    unittest.main()
