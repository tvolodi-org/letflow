"""G-08: the two paths of the UAT runner must judge the same safety checks (the equivalence suite).

The runner has two paths: `run` (a process or a chain) and `replay_cleanup` (the cleanup list of an aborted
run). A safety check that one path makes and the other does not is a hole: the T-2606 cleanup replay
omitted the platform residue check and reported PASS with an instance still ACTIVE.

This suite runs both paths against fake servers, reads the safety checks each of them actually made from
the run log, and compares them with each other and with the reviewed expectations in
`test/fixtures/security_probes/g08_uat_safety_checks.txt`. A baseline the run promised and that is gone
fails the replay closed: it says it cannot judge the run instead of passing.

The N-cases are seeded failing variants: a runner whose replay skips the residue check, and a runner whose
replay fails open on a missing baseline. The probe must catch both.

Run: python3 -B -m unittest -v scripts/uat/tests/test_safety_equivalence.py   (from the repository root)
"""

import contextlib
import importlib.util
import io
import json
import stat
import sys
import threading
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]  # the product checkout
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import runner  # noqa: E402
from fakes import FakeServerCase, FakeStock, make_handler  # noqa: E402

EXPECTATIONS = ROOT / "test" / "fixtures" / "security_probes" / "g08_uat_safety_checks.txt"
MAIN_TENANT = "qoimeks-qa2"
PLATFORM_TENANT = "bpm-default"  # the platform tenant of QA (the realm of admin-user)
PLATFORM_USER = "admin-user"  # the platform administrator of the .env.uat group UAT_QA_ACTOR_ADMIN_USER_*
DEFINITION = "platform.register_tenant"
DEFINITION_ID = "d1"
SHA = "abc123"  # the build sha of the fake server

# Every safety check the runner can make. The expectation file names each of them for the two paths.
CHECK_KINDS = ("health", "build_sha", "stable", "tenant", "token", "build", "residue")


def observed_checks(records) -> set:
    """The safety checks the rows of a run log show: the kind of every row of the log."""
    kinds = set()
    for r in records:
        step = str(r.get("step") or "")
        if step == "tenant residue check":
            kinds.add("residue")
        elif step == "build":
            kinds.add("build")
        elif step == "build_sha":
            kinds.add("build_sha")
        elif step == "stable":
            kinds.add("stable")
        elif step == "health" or step.startswith("health:"):
            kinds.add("health")
        elif step == "tenant" or step.startswith("tenant:"):
            kinds.add("tenant")
        elif step == "token" or step.startswith("token:"):
            kinds.add("token")
    return kinds


def read_expectations(path=EXPECTATIONS) -> dict:
    """-> {kind: {"run": yes|no|except, "replay": yes|no|except, "note": ...}} of the reviewed expectations."""
    out = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) != 4:
            raise AssertionError(f"a line of {path.name} needs kind | run | replay | note: {line!r}")
        kind, run, replay, note = parts
        out[kind] = {"run": run, "replay": replay, "note": note}
    return out


def path_problems(path, kinds, expectations, column) -> list:
    """Every difference between the checks a path made and the reviewed expectations for it."""
    problems = []
    for kind, want in sorted(expectations.items()):
        said = want[column]
        if said == "yes":
            if kind not in kinds:
                problems.append(f"the {path} path does not make the {kind} check")
        elif said == "no":
            if kind in kinds:
                problems.append(f"the {path} path makes the {kind} check, the expectation says it does not")
        elif said == "except":
            if path == "replay":
                if kind in kinds:
                    problems.append(f"the replay path makes the {kind} check, the expectation says it does not")
            else:
                problems.append(f"{kind}: only the replay column may say except")
        else:
            problems.append(f"{kind}: unknown expectation {said!r} for the {path} path")
    return problems


def divergences(run_kinds, replay_kinds, expectations) -> list:
    """Every difference between the two paths of the runner: a check of one path that the other does not make,
    unless the expectation file says so (a reviewed divergence)."""
    problems = path_problems("run", run_kinds, expectations, "run")
    problems += path_problems("replay", replay_kinds, expectations, "replay")
    for kind in sorted(run_kinds - replay_kinds):
        if expectations.get(kind, {}).get("replay") != "except":
            problems.append(f"the run path makes the {kind} check, the replay path does not")
    for kind in sorted(replay_kinds - run_kinds):
        problems.append(f"the replay path makes the {kind} check, the run path does not")
    return problems


def mutant(replacements, directory, name="runner_mutant"):
    """A copy of the runner with the given replacements (the probe must catch it).

    The copy lives in the temporary directory of the test, never in the checkout."""
    source = (HERE.parent / "runner.py").read_text(encoding="utf-8")
    for old, new in replacements:
        if old not in source:
            raise AssertionError(f"the mutation does not apply: {old!r}")
        source = source.replace(old, new, 1)
    path = Path(directory) / f"{name}.py"
    path.write_text(source, encoding="utf-8")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def call(sid, method, path, body=None, expect=None, actor="platform-admin", save=None):
    do = {"api": method, "path": path}
    if body is not None:
        do["body"] = body
    step = {"id": sid, "actor": actor, "do": do, "expect": expect if expect is not None else {"status": 200}}
    if save:
        step["save"] = save
    return step


def scenario():
    """A run that changes a definition, starts and cancels an instance on the platform tenant and watches both.
    The run and its cleanup replay must judge the definition, the instance, the documents and the open tasks.
    The cleanup step is part of the scenario: the replay of the run has work to do, so it must mint the token
    of the actor of that step like the run does."""
    return {
        "id": "G08",
        "steps": [
            call("s1", "POST", f"/api/v1/definitions/{DEFINITION_ID}/activate", {}, {"status": 200}),
            call("s2", "POST", f"/api/v1/definitions/{DEFINITION}/rollback", {}, {"status": 200}),
            call("s3", "POST", "/api/v1/instances", {"definition_name": DEFINITION}, {"status": 201},
                 save={"instance_id": "$.instance_id"}),
            call("s4", "POST", "/api/v1/instances/${instance_id}/cancel", {}, {"status": 200}),
        ],
        "cleanup": [call("c1", "POST", "/api/v1/instances/${instance_id}/cancel", {}, {"status": 200})],
        "platform_residue": {"definitions": [DEFINITION], "instances": ["${instance_id}"]},
    }


class SafetyCase(FakeServerCase):
    """A run on a company tenant with a platform administrator on the platform tenant (two fake servers)."""

    def setUp(self):
        super().setUp()
        stable = Path(self.team_root) / "project" / "scripts" / "qa_stable.sh"
        stable.write_text('#!/usr/bin/env bash\necho "stable sha=abc123"\n', encoding="utf-8")
        stable.chmod(stable.stat().st_mode | stat.S_IXUSR)
        self.platform_state = FakeStock()
        self.platform_state.users = {"platform-admin": PLATFORM_USER}
        self.platform_state.platform_roles = {"platform-admin"}
        self.platform_state.instance_starts = True
        self.platform_state.definitions = [{"id": DEFINITION_ID, "name": DEFINITION, "version": "1.0.0",
                                            "status": "ACTIVE"}]
        self.platform_server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.platform_state))
        self.platform_thread = threading.Thread(target=self.platform_server.serve_forever,
                                                kwargs={"poll_interval": 0.01}, daemon=True)
        self.platform_thread.start()
        self.addCleanup(self.stop_platform_server)
        self.platform_base = f"http://127.0.0.1:{self.platform_server.server_address[1]}"
        self.expectations = read_expectations()

    def stop_platform_server(self):
        self.platform_server.shutdown()
        self.platform_server.server_close()

    def actors(self):
        return {"admin": "adm", "platform-admin": {"user": PLATFORM_USER, "tenant": PLATFORM_TENANT,
                                                   "base_url": self.platform_base}}

    def records(self, run_dir=None):
        path = Path(run_dir or self.run_dir) / "run.jsonl"
        if not path.exists():
            return []
        return [json.loads(x) for x in path.read_text(encoding="utf-8").splitlines() if x.strip()]

    def do_run(self, module, run_dir=None):
        """The normal path: a run of the scenario. -> (exit code, the checks it made)"""
        run_dir = Path(run_dir or self.run_dir)
        out = io.StringIO()
        r = module.Runner([scenario()], base_url=self.base, tenant=MAIN_TENANT, actors=self.actors(),
                           run_dir=run_dir, inputs={}, poll_interval=0.01, out=out, allow_create=True,
                           build_sha=SHA)
        code = r.run()
        return code, observed_checks(self.records(run_dir))

    def do_replay(self, module, run_dir=None):
        """The cleanup replay of the run in this run dir. -> (exit code, the checks it made)"""
        run_dir = Path(run_dir or self.run_dir)
        before = len(self.records(run_dir))
        out = io.StringIO()
        r = module.Runner([{"id": "cleanup", "steps": []}], base_url=self.base, tenant=MAIN_TENANT,
                           actors=self.actors(), run_dir=run_dir, poll_interval=0.01, out=out)
        code = r.replay_cleanup()
        return code, observed_checks(self.records(run_dir)[before:])

    def residue_row(self, records=None):
        rows = [r for r in (records if records is not None else self.records())
                if r.get("step") == "tenant residue check"]
        return rows[-1] if rows else None


class TheEquivalence(SafetyCase):
    """The two paths must judge the same safety checks (the reviewed expectations say which)."""

    def test_E1_the_run_path_makes_the_checks_the_expectations_name(self):
        code, kinds = self.do_run(runner)
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        self.assertEqual(path_problems("run", kinds, self.expectations, "run"), [])

    def test_E2_the_replay_path_makes_the_checks_the_expectations_name(self):
        self.do_run(runner)
        code, kinds = self.do_replay(runner)
        self.assertEqual(code, 0, (self.run_dir / "summary-cleanup.md").read_text())
        self.assertEqual(path_problems("replay", kinds, self.expectations, "replay"), [])

    def test_E3_the_two_paths_are_equivalent(self):
        _, run_kinds = self.do_run(runner)
        _, replay_kinds = self.do_replay(runner)
        self.assertEqual(divergences(run_kinds, replay_kinds, self.expectations), [])

    def test_E4_the_inventory_is_not_empty_and_covers_every_check_kind(self):
        _, run_kinds = self.do_run(runner)
        _, replay_kinds = self.do_replay(runner)
        self.assertTrue(run_kinds, "the run path made no safety check at all")
        self.assertTrue(replay_kinds, "the replay path made no safety check at all")
        self.assertEqual(sorted(self.expectations), sorted(CHECK_KINDS))

    def test_E5_the_command_line_replay_makes_the_same_checks(self):
        self.do_run(runner)
        before = len(self.records())
        with contextlib.redirect_stdout(io.StringIO()):
            code = runner.main(["cleanup", str(self.run_dir)])
        self.assertEqual(code, 0, (self.run_dir / "summary-cleanup.md").read_text())
        cli_kinds = observed_checks(self.records()[before:])
        _, replay_kinds = self.do_replay(runner)
        self.assertEqual(cli_kinds, replay_kinds)


class TheMissingBaseline(SafetyCase):
    """A baseline the run promised and that is gone: the replay fails closed, it does not pass."""

    def replay_code(self, name):
        self.do_run(runner)
        (self.run_dir / name).unlink()
        code, _ = self.do_replay(runner)
        return code

    def test_F1_a_missing_residue_baseline_fails_the_replay(self):
        code = self.replay_code("residue_before.json")
        self.assertEqual(code, 1)
        row = self.residue_row()
        self.assertEqual(row["verdict"], "fail")
        self.assertIn(f"the residue baseline of tenant {MAIN_TENANT} is gone", row["error"])

    def test_F2_a_missing_platform_baseline_fails_the_replay(self):
        code = self.replay_code("platform_before.json")
        self.assertEqual(code, 1)
        row = self.residue_row()
        self.assertEqual(row["verdict"], "fail")
        self.assertIn(f"the platform baseline of tenant {PLATFORM_TENANT} is gone", row["error"])

    def test_F3_a_missing_platform_watch_fails_the_replay(self):
        code = self.replay_code("platform_watch.json")
        self.assertEqual(code, 1)
        row = self.residue_row()
        self.assertEqual(row["verdict"], "fail")
        self.assertIn("the platform watch of the run is gone", row["error"])

    def test_F4_a_missing_expectations_file_fails_the_replay(self):
        code = self.replay_code("safety.json")
        self.assertEqual(code, 1)
        row = self.residue_row()
        self.assertEqual(row["verdict"], "fail")
        self.assertIn("the run dir has no safety expectations", row["error"])

    def test_F5_a_complete_run_dir_passes(self):
        self.do_run(runner)
        code, _ = self.do_replay(runner)
        self.assertEqual(code, 0, (self.run_dir / "summary-cleanup.md").read_text())
        self.assertEqual(self.residue_row()["verdict"], "pass")


class TheSeededFailures(SafetyCase):
    """The probe must catch a runner that lost a check of the replay (the T-2606 class)."""

    def test_N1_a_replay_that_skips_the_residue_check_is_caught(self):
        broken = mutant([("residue_ok = self.check_residue()\n", "residue_ok = True\n")], self.tmp.name)
        _, run_kinds = self.do_run(runner)
        _, replay_kinds = self.do_replay(broken)
        problems = divergences(run_kinds, replay_kinds, self.expectations)
        self.assertTrue(problems, "the probe did not see that the broken replay skips the residue check")
        self.assertTrue(any("residue" in p for p in problems), problems)

    def test_N2_a_replay_that_fails_open_on_a_missing_baseline_is_caught(self):
        broken = mutant([("self.baseline_problems = self._replay_baseline_problems()\n",
                          "self.baseline_problems = []\n")], self.tmp.name)
        run_dir = Path(self.tmp.name) / "broken"
        self.do_run(broken, run_dir)
        (run_dir / "residue_before.json").unlink()
        code, _ = self.do_replay(broken, run_dir)
        self.assertEqual(code, 0, "the broken replay passed a run it cannot judge")
        # the real runner fails closed on the same run dir
        good_dir = Path(self.tmp.name) / "good"
        self.do_run(runner, good_dir)
        (good_dir / "residue_before.json").unlink()
        code, _ = self.do_replay(runner, good_dir)
        self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
