"""Tests of the BP-PLATFORM-25 scenario file (T-2816): the designer checks the runner can do through the API, the
steps it cannot do carry 'not run' with an OWNER, the cleanup retires the throwaway definitions (and the three
leftovers of the 2026-11-25 walk) with the product's own DELETE call, and the designer strings (including the Guide
entry) exist in en, ru and kk, with the three guide documents on disk. No network, no model.

Run: python3 -B -m unittest -v scripts/uat/tests/test_bp_platform_25.py   (from the repository root)
"""

import json
import re
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import runner  # noqa: E402

ROOT = HERE.parents[2]
FILE = ROOT / "test" / "uat" / "processes" / "BP-PLATFORM-25-designer.json"
MESSAGES = ROOT / "web" / "src" / "pages" / "definitions" / "definitionsMessages.ts"
LEFTOVERS = {
    "8dc15fc1-d618-471e-afbc-514afe549559",
    "df9f05bd-49c2-4d00-8c9b-b392a26a880b",
    "667a9e0f-6787-49c5-98bb-e00c9128930c",
}


class Scenario(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = FILE.read_text()
        cls.process = json.loads(cls.text)
        cls.steps = {s["id"]: s for s in cls.process["steps"]}

    def test_every_step_passes_the_runner_validation(self):
        for step in self.process["steps"] + self.process["cleanup"]:
            runner.validate_step(step, step["id"])

    def test_no_provisioner_no_tenant_no_mail(self):
        for token in ("/api/v1/onboarding", "/api/v1/tenants", "tenant.create", "notify", "outbound-destinations"):
            self.assertNotIn(token, self.text)

    def test_export_import_round_trip_compares_the_graph(self):
        self.assertEqual(self.steps["A2"]["do"]["path"], "/api/v1/definitions/${defX}/export")
        self.assertEqual(self.steps["A3"]["do"]["path"], "/api/v1/definitions/import")
        # the imported graph is read back and compared with the exported one, by the same keys
        exported = self.steps["A2"]["expect"]["json"]
        read_back = self.steps["A4"]["expect"]["json"]
        for key in ("$.graph.nodes[1].id", "$.graph.nodes[1].attributes.platform_call.function", "$.graph.edges[1].target"):
            self.assertEqual(exported.get(key), read_back.get(key), key)
        self.assertIn("refused", json.dumps(self.steps["A6"]))

    def test_instances_step_log_and_dlq_retry(self):
        self.assertTrue(self.steps["B4"]["do"]["path"].startswith("/api/v1/instances"))
        self.assertEqual(self.steps["B5"]["expect"]["json"]["$.status"], "ERROR")
        self.assertTrue(self.steps["B6"]["do"]["path"].endswith("/timeline"))
        self.assertTrue(self.steps["B7"]["do"]["path"].startswith("/api/v1/dlq"))
        self.assertEqual(self.steps["B8"]["do"]["path"], "/api/v1/dlq/${dlq_id}/retry")
        self.assertEqual(self.steps["B9"]["expect"]["json"]["$.steps[1].attempts"], {"regex": "^[2-9]$"})
        self.assertEqual(self.steps["B3"]["do"]["body"]["initial_variables"]["slug"], "X-${uuid2}")  # T-2897: unique per run (the call key is the slug)

    def test_unrunnable_steps_are_not_run_with_an_owner(self):
        for sid in ("D1", "D2", "D3", "D4"):
            why = self.steps[sid]["blocked_by"]
            self.assertTrue(why.startswith("OWNER: "), sid)
            self.assertGreater(len(why), 60, sid)
        self.assertIn("infra", self.steps["D1"]["blocked_by"])
        self.assertIn("web/tests/e2e", self.steps["D2"]["blocked_by"])
        self.assertIn("web/tests/e2e", self.steps["D3"]["blocked_by"])
        # only the four are blocked; every other step really runs
        blocked = {s["id"] for s in self.process["steps"] if "blocked_by" in s}
        self.assertEqual(blocked, {"D1", "D2", "D3", "D4"})

    def test_cleanup_uses_delete_for_throwaways_and_the_three_leftovers(self):
        by_path = {c["do"]["path"]: c for c in self.process["cleanup"] if c["do"].get("api") == "DELETE"}
        for key in ("defX", "defY"):
            c = by_path["/api/v1/definitions/${%s}" % key]
            self.assertEqual(c["requires"], [key])
        for uid in LEFTOVERS:
            c = by_path["/api/v1/definitions/" + uid]
            self.assertIn(404, c["expect"]["status"])
            self.assertIn(409, c["expect"]["status"])
        sweeps = [c["do"]["sweep"] for c in self.process["cleanup"] if "sweep" in c["do"]]  # T-2898
        self.assertEqual(sweeps, [{"prefix": "uat-tmp-designer-", "exclude_contains": "${run_id}"},
                                  {"draft_versions_of": "platform.register_tenant", "exclude_contains": "${run_id}"}])  # T-2917
        # every definition this run creates is a throwaway name
        for name in re.findall(r'"name": "([^"]+)"', self.text):
            self.assertTrue(name.startswith("uat-tmp-designer-"), name)

    def test_catalog_row(self):
        rows = json.loads((ROOT / "docs" / "bp" / "platform.json").read_text())
        row = next(r for r in rows if r["id"] == "BP-PLATFORM-25")
        self.assertEqual(row["scenario"], "test/uat/processes/BP-PLATFORM-25-designer.json")


class DesignerStrings(unittest.TestCase):
    """The same page strings in ru, kk and en (definitionsMessages.ts), the Guide entry among them."""

    @classmethod
    def setUpClass(cls):
        src = MESSAGES.read_text()
        body = src[src.index("export const definitionsMessages"):]
        cls.blocks = {}
        for lang in ("en", "ru", "kk"):
            m = re.search(r"^  %s: \{\n(.*?)^  \},?$" % lang, body, re.S | re.M)
            assert m, lang
            cls.blocks[lang] = dict(re.findall(r"^    (\w+): (.+?),?$", m.group(1), re.M))

    def test_same_keys_in_three_languages(self):
        en = set(self.blocks["en"])
        self.assertGreater(len(en), 40)
        self.assertEqual(en, set(self.blocks["ru"]))
        self.assertEqual(en, set(self.blocks["kk"]))

    def test_guide_entry_texts_exist_and_differ_by_language(self):
        for key in ("guideButton", "guideTitle", "guideClose", "guideUnavailable", "guideNotifyLink"):
            values = {lang: self.blocks[lang][key] for lang in self.blocks}
            for lang, v in values.items():
                self.assertGreater(len(v.strip("'\" ")), 0, (lang, key))
            self.assertNotEqual(values["en"], values["ru"], key)

    def test_import_export_strings_are_translated(self):
        for key in ("exportButton", "importButton", "newDefinition"):
            self.assertNotEqual(self.blocks["en"][key], self.blocks["ru"][key], key)

    def test_the_three_guide_documents_exist(self):
        for name in ("designer-guide.md", "designer-guide.ru.md", "designer-guide.kk.md"):
            self.assertGreater((ROOT / "docs" / name).stat().st_size, 1000, name)


if __name__ == "__main__":
    unittest.main()
