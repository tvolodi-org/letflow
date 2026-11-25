"""Tests of the BP-PLATFORM-01 scenario file, step A (T-2744): the expectations of the file judge a good answer as
good and a defective one (definition missing, not active, a service step without its function, a notify step
without recipient, a registry without the entry) as failed. No network, no model: the answers are canned.

Run: python3 -B -m unittest -v scripts/uat/tests/test_bp_platform_01.py   (from the repository root)
"""

import copy
import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import runner  # noqa: E402

FILE = HERE.parents[2] / "test" / "uat" / "processes" / "BP-PLATFORM-01-register-tenant.json"
CALLS = [
    ("validate", "tenant.validate"),
    ("create", "tenant.create"),
    ("provision", "tenant.provision"),
    ("bind_realm", "tenant.bind_realm"),
    ("grant_first_admins", "tenant.grant_first_admins"),
]
FUNCTIONS = [
    "platform.validate_registration",
    "tenant.bind_realm",
    "tenant.create",
    "tenant.grant_first_admins",
    "tenant.install_default_modules",
    "tenant.provision",
    "tenant.validate",
]


def definition():
    nodes = [{"id": "start", "node_type": "START"}]
    for node_id, fn in CALLS:
        nodes.append({"id": node_id, "node_type": "SERVICE_TASK", "attributes": {"platform_call": {"function": fn}}})
    nodes.append({"id": "notify", "node_type": "SERVICE_TASK", "attributes": {
        "notify": {"template_key": "tenant_registered", "recipient": {"var": "admin_email"}}}})
    nodes.append({"id": "end", "node_type": "END"})
    return {"id": "d1", "name": "platform.register_tenant", "version": "1", "status": "ACTIVE", "graph": {"nodes": nodes}}


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
        self.assertNotIn("qoimeks-qa\"", FILE.read_text())
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

    def test_a2_notify_without_recipient_or_template_fails(self):
        d = definition()
        del d["graph"]["nodes"][6]["attributes"]["notify"]["recipient"]
        self.assertFalse(self.verdict("A2", d))
        d = copy.deepcopy(definition())
        d["graph"]["nodes"][6]["attributes"]["notify"]["template_key"] = None
        self.assertFalse(self.verdict("A2", d))

    def test_a2_node_count_is_eight(self):
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

    V1 = ["start", "validate", "create", "provision", "bind_realm", "grant_first_admins", "notify", "end"]
    V2 = V1[:-1] + ["notify_file", "end"]

    def test_the_steps_run_in_the_order_of_the_scenario(self):
        ids = list(self.steps)
        order = ["A1", "A2", "A3a", "A3b", "B0a", "B0b", "B0c", "B1", "B2", "B3", "C1", "C2", "C3", "D1", "E1", "E2",
                 "E3", "E4", "E5", "E6", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "G1", "G2",
                 "G3", "G4", "G5", "G6", "H1", "H2", "H3", "H4", "H5"]
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
        rows["steps"][4]["last_failure_kind"] = "refused"
        self.assertTrue(self.verdict("E3", rows))
        self.assertFalse(self.verdict("E3", self.log(self.V1)))
        self.assertTrue(self.verdict("E2", {"status": "ERROR"}))
        self.assertFalse(self.verdict("E2", {"status": "COMPLETED"}))

    def test_e6_a_second_attempt_is_shown(self):
        rows = self.log(self.V1, {"bind_realm": "failed"})
        rows["steps"][4]["attempts"] = 2
        self.assertTrue(self.verdict("E6", rows))
        self.assertFalse(self.verdict("E6", self.log(self.V1, {"bind_realm": "failed"})))

    def test_f_the_edited_version_has_the_file_step_and_g_the_rollback_does_not(self):
        self.assertTrue(self.verdict("F8", self.log(self.V2)))
        self.assertFalse(self.verdict("F8", self.log(self.V1)))
        self.assertTrue(self.verdict("G5", self.log(self.V1)))
        self.assertFalse(self.verdict("G5", self.log(self.V2)))

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
        self.assertIn("status", self.steps["F4"]["expect_refused"])

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
        for sid in ("H1", "H2", "H3", "H4", "H5"):
            self.assertEqual("storekeeper", self.steps[sid]["actor"])
            self.assertEqual([403, 404], self.steps[sid]["expect_refused"]["status"])
        self.assertEqual("qoimeks-qa2-storekeeper", self.process["dry_run"]["actors"]["storekeeper"])

    def test_every_step_passes_the_runner_validation(self):
        for step in self.process["steps"] + self.process["cleanup"]:
            runner.validate_step(step, step["id"])


if __name__ == "__main__":
    unittest.main()
