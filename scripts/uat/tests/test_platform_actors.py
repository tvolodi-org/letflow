"""Tests of the actor of another tenant (T-2577): the platform administrator lives on the platform tenant, has
its own token, its own address and its own tenant in the preflight, in the residue check and in the
retired-tenant guard. Two fake servers on 127.0.0.1, no network beyond them, no model.

Run: python3 -B -m unittest -v scripts/uat/tests/test_platform_actors.py   (from the repository root)
"""

import contextlib
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
from fakes import SECRET, FakeServerCase, FakeStock, make_handler  # noqa: E402

PLATFORM_TENANT = "bpm-default"  # the platform tenant of QA (the realm of admin-user)
PLATFORM_USER = "admin-user"  # the platform administrator of the .env.uat group UAT_QA_ACTOR_ADMIN_USER_*
TODAY = datetime.now(timezone.utc).strftime("%Y%m%d")


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


class TwoServers(FakeServerCase):
    """The tenant of the run and the platform tenant: two fake servers, two sets of tokens."""

    def setUp(self):
        super().setUp()
        self.platform_state = FakeStock()
        self.platform_state.users = {"platform-admin": PLATFORM_USER}
        self.platform_state.platform_roles = {"platform-admin"}
        self.platform_server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.platform_state))
        self.platform_thread = threading.Thread(target=self.platform_server.serve_forever,
                                                kwargs={"poll_interval": 0.01}, daemon=True)
        self.platform_thread.start()
        self.addCleanup(self.stop_platform_server)
        self.platform_base = f"http://127.0.0.1:{self.platform_server.server_address[1]}"

    def stop_platform_server(self):
        self.platform_server.shutdown()
        self.platform_server.server_close()

    def actors(self, tenant=PLATFORM_TENANT, base_url=None, user=PLATFORM_USER):
        """The actors of the run: a plain one and the platform administrator of another tenant."""
        spec = {"user": user, "tenant": tenant}
        if base_url:
            spec["base_url"] = base_url
        return {"admin": "adm", "platform-admin": spec}

    def lines(self):
        return [json.loads(x) for x in (self.run_dir / "run.jsonl").read_text().splitlines()]

    def residue_row(self):
        return next(x for x in self.lines() if x["step"] == "tenant residue check")

    def registry_calls(self, state):
        return [c for c in state.log if c[1].split("?")[0] == "/api/v1/tenants"]


class ActorOfAnotherTenant(TwoServers):
    """The runner knows one tenant and one address per run: an actor may live on another one."""

    def test_an_actor_of_another_tenant_reaches_only_that_server(self):
        process = proc("PLAT", [call("s1", "GET", "/api/v1/tenants", actor="platform-admin"),
                                call("s2", "POST", "/api/v1/echo", {"a": 1})])
        code, _ = self.run_process(process, inputs={}, actors=self.actors(base_url=self.platform_base))
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        # the platform step reached the platform server, the company step the tenant of the run
        self.assertIn(("GET", "/api/v1/tenants", "platform-admin", None), self.platform_state.log)
        self.assertEqual(self.registry_calls(self.state), [])
        self.assertEqual(self.platform_state.calls("POST", "/echo"), [])
        self.assertEqual([c[2] for c in self.state.calls("POST", "/echo")], ["admin"])

    def test_the_preflight_lists_both_tenants(self):
        process = proc("PLAT", [call("s1", "GET", "/api/v1/tenants", actor="platform-admin"),
                                call("s2", "POST", "/api/v1/echo", {"a": 1})])
        code, _ = self.run_process(process, inputs={}, actors=self.actors(base_url=self.platform_base))
        self.assertEqual(code, 0)
        steps = [x["step"] for x in self.lines() if x["phase"] == "preflight"]
        for step in ("health", "tenant", "token:admin",
                     f"health:{PLATFORM_TENANT}", f"tenant:{PLATFORM_TENANT}", f"token:{PLATFORM_TENANT}:platform-admin"):
            self.assertIn(step, steps)

    def test_the_token_of_the_platform_actor_never_reaches_a_file(self):
        process = proc("PLAT", [call("s1", "GET", "/api/v1/tenants", actor="platform-admin")])
        code, _ = self.run_process(process, inputs={}, actors=self.actors(base_url=self.platform_base))
        self.assertEqual(code, 0)
        text = "".join((self.run_dir / name).read_text()
                       for name in ("run.jsonl", "summary.md", "context.json", "meta.json"))
        self.assertNotIn(SECRET, text)
        self.assertNotIn("TOKEN_", text)
        self.assertNotIn("Bearer", text)

    def test_a_plain_actor_behaves_as_before(self):
        process = proc("PLAT", [call("s1", "POST", "/api/v1/echo", {"a": 1})])
        code, _ = self.run_process(process, inputs={}, actors={"admin": "adm"})
        self.assertEqual(code, 0)
        self.assertEqual([c[2] for c in self.state.calls("POST", "/echo")], ["admin"])
        self.assertEqual(self.platform_state.log, [])
        steps = [x["step"] for x in self.lines() if x["phase"] == "preflight"]
        self.assertIn("token:admin", steps)
        self.assertNotIn(f"tenant:{PLATFORM_TENANT}", steps)

    def test_the_process_tenant_stays_the_main_tenant(self):
        process = proc("PLAT", [call("s1", "POST", "/api/v1/echo", {"t": "${tenant}"})])
        code, _ = self.run_process(process, inputs={}, actors=self.actors(base_url=self.platform_base))
        self.assertEqual(code, 0)
        self.assertEqual(self.state.calls("POST", "/echo")[0][3]["t"], "qoimeks-qa2")

    def test_a_bad_actor_object_is_a_usage_error(self):
        for bad in ({"user": "", "tenant": "x"}, {"tenant": "x"}, {"user": "u", "base_url": "ftp://x"},
                    {"user": "u", "tenant": 7}, 7):
            with self.assertRaises(runner.ConfigError, msg=str(bad)):
                runner.normalize_actors({"platform-admin": bad})
        self.assertEqual(runner.normalize_actors({"admin": "adm"}),
                         {"admin": {"user": "adm", "tenant": None, "base_url": None}})


class RetiredGuard(TwoServers):
    """A retired tenant named by an actor stops the run before any request (exit 2)."""

    def write_process(self, doc):
        path = Path(self.tmp.name) / (doc["id"] + ".json")
        path.write_text(json.dumps(doc), encoding="utf-8")
        return str(path)

    def main(self, *extra):
        args = ["run", self.write_process(proc("PLAT", [call("s1", "GET", "/api/v1/tenants", actor="platform-admin")])), "--tenant", "qoimeks-qa2",
                "--base-url", self.base, "--actors", "admin=adm", "--run-dir", str(self.run_dir),
                "--poll-interval", "0.01", *extra]
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = runner.main(args)
        return code, out.getvalue(), err.getvalue()

    def test_a_retired_tenant_on_an_actor_is_refused_before_any_request(self):
        given = json.dumps({"admin": "adm",
                            "platform-admin": {"user": PLATFORM_USER, "tenant": "qoimeks-qa",
                                               "base_url": self.platform_base}})
        code, out, err = self.main("--actors", given)
        self.assertEqual(code, 2, out + err)
        self.assertIn("retired", err)
        self.assertEqual(self.state.log, [])
        self.assertEqual(self.platform_state.log, [])

    def test_a_retired_user_on_an_actor_is_refused_before_any_request(self):
        given = json.dumps({"admin": "adm",
                            "platform-admin": {"user": "qoimeks-qa-admin", "tenant": PLATFORM_TENANT}})
        code, out, err = self.main("--actors", given)
        self.assertEqual(code, 2, out + err)
        self.assertIn("retired", err)
        self.assertEqual(self.state.log, [])

    def test_a_retired_tenant_in_an_actor_object_of_a_process_file_is_refused(self):
        doc = proc("PLAT", [call("s1", "GET", "/api/v1/tenants", actor="platform-admin")])
        doc["dry_run"] = {"tenant": "qoimeks-qa2", "actors": {"platform-admin": {"user": PLATFORM_USER, "tenant": "qoimeks-client1-qa"}},
                          "inputs": {}}
        path = self.write_process(doc)
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = runner.main(["dry-run", "--files", path, "--repo", str(Path(runner.__file__).resolve().parents[2])])
        self.assertEqual(code, 2, out.getvalue())
        self.assertIn("retired", out.getvalue())
        self.assertEqual(self.state.log, [])


class PlatformResidue(TwoServers):
    """The throwaway platform tenants (PM 22:3x/22:4x): an active one left behind is residue."""

    def create(self, slug, actor="platform-admin"):
        return call("s1", "POST", "/api/v1/tenants", {"slug": slug}, {"status": 201}, actor=actor)

    def test_an_active_throwaway_tenant_is_residue(self):
        slug = f"uat-tmp-{TODAY}-1"
        process = proc("PLAT", [self.create(slug)])
        code, _ = self.run_process(process, inputs={}, actors=self.actors(base_url=self.platform_base), allow_create=True)
        self.assertEqual(code, 1)
        row = self.residue_row()
        self.assertEqual(row["verdict"], "fail")
        self.assertIn(f"leftover platform tenant {slug}", row["error"])

    def test_the_fixture_tenant_alone_is_not_residue(self):
        self.platform_state.tenants.append({"slug": "uat-tmp-fixture", "status": "active"})
        process = proc("PLAT", [call("s1", "GET", "/api/v1/tenants", actor="platform-admin")])
        code, _ = self.run_process(process, inputs={}, actors=self.actors(base_url=self.platform_base))
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        self.assertEqual(self.residue_row()["verdict"], "pass")

    def test_a_deactivated_throwaway_tenant_is_final(self):
        slug = f"uat-tmp-{TODAY}-2"
        process = proc("PLAT", [self.create(slug),
                                call("s2", "POST", f"/api/v1/tenants/{slug}/deactivate", {}, {"status": 200},
                                     actor="platform-admin")])
        code, _ = self.run_process(process, inputs={}, actors=self.actors(base_url=self.platform_base), allow_create=True)
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        self.assertEqual(self.residue_row()["verdict"], "pass")

    def test_a_throwaway_tenant_that_existed_before_the_run_is_not_residue(self):
        self.platform_state.tenants.append({"slug": f"uat-tmp-{TODAY}-3", "status": "active"})
        process = proc("PLAT", [call("s1", "GET", "/api/v1/tenants", actor="platform-admin")])
        code, _ = self.run_process(process, inputs={}, actors=self.actors(base_url=self.platform_base))
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        self.assertEqual(self.residue_row()["verdict"], "pass")

    def test_an_actor_object_that_may_not_read_the_registry_is_not_a_platform_tenant(self):
        # a company actor of another tenant: the registry answers 403, and that is not a failure
        self.platform_state.platform_roles = set()
        process = proc("PLAT", [call("s1", "GET", "/api/v1/tenants", actor="platform-admin", expect={"status": 403})])
        code, _ = self.run_process(process, inputs={}, actors=self.actors(base_url=self.platform_base))
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        self.assertEqual(self.residue_row()["verdict"], "pass")
        self.assertFalse((self.run_dir / "platform_before.json").exists())


class AllowCreate(TwoServers):
    """A tenant is created only when the caller says so (--allow-create), and only once a day."""

    def create(self, slug):
        return call("s1", "POST", "/api/v1/tenants", {"slug": slug}, {"status": 201}, actor="platform-admin")

    def test_a_tenant_is_not_created_without_the_flag(self):
        process = proc("PLAT", [self.create(f"uat-tmp-{TODAY}-4")])
        code, _ = self.run_process(process, inputs={}, actors=self.actors(base_url=self.platform_base))
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        row = next(x for x in self.lines() if x["step"] == "s1")
        self.assertEqual(row["verdict"], "skipped")
        self.assertIn("--allow-create", row["error"])
        self.assertEqual(self.platform_state.calls("POST", "/tenants"), [])

    def test_a_tenant_is_created_with_the_flag(self):
        slug = f"uat-tmp-{TODAY}-5"
        process = proc("PLAT", [self.create(slug)])
        code, _ = self.run_process(process, inputs={}, actors=self.actors(base_url=self.platform_base), allow_create=True)
        self.assertEqual(code, 1)  # the tenant it left behind is residue
        self.assertEqual(len(self.platform_state.calls("POST", "/tenants")), 1)
        row = next(x for x in self.lines() if x["step"] == "s1")
        self.assertEqual(row["verdict"], "pass")

    def test_the_second_create_of_the_day_is_skipped(self):
        self.platform_state.tenants.append({"slug": f"uat-tmp-{TODAY}", "status": "active"})
        process = proc("PLAT", [self.create(f"uat-tmp-{TODAY}-6")])
        code, _ = self.run_process(process, inputs={}, actors=self.actors(base_url=self.platform_base), allow_create=True)
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        row = next(x for x in self.lines() if x["step"] == "s1")
        self.assertEqual(row["verdict"], "skipped")
        self.assertIn("already created today", row["error"])
        self.assertEqual(self.platform_state.calls("POST", "/tenants"), [])

    def test_a_refusal_step_runs_without_the_flag(self):
        process = proc("PLAT", [call("s1", "POST", "/api/v1/tenants", {}, {"status": 403}, actor="platform-admin")])
        self.platform_state.platform_roles = set()
        code, _ = self.run_process(process, inputs={}, actors=self.actors(base_url=self.platform_base))
        row = next(x for x in self.lines() if x["step"] == "s1")
        self.assertEqual(row["verdict"], "pass", row)
        self.assertEqual(len(self.platform_state.calls("POST", "/tenants")), 1)

    def test_a_refusal_step_that_creates_fails_with_the_slug(self):
        slug = f"uat-tmp-{TODAY}-7"
        process = proc("PLAT", [call("s1", "POST", "/api/v1/tenants", {"slug": slug}, {"status": 403}, actor="platform-admin")])
        code, _ = self.run_process(process, inputs={}, actors=self.actors(base_url=self.platform_base))
        row = next(x for x in self.lines() if x["step"] == "s1")
        self.assertEqual(row["verdict"], "fail")
        self.assertIn(slug, row["error"])
        self.assertNotEqual(code, 0)


if __name__ == "__main__":
    unittest.main()
