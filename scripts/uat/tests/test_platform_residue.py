"""Tests of the platform residue check (G18): a platform run leaves no active throwaway tenant, the definition
is back on its previous version and no instance is left open. Two fake servers, no network beyond them.

Run: python3 -B -m unittest -v scripts/uat/tests/test_platform_residue.py   (from the repository root)
"""

import io
import json
import sys
import threading
import unittest
from datetime import datetime, timezone
from http.server import ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import runner  # noqa: E402
from fakes import FakeServerCase, FakeStock, make_handler  # noqa: E402

PLATFORM_TENANT = "bpm-default"  # the platform tenant of QA (the realm of admin-user)
PLATFORM_USER = "admin-user"  # the platform administrator of the .env.uat group UAT_QA_ACTOR_ADMIN_USER_*
TODAY = datetime.now(timezone.utc).strftime("%Y%m%d")
DEFINITION = "platform.register_tenant"
DEFINITION_ID = "d1"


def call(sid, method, path, body=None, expect=None, actor="platform-admin", save=None):
    do = {"api": method, "path": path}
    if body is not None:
        do["body"] = body
    step = {"id": sid, "actor": actor, "do": do, "expect": expect if expect is not None else {"status": 200}}
    if save:
        step["save"] = save
    return step


def proc(steps, residue=None):
    doc = {"id": "PLAT", "steps": steps}
    if residue is not None:
        doc["platform_residue"] = residue
    return doc


def activate(sid="s1"):
    return call(sid, "POST", f"/api/v1/definitions/{DEFINITION_ID}/activate", {}, {"status": 200})


def rollback(sid="s2"):
    return call(sid, "POST", f"/api/v1/definitions/{DEFINITION}/rollback", {}, {"status": 200})


def start(sid="s3"):
    return call(sid, "POST", "/api/v1/instances", {"definition_name": DEFINITION}, {"status": 201},
                save={"instance_id": "$.instance_id"})


def cancel(sid="s4"):
    return call(sid, "POST", "/api/v1/instances/${instance_id}/cancel", {}, {"status": 200})


class PlatformRun(FakeServerCase):
    """The run lives on a company tenant; the platform administrator is an actor of another tenant."""

    def setUp(self):
        super().setUp()
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

    def stop_platform_server(self):
        self.platform_server.shutdown()
        self.platform_server.server_close()

    def actors(self):
        return {"admin": "adm", "platform-admin": {"user": PLATFORM_USER, "tenant": PLATFORM_TENANT,
                                                   "base_url": self.platform_base}}

    def run_it(self, doc):
        out = io.StringIO()
        r = runner.Runner(doc, base_url=self.base, tenant="qoimeks-qa2", actors=self.actors(),
                          run_dir=self.run_dir, inputs={}, poll_interval=0.01, out=out, allow_create=True)
        code = r.run()
        return code, r

    def residue_row(self):
        return next(x for x in self.lines() if x["step"] == "tenant residue check")


class TheDefinition(PlatformRun):
    """The definition is back on its previous version."""

    def test_a_definition_on_its_previous_version_passes(self):
        doc = proc([activate(), rollback()], {"definitions": [DEFINITION]})
        code, _ = self.run_it(doc)
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        self.assertEqual(self.residue_row()["verdict"], "pass")

    def test_a_definition_left_on_another_version_is_residue(self):
        doc = proc([activate()], {"definitions": [DEFINITION]})
        code, _ = self.run_it(doc)
        self.assertEqual(code, 1)
        row = self.residue_row()
        self.assertEqual(row["verdict"], "fail")
        self.assertIn(f"definition {DEFINITION} is on the version {DEFINITION_ID}-v2", row["error"])
        self.assertIn(f"the run left it on {DEFINITION_ID}", row["error"])

    def test_without_the_block_the_definition_is_not_watched(self):
        doc = proc([activate()])
        code, _ = self.run_it(doc)
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        self.assertEqual(self.residue_row()["verdict"], "pass")

    def test_a_definition_that_nobody_may_read_fails_the_baseline(self):
        self.platform_state.definitions_forbidden = True
        doc = proc([activate()], {"definitions": [DEFINITION]})
        code, _ = self.run_it(doc)
        self.assertEqual(code, 1)
        row = self.residue_row()
        self.assertEqual(row["verdict"], "fail")
        self.assertIn("baseline unavailable", row["error"])

    def test_the_baseline_of_the_definition_is_written_in_the_run_dir(self):
        doc = proc([activate(), rollback()], {"definitions": [DEFINITION]})
        code, _ = self.run_it(doc)
        self.assertEqual(code, 0)
        before = json.loads((self.run_dir / "platform_before.json").read_text())
        self.assertEqual(before[PLATFORM_TENANT]["definitions"]["active"][DEFINITION], [DEFINITION_ID])

    def test_a_platform_tenant_that_nobody_may_read_fails_the_baseline(self):
        self.platform_state.platform_roles = set()
        doc = proc([activate()], {"definitions": [DEFINITION]})
        code, _ = self.run_it(doc)
        self.assertEqual(code, 1)
        row = self.residue_row()
        self.assertEqual(row["verdict"], "fail")
        self.assertIn("baseline unavailable", row["error"])
        self.assertIn("the tenant registry is not readable", row["error"])

    def test_a_run_without_a_platform_administrator_fails_the_baseline(self):
        doc = proc([activate()], {"definitions": [DEFINITION]})
        out = io.StringIO()
        r = runner.Runner(doc, base_url=self.base, tenant="qoimeks-qa2", actors={"admin": "adm"},
                          run_dir=self.run_dir, inputs={}, poll_interval=0.01, out=out, allow_create=True)
        code = r.run()
        self.assertEqual(code, 1)
        row = self.residue_row()
        self.assertEqual(row["verdict"], "fail")
        self.assertIn("no actor of this run reads the platform tenant", row["error"])


class TheInstances(PlatformRun):
    """No instance of the run is left open."""

    def test_an_instance_left_open_is_residue(self):
        doc = proc([start()], {"definitions": [DEFINITION]})
        code, _ = self.run_it(doc)
        self.assertEqual(code, 1)
        row = self.residue_row()
        self.assertEqual(row["verdict"], "fail")
        self.assertIn("instance inst-started-1 is still open", row["error"])

    def test_a_finished_instance_is_not_residue(self):
        doc = proc([start(), cancel()], {"definitions": [DEFINITION]})
        code, _ = self.run_it(doc)
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        self.assertEqual(self.residue_row()["verdict"], "pass")

    def test_an_instance_the_block_names_is_checked_too(self):
        self.platform_state.instances["inst-old"] = {"status": "ACTIVE", "variables": {}}
        doc = proc([start(), cancel()], {"instances": ["inst-old"]})
        code, _ = self.run_it(doc)
        self.assertEqual(code, 1)
        self.assertIn("instance inst-old is still open", self.residue_row()["error"])

    def test_an_instance_that_does_not_exist_is_not_left_open(self):
        doc = proc([start(), cancel()], {"instances": ["inst-nothing"]})
        code, _ = self.run_it(doc)
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        self.assertEqual(self.residue_row()["verdict"], "pass")

    def test_without_the_block_an_open_instance_is_not_reported(self):
        doc = proc([start()])
        code, _ = self.run_it(doc)
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        self.assertEqual(self.residue_row()["verdict"], "pass")


class TheThrowawayTenant(PlatformRun):
    """The tenant rule of the platform residue check stays: no active throwaway tenant is left."""

    def test_an_active_throwaway_tenant_is_residue(self):
        slug = f"uat-tmp-{TODAY}-g18"
        doc = proc([call("s1", "POST", "/api/v1/tenants", {"slug": slug}, {"status": 201})],
                   {"definitions": [DEFINITION]})
        code, _ = self.run_it(doc)
        self.assertEqual(code, 1)
        row = self.residue_row()
        self.assertEqual(row["verdict"], "fail")
        self.assertIn(f"leftover platform tenant {slug}", row["error"])

    def test_a_deactivated_throwaway_tenant_is_final(self):
        slug = f"uat-tmp-{TODAY}-g18b"
        doc = proc([call("s1", "POST", "/api/v1/tenants", {"slug": slug}, {"status": 201}),
                    call("s2", "POST", f"/api/v1/tenants/{slug}/deactivate", {}, {"status": 200})],
                   {"definitions": [DEFINITION]})
        code, _ = self.run_it(doc)
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        self.assertEqual(self.residue_row()["verdict"], "pass")


class TheBlockMustBeReadable(PlatformRun):
    """A bad platform_residue block is a usage error (exit 2), never a request."""

    def load(self, block):
        path = Path(self.tmp.name) / "process.json"
        path.write_text(json.dumps({"id": "PLAT", "steps": [activate()], "platform_residue": block}),
                        encoding="utf-8")
        return runner.load_process(str(path))

    def test_an_unknown_key_is_refused(self):
        with self.assertRaises(runner.ConfigError):
            self.load({"tenants": ["uat-tmp-x"]})

    def test_a_list_that_is_not_a_list_is_refused(self):
        with self.assertRaises(runner.ConfigError):
            self.load({"definitions": "platform.register_tenant"})

    def test_an_empty_name_is_refused(self):
        with self.assertRaises(runner.ConfigError):
            self.load({"definitions": ["  "]})

    def test_a_good_block_is_accepted(self):
        doc = self.load({"definitions": [DEFINITION], "instances": ["${instance_id}"]})
        self.assertEqual(doc["platform_residue"]["definitions"], [DEFINITION])


if __name__ == "__main__":
    unittest.main()
