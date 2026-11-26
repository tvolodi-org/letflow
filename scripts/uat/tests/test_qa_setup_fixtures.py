"""Tests of the fixtures `module_installed` and `tenant_onboarded` (the local modes of the QA tenant setup, D-174):
a fake server on 127.0.0.1, no model.

Run: python3 -B -m unittest -v scripts/uat/tests/test_qa_setup_fixtures.py   (from the repository root)
"""

import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import runner  # noqa: E402
from test_fixtures import FixtureCase, process  # noqa: E402


def proc(*entries):
    doc = process("P", fixtures=list(entries))
    doc["inputs"] = []
    doc["steps"][0]["do"]["body"] = {}
    return doc


def module(name, **extra):
    return dict({"fixture": "module_installed", "module": name}, **extra)


class ModuleInstalledTests(FixtureCase):
    def posts(self):
        return [c[3]["module_id"] for c in self.state.log if c[0] == "POST" and c[1] == "/api/v1/tenant/modules"]

    def test_absent_module_is_installed_once_and_version_is_logged(self):
        self.state.modules = {"org": "0.3.0"}
        code, _ = self.play(proc(module("assets")))
        self.assertEqual(code, 0)
        self.assertEqual(self.posts(), ["assets"])
        line = next(x for x in self.lines() if x.get("step") == "f1" and x["process"].startswith("fixture:"))
        self.assertEqual(line["module_installed"], {"module": "assets", "already": False, "version": [0, 31, 0]})
        self.assertEqual(json.loads((self.run_dir / "context.json").read_text())["module_assets_version"], [0, 31, 0])
        self.assertNotIn("TOKEN", (self.run_dir / "run.jsonl").read_text())

    def test_present_module_makes_no_post(self):
        self.state.modules = {"org": "0.3.0", "assets": "0.31.0"}
        self.assertEqual(self.play(proc(module("assets")))[0], 0)
        self.assertEqual(self.posts(), [])

    def test_409_is_ok(self):
        # the first read says absent, the install answers 409 (installed meanwhile): the read after it decides
        self.state.modules = {"org": "0.3.0"}
        self.state.module_hidden_reads = 1
        self.assertEqual(self.play(proc(module("org")))[0], 0)
        self.assertEqual(self.posts(), ["org"])

    def test_unknown_module_fails_with_the_products_answer_and_no_retry(self):
        code, _ = self.play(proc(module("nosuch")))
        self.assertNotEqual(code, 0)
        self.assertEqual(self.posts(), ["nosuch"])
        err = next(x for x in self.lines() if x.get("verdict") == "error")["error"]
        self.assertIn("422", err)
        self.assertIn("unknown_module", err)

    def test_unmet_dependency_fails_with_the_products_answer(self):
        code, _ = self.play(proc(module("assets")))
        self.assertNotEqual(code, 0)
        self.assertIn("dependency_unmet", next(x for x in self.lines() if x.get("verdict") == "error")["error"])

    def test_two_modules_install_in_the_given_order(self):
        self.assertEqual(self.play(proc(module(["org", "assets"])))[0], 0)
        self.assertEqual(self.posts(), ["org", "assets"])

    def test_two_fixtures_in_order(self):
        self.assertEqual(self.play(proc(module("org"), module("assets")))[0], 0)
        self.assertEqual(self.posts(), ["org", "assets"])

    def test_invalid_names_are_refused_before_any_request(self):
        for bad in ("Assets", "../x", "", "1a", "a" * 65, "a b", ["org", "org"], []):
            with self.subTest(bad=bad):
                self.state.log.clear()
                with self.assertRaises(runner.ConfigError):
                    self.play(proc(module(bad)))
                self.assertEqual(self.state.log, [])

    def test_nothing_is_uninstalled_by_cleanup(self):
        self.assertEqual(self.play(proc(module("org")))[0], 0)
        self.assertEqual([c for c in self.state.log if c[0] != "GET" and c[1] != "/api/v1/tenant/modules" and "echo" not in c[1]], [])
        self.assertEqual(self.state.modules, {"org": "0.3.0"})

    def test_wrong_tenant_is_refused(self):
        code, _ = self.play(proc(module("org", tenant="other-tenant")))
        self.assertNotEqual(code, 0)
        self.assertEqual(self.posts(), [])


class TenantOnboardedTests(FixtureCase):
    def entry(self, **extra):
        return dict({"fixture": "tenant_onboarded"}, **extra)

    def ready(self):
        self.state.legal_entities = ["QOIMEKS"]
        self.state.app_name = "Qoimeks"
        self.state.modules = {"org": "0.3.0"}

    def writes(self):
        return [c for c in self.state.log if c[0] != "GET" and c[1] not in ("/api/v1/entities/query",) and "echo" not in c[1]]

    def test_ready_tenant_passes_and_creates_nothing(self):
        self.ready()
        entry = self.entry(legal_entity="QOIMEKS", app_name="Qoimeks", modules=["org"],
                           actors={"storekeeper": {"roles": ["STOREKEEPER"], "permissions": ["StockQuickCount"]}})
        self.assertEqual(self.play(proc(entry))[0], 0)
        self.assertEqual(self.writes(), [])

    def test_missing_items_are_named(self):
        entry = self.entry(modules=["assets"], actors={"storekeeper": {"roles": ["STOREKEEPER"], "permissions": ["StockApprove"]}})
        code, _ = self.play(proc(entry))
        self.assertNotEqual(code, 0)
        err = next(x for x in self.lines() if x.get("verdict") == "error")["error"]
        for item in ("legal entity", "app_name", "module assets", "actor storekeeper: permission StockApprove"):
            self.assertIn(item, err)
        self.assertNotIn("actor storekeeper: role", err)
        self.assertEqual(self.writes(), [])

    def test_wrong_app_name_is_named(self):
        self.ready()
        code, _ = self.play(proc(self.entry(app_name="Other")))
        self.assertNotEqual(code, 0)
        self.assertIn("app_name 'Other' (is 'Qoimeks')", next(x for x in self.lines() if x.get("verdict") == "error")["error"])

    def test_bad_spec_is_refused_before_any_request(self):
        for bad in ({"modules": ["Bad"]}, {"unknown": 1}, {"actors": {"a": {"roles": "X"}}}):
            with self.subTest(bad=bad):
                with self.assertRaises(runner.ConfigError):
                    self.play(proc(self.entry(**bad)))
                self.assertEqual(self.state.log, [])


if __name__ == "__main__":
    unittest.main()
