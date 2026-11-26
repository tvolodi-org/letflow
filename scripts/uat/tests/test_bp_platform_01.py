"""Tests of the BP-PLATFORM-01 scenario file, step A (T-2744): the expectations of the file judge a good answer as
good and a defective one (definition missing, not active, a service step without its function, a notify step
without its function, a registry without the entry) as failed. No network, no model: the answers are canned.

Run: python3 -B -m unittest -v scripts/uat/tests/test_bp_platform_01.py   (from the repository root)
"""

import copy
import io
import json
import re
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import runner  # noqa: E402
from fakes import FakeServerCase  # noqa: E402

FILE = HERE.parents[2] / "test" / "uat" / "processes" / "BP-PLATFORM-01-register-tenant.json"
CALLS = [
    ("validate", "tenant.validate"),
    ("create", "tenant.create"),
    ("provision", "tenant.provision"),
    ("record_lifecycle", "tenant.record_lifecycle"),
    ("record_onboarding", "tenant.record_onboarding"),
    ("bind_realm", "tenant.bind_realm"),
    ("grant_first_admins", "tenant.grant_first_admins"),
    ("install_default_modules", "tenant.install_default_modules"),
]
FUNCTIONS = [
    "platform.validate_registration",
    "tenant.bind_realm",
    "tenant.create",
    "tenant.grant_first_admins",
    "tenant.install_default_modules",
    "tenant.notify_admin",
    "tenant.provision",
    "tenant.record_lifecycle",
    "tenant.record_onboarding",
    "tenant.validate",
]


def definition():
    nodes = [{"id": "start", "node_type": "START"}]
    for node_id, fn in CALLS:
        nodes.append({"id": node_id, "node_type": "SERVICE_TASK", "attributes": {"platform_call": {"function": fn}}})
    nodes.append({"id": "notify_gate", "node_type": "EXCLUSIVE_GATEWAY"})
    # T-2727 V8: the notify step is a platform step of tenant.notify_admin.
    nodes.append({"id": "notify", "node_type": "SERVICE_TASK", "attributes": {
        "platform_call": {"function": "tenant.notify_admin"}}})
    nodes.append({"id": "end", "node_type": "END"})
    return {"id": "d1", "name": "platform.register_tenant", "version": "2", "status": "ACTIVE", "graph": {"nodes": nodes}}


def registry():
    return {"items": [{"name": n, "inputs": [{"name": "x"}], "outputs": [{"name": "y"}]} for n in FUNCTIONS]}


def templates():
    keys = ["asset_expiry_reminder", "exam_assigned", "exam_reminder", "exam_result", "password_reset_hint",
            "problem_report_status", "task_assigned", "tenant_registered"]
    return {"items": [{"template_key": k, "placeholders": ["tenant_name", "tenant_slug", "registered_by"]} for k in keys]}


class StepA(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.process = json.loads(FILE.read_text())
        cls.steps = {s["id"]: s for s in cls.process["steps"]}

    def verdict(self, step_id, body, status=200):
        rows = runner.run_assertions(self.steps[step_id]["expect"], status, body)
        return all(r["ok"] for r in rows)

    def test_step_a_is_read_only(self):
        self.assertEqual(["A1", "A2", "A3a", "A3b"], list(self.steps)[:4])
        for sid in ("A1", "A2", "A3a", "A3b"):
            self.assertEqual("GET", self.steps[sid]["do"]["api"])
        self.assertIsNone(re.search(r"qoimeks-qa(?!2)", FILE.read_text()))
        self.assertEqual("bpm-default", self.process["dry_run"]["actors"]["admin"]["tenant"])
        self.assertIn("web/tests/e2e/pilot-register-tenant-qa.e2e.spec.ts", self.process["description"])
        self.assertNotIn("pilot-register-tenant-designer.e2e.spec.ts", self.process["description"])

    def test_a1_active_definition(self):
        self.assertTrue(self.verdict("A1", definition()))

    def test_a1_missing_or_not_active_fails(self):
        self.assertFalse(self.verdict("A1", {"error": "not_found"}, status=404))
        draft = definition()
        draft["status"] = "DRAFT"
        self.assertFalse(self.verdict("A1", draft))
        draft = definition()
        draft["version"] = "0"
        self.assertFalse(self.verdict("A1", draft))

    def test_a2_complete_graph(self):
        self.assertTrue(self.verdict("A2", definition()))

    def test_a2_service_step_without_function_fails(self):
        d = definition()
        d["graph"]["nodes"][3]["attributes"] = {}
        self.assertFalse(self.verdict("A2", d))

    def test_a2_notify_without_its_function_fails(self):
        d = definition()
        d["graph"]["nodes"][10]["attributes"] = {}
        self.assertFalse(self.verdict("A2", d))
        d = copy.deepcopy(definition())
        d["graph"]["nodes"][10]["attributes"]["platform_call"]["function"] = "tenant.provision"
        self.assertFalse(self.verdict("A2", d))

    def test_a2_node_count_is_twelve(self):
        d = definition()
        d["graph"]["nodes"].append({"id": "extra", "node_type": "END"})
        self.assertFalse(self.verdict("A2", d))
        d = definition()
        del d["graph"]["nodes"][1]
        self.assertFalse(self.verdict("A2", d))

    def test_a3_registry_and_template_options(self):
        self.assertTrue(self.verdict("A3a", registry()))
        self.assertTrue(self.verdict("A3b", templates()))
        self.assertFalse(self.verdict("A3a", {"items": []}))
        self.assertFalse(self.verdict("A3b", {"items": []}))
        t = templates()
        t["items"][7]["placeholders"] = []
        self.assertFalse(self.verdict("A3b", t))


class StepsBToH(unittest.TestCase):
    """T-2608: the start, the run, the step log, the mail, the retry, the designer edit, the rollback, the refusals."""

    @classmethod
    def setUpClass(cls):
        cls.process = json.loads(FILE.read_text())
        cls.steps = {s["id"]: s for s in cls.process["steps"]}
        cls.cleanup = {s["id"]: s for s in cls.process["cleanup"]}

    def verdict(self, step_id, body, status=200):
        rows = runner.run_assertions(self.steps[step_id]["expect"], status, body)
        return all(r["ok"] for r in rows)

    def log(self, nodes, results=None):
        rows = [{"node_id": n, "result": (results or {}).get(n, "completed"), "attempts": 1,
                 "started_at": "2026-11-25T00:00:00Z", "duration_ms": 5, "last_failure_kind": None}
                for n in nodes]
        return {"items": [], "steps": rows}

    V1 = ["start", "validate", "create", "provision", "record_lifecycle", "record_onboarding", "bind_realm",
          "grant_first_admins", "install_default_modules", "notify_gate", "notify", "end"]
    DRAFT = ["start", "validate", "create", "provision", "bind_realm", "grant_first_admins", "notify"]
    V2 = DRAFT + ["notify_file", "end"]

    def test_the_steps_run_in_the_order_of_the_scenario(self):
        ids = list(self.steps)
        order = ["A1", "A2", "A3a", "A3b", "B0a", "B0b", "B0c", "B1n", "B1", "B2", "B3", "C1", "C2", "C3", "C4", "C5", "D1", "E1", "E2",
                 "E3", "E4", "E5", "E6", "F1", "F2", "F3", "F5", "F6", "F7", "F8", "F9", "F10", "G1", "G2",
                 "G3", "G4", "G5", "G6", "H1", "H2", "H3", "H4", "H5", "H6"]
        self.assertEqual(order, ids)
        self.assertLess(ids.index("B0b"), ids.index("B1"))  # the allowed destination comes before the mail step

    def test_only_throwaway_tenants_are_created_and_each_is_deactivated(self):
        slugs = set()
        for sid in ("B1", "E1", "F6", "G3"):
            body = self.steps[sid]["do"]["body"]
            self.assertTrue(body["slug"].startswith("uat-tmp-"), sid)
            self.assertTrue(body["hostname"].startswith(body["slug"]), sid)
            self.assertTrue(body["admin_email"].endswith("@uat.letflow.internal"), sid)
            slugs.add(body["slug"])
        self.assertEqual(4, len(slugs))
        for i in (1, 2, 3, 4):
            c = next(c for c in self.process["cleanup"] if c["do"]["path"] == f"/api/v1/tenants/${{slug{i}}}/deactivate")
            self.assertEqual([f"slug{i}"], c["requires"])
        self.assertNotIn("qoimeks-client1", FILE.read_text())

    def test_every_cleanup_step_is_conditional_on_what_the_run_made(self):
        for step in self.process["cleanup"]:
            self.assertTrue(step.get("requires"), step["id"])
        self.assertEqual(["rolled_back"], self.cleanup["c1"]["skip_if"])
        self.assertEqual({"definitions": ["platform.register_tenant"],
                          "instances": ["${instance_id1}", "${instance_id2}", "${instance_id3}", "${instance_id4}"]},
                         self.process["platform_residue"])

    def test_the_trap_steps_name_the_two_causes_and_are_bounded(self):
        for sid in ("B2", "B3"):
            self.assertEqual("${stuck_after_s}", self.steps[sid]["poll"]["within_s"])
        self.assertIn("did not arm", self.steps["B2"]["says"])
        self.assertIn("LETFLOW_START_PLATFORM_STEP_RUNNER", self.steps["B3"]["says"])
        self.assertEqual("60", self.process["defaults"]["stuck_after_s"])

    def test_c2_the_six_steps_in_order_all_completed(self):
        self.assertTrue(self.verdict("C2", self.log(self.V1)))

    def test_c2_a_missing_or_failed_or_reordered_step_fails(self):
        self.assertFalse(self.verdict("C2", self.log(self.V1, {"create": "failed"})))
        self.assertFalse(self.verdict("C2", self.log(self.V1, {"notify": "running"})))
        swapped = list(self.V1)
        swapped[2], swapped[3] = swapped[3], swapped[2]
        self.assertFalse(self.verdict("C2", self.log(swapped)))
        self.assertFalse(self.verdict("C2", self.log(self.V1[:-2] + ["end"])))

    def test_c1_the_instance_must_be_completed(self):
        self.assertTrue(self.verdict("C1", {"status": "COMPLETED"}))
        self.assertFalse(self.verdict("C1", {"status": "ACTIVE"}))
        self.assertFalse(self.verdict("B3", self.log(self.V1, {"validate": "running"})))
        self.assertTrue(self.verdict("B3", self.log(self.V1)))
        self.assertFalse(self.verdict("B2", {"steps": []}))

    def test_e3_the_failed_step_is_named(self):
        rows = self.log(self.V1, {"bind_realm": "failed"})
        rows["steps"][6]["last_failure_kind"] = "refused"
        self.assertTrue(self.verdict("E3", rows))
        self.assertFalse(self.verdict("E3", self.log(self.V1)))
        self.assertTrue(self.verdict("E2", {"status": "ERROR"}))
        self.assertFalse(self.verdict("E2", {"status": "COMPLETED"}))

    def test_e6_a_second_attempt_is_shown(self):
        rows = self.log(self.V1, {"bind_realm": "failed"})
        rows["steps"][6]["attempts"] = 2
        self.assertTrue(self.verdict("E6", rows))
        self.assertFalse(self.verdict("E6", self.log(self.V1, {"bind_realm": "failed"})))

    def test_f_the_edited_version_has_the_file_step_and_g_the_rollback_does_not(self):
        self.assertTrue(self.verdict("F8", self.log(self.V2)))
        self.assertFalse(self.verdict("F8", self.log(self.V1)))
        self.assertTrue(self.verdict("G5", self.log(self.V1)))
        self.assertFalse(self.verdict("G5", self.log(self.V2)))
        self.assertFalse(self.verdict("G5", self.log(self.DRAFT + ["end"])))

    def test_f1_the_draft_graph_is_the_shipped_one_plus_a_file_step_without_a_path(self):
        graph = self.steps["F1"]["do"]["body"]["graph"]
        ids = [n["id"] for n in graph["nodes"]]
        self.assertEqual(["start", "validate", "create", "provision", "bind_realm", "grant_first_admins", "notify",
                          "notify_file", "end"], ids)
        node = graph["nodes"][7]["attributes"]["notify"]
        self.assertEqual({"channel": "file", "file_name": "registration-notice"},
                         {k: node[k] for k in ("channel", "file_name")})
        self.assertNotIn("recipient", node)  # the channels are exclusive
        bad = self.steps["F3"]["do"]["body"]["graph"]["nodes"][7]["attributes"]["notify"]["file_name"]
        self.assertEqual("../x", bad)
        self.assertEqual([e["target"] for e in graph["edges"] if e["source"] == "notify"], ["notify_file"])
        # the product refuses the path-like name when the draft is SAVED: the refusal is the F3 step itself
        self.assertEqual([422], self.steps["F3"]["expect_refused"]["status"])
        self.assertEqual("notify_file_name_invalid", self.steps["F3"]["expect_refused"]["code"])
        self.assertNotIn("F4", self.steps)

    def test_the_rollback_is_one_call_to_the_version_a1_read(self):
        self.assertIn("$.version", self.steps["A1"]["save"].values())
        self.assertEqual("${version1}", self.steps["G1"]["do"]["body"]["target_version"])
        self.assertEqual("POST", self.steps["G1"]["do"]["api"])
        self.assertEqual("/api/v1/definitions/platform.register_tenant/rollback", self.steps["G1"]["do"]["path"])

    def test_the_allowed_destination_is_added_visibly_and_removed(self):
        self.assertEqual({"channel": "email", "destination": "uat.letflow.internal"}, self.steps["B0b"]["do"]["body"])
        self.assertEqual(["domain_added"], self.cleanup["c7"]["requires"])
        self.assertIn("destination=uat.letflow.internal", self.cleanup["c7"]["do"]["path"])
        self.assertEqual("DELETE", self.cleanup["c7"]["do"]["api"])

    def test_the_mail_steps_wait_for_the_subject_of_the_template(self):
        for sid, slug in (("D1", "slug1"), ("F9", "slug3"), ("G6", "slug4")):
            spec = self.steps[sid]["do"]["wait_mail"]
            self.assertEqual(f"Tenant ${{{slug}}} is registered", spec["subject"])
            self.assertTrue(spec["recipient"].endswith("@uat.letflow.internal"))
            runner.validate_step(self.steps[sid], sid)

    def test_h_the_company_user_is_refused_everywhere(self):
        for sid in ("H1", "H2", "H3", "H4", "H5", "H6"):
            self.assertEqual("storekeeper", self.steps[sid]["actor"])
            self.assertEqual([403, 404], self.steps[sid]["expect_refused"]["status"])
        self.assertEqual("qoimeks-qa2-storekeeper", self.process["dry_run"]["actors"]["storekeeper"])

    def test_h2_is_marked_as_a_refusal_probe(self):
        self.assertTrue(self.steps["H2"].get("refusal_probe"))
        self.assertEqual("/api/v1/tenants", self.steps["H2"]["do"]["path"])

    def test_b2_tells_a_missing_dispatch_row_from_a_pending_one(self):
        # a visit with no dispatch row: step is null and the log counts one attempt (merge_dispatch(step, nil))
        missing = {"steps": [{"node_id": "start", "result": "completed"},
                             {"node_id": "validate", "step": None, "result": "running", "attempts": 1}]}
        pending = {"steps": [{"node_id": "start", "result": "completed"},
                             {"node_id": "validate", "step": "tenant.validate", "result": "running", "attempts": 0}]}
        self.assertFalse(self.verdict("B2", missing))
        self.assertTrue(self.verdict("B2", pending))
        self.assertFalse(self.verdict("B3", pending))  # armed but never run: the runner is off

    def test_the_process_creates_the_realm_and_the_unknown_realm_is_a_negative(self):
        # /onboarding probes a realm that is SENT; the registrations send none, the process creates it
        for sid in ("B1", "F6", "G3"):
            self.assertNotIn("idp_realm_id", self.steps[sid]["do"]["body"], sid)
        neg = self.steps["B1n"]
        self.assertEqual("/api/v1/onboarding", neg["do"]["path"])
        self.assertIn("idp_realm_id", neg["do"]["body"])
        self.assertEqual(422, neg["expect"]["status"])
        self.assertEqual("idp_realm_id", neg["expect"]["json"]["$.errors[0].field"])
        self.assertNotIn("save", neg)
        # C3 reads the created realm back; E1 reuses it: the bind refuses a realm bound to another tenant
        self.assertEqual("$.idp_realm_id", self.steps["C3"]["save"]["realm1"])
        self.assertEqual("${realm1}", self.steps["E1"]["do"]["body"]["idp_realm_id"])
        self.assertNotIn("realm", self.process["inputs"])

    def test_the_description_names_the_setting_and_no_marker_is_left(self):
        text = self.process["description"]
        self.assertIn("LETFLOW_PROVISIONER_CREATE_VIA_PROCESS=true", text)
        self.assertIn("No step carries a blocked_by marker now", text)
        self.assertIn("file", self.steps["F8"]["says"])

    def test_a_non_finite_wait_time_is_refused(self):
        self.assertFalse(runner.wait_time_ok("1e400"))
        self.assertFalse(runner.wait_time_ok(float("inf")))
        self.assertTrue(runner.wait_time_ok("60"))

    def test_every_step_passes_the_runner_validation(self):
        for step in self.process["steps"] + self.process["cleanup"]:
            runner.validate_step(step, step["id"])


class Refuser(BaseHTTPRequestHandler):
    """A company tenant's API: every POST to the tenant registry is refused with 403 and recorded."""

    seen = []

    def do_GET(self):  # noqa: N802
        self.reply(200, {"status": "ok", "sha": "abc123"})

    def do_POST(self):  # noqa: N802
        type(self).seen.append(self.path)
        self.reply(403, {"error": "forbidden"})

    def reply(self, status, doc):
        data = json.dumps(doc).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


class H2IsPlayed(FakeServerCase):
    """T-2608 review: the create-gate must not swallow the refusal probe H2, and must still stop an ordinary create."""

    def setUp(self):
        super().setUp()
        self.handler = type("R", (Refuser,), {"seen": []})
        self.other = ThreadingHTTPServer(("127.0.0.1", 0), self.handler)
        threading.Thread(target=self.other.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True).start()
        self.addCleanup(self.other.server_close)
        self.addCleanup(self.other.shutdown)
        self.actors = {"storekeeper": {"user": "sk", "tenant": "qoimeks-qa2",
                                       "base_url": f"http://127.0.0.1:{self.other.server_address[1]}"}}

    def play(self, step):
        r = runner.Runner({"id": "H", "steps": [step]}, base_url=self.base, tenant="qoimeks-qa2", actors=self.actors,
                          run_dir=self.run_dir, inputs={}, poll_interval=0.01, out=io.StringIO())
        code = r.run()
        return code, next(x for x in self.lines() if x["phase"] == "step" and x["step"] == step["id"])

    def h2(self):
        process = json.loads(FILE.read_text())
        step = next(x for x in process["steps"] if x["id"] == "H2")
        step["do"]["body"]["slug"] = "uat-tmp-00000000"
        return step

    def test_the_marked_refusal_is_sent_and_recorded_as_a_pass(self):
        code, row = self.play(self.h2())
        self.assertEqual(["/api/v1/tenants"], self.handler.seen)
        self.assertEqual("pass", row["verdict"])
        self.assertEqual(0, code)

    def test_the_same_step_without_the_mark_is_stopped_by_the_gate(self):
        step = self.h2()
        del step["refusal_probe"]
        code, row = self.play(step)
        self.assertEqual([], self.handler.seen)
        self.assertEqual("skipped", row["verdict"])


class BlockedSteps(H2IsPlayed):
    """PM answer 12:20 (D-195): a blocked_by step is never run, never a failure, never a pass."""

    def test_a_blocked_step_sends_nothing_and_is_reported_not_run(self):
        step = self.h2()
        del step["refusal_probe"]
        step["blocked_by"] = "T-2727 provisioner wiring"
        code, row = self.play(step)
        self.assertEqual([], self.handler.seen)
        self.assertEqual("blocked", row["verdict"])
        self.assertEqual("not run: blocked by T-2727 provisioner wiring", row["error"])
        self.assertEqual(0, code)
        summary = (self.run_dir / "summary.md").read_text()
        self.assertIn("steps not run (blocked_by): 1", summary)
        self.assertIn("1 steps NOT RUN", summary)

    def test_no_step_of_the_scenario_is_parked_any_more(self):
        """T-2827: the create-via-process setting is on at QA; a marker needs an owner and a reason."""
        process = json.loads(FILE.read_text())
        marked = {x["id"] for x in process["steps"] if x.get("blocked_by")}
        self.assertEqual(set(), marked)

    def test_fresh_tenant_module_install_ends_active(self):
        """G14 finding: no shipped definition of a fresh tenant stays a draft; an empty install does not pass."""
        steps = {x["id"]: x for x in json.loads(FILE.read_text())["steps"]}
        c4, c5 = steps["C4"], steps["C5"]
        self.assertIn("status=draft", c4["do"]["path"])
        self.assertEqual({"absent": True}, c4["expect"]["json"]["$.items[0]"])
        self.assertIn("status=active", c5["do"]["path"])
        self.assertEqual("ACTIVE", c5["expect"]["json"]["$.items[0].status"])

    def test_blocked_by_and_refusal_probe_are_validated(self):
        base = {"id": "X", "actor": "admin", "do": {"api": "GET", "path": "/x"}}
        with self.assertRaises(runner.ConfigError):
            runner.validate_step({**base, "blocked_by": " "}, "X")
        with self.assertRaises(runner.ConfigError):
            runner.validate_step({**base, "refusal_probe": True}, "X")
        with self.assertRaises(runner.ConfigError):
            runner.validate_step({**base, "expect_refused": {}, "refusal_probe": "yes"}, "X")
        runner.validate_step({**base, "expect_refused": {}, "refusal_probe": True}, "X")


class BlockedNeverFails(H2IsPlayed):
    """T-2783: blocked steps never fail a run, a step that needs their value is blocked, not skipped."""

    def run_steps(self, steps, **extra):
        r = runner.Runner({"id": "H", "steps": steps, **extra}, base_url=self.base, tenant="qoimeks-qa2",
                          actors=self.actors, run_dir=self.run_dir, inputs={}, poll_interval=0.01,
                          out=io.StringIO())
        code = r.run()
        return code, {x["step"]: x for x in self.lines() if x["phase"] == "step"}

    def blocked(self):
        step = self.h2()
        del step["refusal_probe"]
        step.update(id="B", blocked_by="T-2727 provisioner wiring", save={"inst": "$.instance_id"})
        return step

    def needing(self, sid):
        step = self.h2()
        del step["refusal_probe"]
        step.update(id=sid, requires=["inst"])
        return step

    def test_a_step_needing_a_blocked_value_is_blocked_and_the_run_passes(self):
        code, rows = self.run_steps([self.blocked(), self.needing("N")])
        self.assertEqual("blocked", rows["B"]["verdict"])
        self.assertEqual("blocked", rows["N"]["verdict"])
        self.assertEqual("not run: blocked by T-2727 provisioner wiring", rows["N"]["error"])
        self.assertEqual([], self.handler.seen)
        self.assertEqual(0, code)

    def test_after_a_failure_a_blocked_step_stays_blocked_and_the_skip_names_the_failure(self):
        fail = self.h2()
        fail.update(id="X", expect={"status": 418})
        del fail["expect_refused"], fail["refusal_probe"]
        fail["do"] = {"api": "GET", "path": "/api/v1/definitions"}
        _, rows = self.run_steps([self.blocked(), fail, self.needing("N"), dict(self.h2(), id="S")])
        self.assertEqual("fail", rows["X"]["verdict"])
        self.assertEqual("blocked", rows["N"]["verdict"])
        self.assertEqual("skipped", rows["S"]["verdict"])
        self.assertIn("(X)", rows["S"]["error"])

    def test_the_residue_watch_ignores_an_instance_of_a_blocked_step(self):
        r = runner.Runner({"id": "H", "steps": []}, base_url=self.base, tenant="t", actors={}, run_dir=self.run_dir,
                          inputs={}, poll_interval=0.01, out=io.StringIO())
        r.blocked_saves["inst"] = "why"
        self.assertEqual([], r._watched_instances("t", {"instances": ["${inst}"]}))
        with self.assertRaises(runner.RunnerError):
            r._watched_instances("t", {"instances": ["${other}"]})

    def test_the_scenario_keeps_no_document_check_on_the_platform_tenant(self):
        self.assertIs(False, json.loads(FILE.read_text())["residue_check"])


if __name__ == "__main__":
    unittest.main()
