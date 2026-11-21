"""Tests of scripts/uat/check_processes.py, the static check of process and chain files: a small fake product
tree (router files and a roster) in a temp dir, plus the real BP-01 file against the real routers.

Run: python3 -B -m unittest -v scripts/uat/tests/test_check_processes.py   (from the repository root)
"""

import contextlib
import copy
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import check_processes  # noqa: E402

REPO = HERE.parent.parent.parent
STOCK_ROUTER = '''
  authz_get "/balances", :StockRead do
  end
  authz_post "/documents", :StockPost,
  authz_post "/documents/:id/issue", :StockPost,
  authz_get "/documents/:id", :StockRead do
'''
TASKS_ROUTER = '''
  authz_get "/inbox", :TasksRead do
  authz_post "/:id/claim", :TasksClaim do
  authz_post "/:id/complete", :TasksComplete do
'''
INSTANCES_ROUTER = '''
  authz_get "/:id", :InstancesRead do
'''
IDENTITY_ROUTER = '''
  authz_post "/shared-stock-access", :TokensManage do
  authz_delete "/shared-stock-access", :TokensManage do
'''
SHARED_ROUTER = '''
  get "/movements" do
  post "/movements" do
'''
ROSTER = '''
actors:
  actor-demo-admin:
    tenant: demo
  actor-demo-storekeeper:
    tenant: demo
  actor-demo-admin2:
    tenant: demo
'''


def step(sid, method, path, actor="admin", expect=True, **extra):
    s = {"id": sid, "actor": actor, "do": {"api": method, "path": path}}
    if expect:
        s["expect"] = {"status": 200}
    s.update(extra)
    return s


GOOD = {
    "id": "BP-T", "title": "t", "inputs": ["item"],
    "steps": [
        step("s1", "GET", "/api/v1/modules/stock/balances?sku=${item}", save={"before": {"pick": "$.rows[0].quantity", "default": "0"}}),
        step("s2", "POST", "/api/v1/modules/stock/documents", actor="storekeeper", save={"doc_id": "$.id"}),
        step("s3", "POST", "/api/v1/modules/stock/documents/${doc_id}/issue", actor="storekeeper"),
        {"id": "s4", "actor": "admin", "do": {"wait_task": {"for_document": "${doc_id}", "step": "post"}, "claim": True,
                                              "complete": {"body": {}}}, "expect": {"status": 200}},
        step("s5", "GET", "/api/v1/modules/stock/documents/${doc_id}", save={"entry": "$.entry_id"}),
    ],
    "outputs": {"receipt": "${doc_id}"},
    "cleanup": [step("c1", "POST", "/api/v1/tasks/${doc_id}/claim", requires=["doc_id"])],
}


class CheckCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for rel, text in (("lib/letflow/modules/stock/router.ex", STOCK_ROUTER), ("lib/letflow/routers/tasks.ex", TASKS_ROUTER),
                          ("lib/letflow/routers/instances.ex", INSTANCES_ROUTER), ("lib/letflow/routers/identity.ex", IDENTITY_ROUTER),
                          ("lib/letflow/routers/shared_stock_access.ex", SHARED_ROUTER), ("test/fixtures/uat/actors.yaml", ROSTER)):
            path = self.root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        (self.root / "test/uat/processes").mkdir(parents=True)
        (self.root / "test/uat/chains").mkdir(parents=True)

    def write(self, doc, rel="test/uat/processes/BP-T.json", raw=None):
        path = self.root / rel
        path.write_text(raw if raw is not None else json.dumps(doc))
        return path

    def check(self, doc, strict=False, **kw):
        return check_processes.check_files([self.write(doc, **kw)], root=self.root, strict=strict)

    def mutated(self, fn):
        doc = copy.deepcopy(GOOD)
        fn(doc)
        return doc


class Process(CheckCase):
    def test_a_good_process_has_no_problem(self):
        self.assertEqual(self.check(GOOD), [])

    def test_an_undefined_variable_is_caught_in_a_path_a_body_and_an_expect(self):
        for where in ("path", "body", "expect"):
            def change(doc):
                s = doc["steps"][2]
                if where == "path":
                    s["do"]["path"] = "/api/v1/modules/stock/documents/${nope}/issue"
                elif where == "body":
                    s["do"]["body"] = {"x": "${nope}"}
                else:
                    s["expect"] = {"json": {"$.x": "${nope + 1}"}}

            problems = self.check(self.mutated(change))
            self.assertTrue(any("${nope}" in p and "step s3" in p for p in problems), (where, problems))

    def test_a_variable_saved_by_a_later_step_is_undefined_in_an_earlier_one(self):
        doc = self.mutated(lambda d: d["steps"].insert(0, step("s0", "GET", "/api/v1/modules/stock/documents/${doc_id}")))
        problems = self.check(doc)
        self.assertEqual(len(problems), 1)
        self.assertIn("${doc_id}", problems[0])
        self.assertIn("step s0", problems[0])

    def test_inputs_defaults_and_builtins_are_defined(self):
        def change(doc):
            doc["defaults"] = {"quantity": "5"}
            doc["steps"][1]["do"]["body"] = {"q": "${quantity}", "t": "${tenant}", "r": "${run_id}", "n": "${now_utc}", "i": "${item}"}

        self.assertEqual(self.check(self.mutated(change)), [])

    def test_uuid_builtins_are_defined_and_fresh_per_run(self):
        import uuid as uuid_module

        runner = check_processes.runner

        def change(doc):
            doc["steps"][1]["do"]["body"] = {"id": "${uuid1}", "again": "${uuid12}"}

        self.assertEqual(self.check(self.mutated(change)), [])
        self.assertTrue(set(runner.UUID_NAMES) <= set(runner.BUILTIN_NAMES))
        run = runner.Runner([{"id": "X", "steps": [], "cleanup": []}], base_url="http://x", tenant="t", actors={},
                            run_dir=self.root / "run")
        other = runner.Runner([{"id": "X", "steps": [], "cleanup": []}], base_url="http://x", tenant="t", actors={},
                              run_dir=self.root / "other-run")
        values = [run.ctx[name] for name in runner.UUID_NAMES]
        for value in values:
            self.assertEqual(str(uuid_module.UUID(value)), value)
        self.assertEqual(len(set(values)), len(runner.UUID_NAMES))
        self.assertNotEqual(run.ctx["uuid1"], other.ctx["uuid1"])

    def test_an_expression_with_a_defined_name_is_fine(self):
        doc = self.mutated(lambda d: d["steps"][4].update(expect={"json": {"$.rows[0].quantity": {"equals": "${before + 5}"}}}))
        self.assertEqual(self.check(doc), [])

    def test_an_output_of_an_unsaved_name_is_caught(self):
        problems = self.check(self.mutated(lambda d: d.update(outputs={"x": "${never_saved}"})))
        self.assertTrue(any("output x" in p and "never_saved" in p for p in problems), problems)

    def test_an_unknown_actor_is_caught_in_a_step_a_cleanup_and_a_parallel_call(self):
        problems = self.check(self.mutated(lambda d: d["steps"][1].update(actor="ghost")))
        self.assertEqual(len(problems), 1)
        self.assertIn("actor 'ghost'", problems[0])
        problems = self.check(self.mutated(lambda d: d["cleanup"][0].update(actor="phantom")))
        self.assertTrue(any("phantom" in p for p in problems))
        parallel = {"id": "p1", "actor": "admin", "expect": {}, "do": {"parallel": [
            {"api": "GET", "path": "/api/v1/modules/stock/balances", "actor": "ghost2"},
            {"api": "GET", "path": "/api/v1/modules/stock/balances"}]}}
        problems = self.check(self.mutated(lambda d: d["steps"].append(parallel)))
        self.assertTrue(any("ghost2" in p for p in problems))

    def test_roster_roles_are_the_last_part_of_the_entry_names(self):
        for role in ("admin", "storekeeper", "admin2"):
            doc = self.mutated(lambda d: d["steps"][1].update(actor=role))
            self.assertEqual(self.check(doc), [], role)

    def test_a_path_that_does_not_start_with_api_is_caught(self):
        problems = self.check(self.mutated(lambda d: d["steps"][0]["do"].update(path="/v1/modules/stock/balances")))
        self.assertTrue(any("must start with /api/" in p for p in problems), problems)

    def test_a_path_with_no_route_is_caught(self):
        for path in ("/api/v1/modules/stock/not-a-route", "/api/v1/modules/stock/documents/${doc_id}/explode", "/api/v1/zzz/yyy"):
            problems = self.check(self.mutated(lambda d, p=path: d["steps"][2]["do"].update(path=p)))
            self.assertTrue(any("matches no route" in p_ for p_ in problems), (path, problems))

    def test_the_method_must_exist_for_the_path(self):
        problems = self.check(self.mutated(lambda d: d["steps"][0]["do"].update(api="DELETE")))
        self.assertTrue(any("DELETE" in p and "matches no route" in p for p in problems), problems)

    def test_a_route_of_a_router_under_its_mount_name_and_a_wildcard_only_route(self):
        doc = self.mutated(lambda d: d["steps"].append(step("s6", "GET", "/api/v1/instances/${doc_id}")))
        self.assertEqual(self.check(doc), [])
        doc = self.mutated(lambda d: d["steps"].append(step("s6", "GET", "/api/v1/whatever/${doc_id}")))
        self.assertTrue(any("matches no route" in p for p in self.check(doc)))  # `/:id` counts only behind /instances

    def test_a_route_of_another_module_router_is_checked_under_its_mount(self):
        router = self.root / "lib/letflow/modules/locations/router.ex"
        router.parent.mkdir(parents=True, exist_ok=True)
        router.write_text('  authz_post "/nodes", :LocationsWrite do\n  end\n  authz_post "/nodes/:id/move", :LocationsWrite do\n  end\n')
        good = self.mutated(lambda d: d["steps"].append(step("s6", "POST", "/api/v1/modules/locations/nodes/${doc_id}/move")))
        self.assertEqual(self.check(good), [])
        bad = self.mutated(lambda d: d["steps"].append(step("s6", "POST", "/api/v1/modules/locations/nodes/${doc_id}/explode")))
        self.assertTrue(any("matches no route" in p for p in self.check(bad)))

    def test_a_route_of_another_module_router_is_found_under_modules_name(self):
        path = self.root / "lib/letflow/modules/exam/router.ex"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('  authz_get "/sessions/:id", :ExamSessionRead do\n')
        doc = self.mutated(lambda d: d["steps"].append(step("s6", "GET", "/api/v1/modules/exam/sessions/${doc_id}")))
        self.assertEqual(self.check(doc), [])
        doc = self.mutated(lambda d: d["steps"].append(step("s6", "GET", "/api/v1/modules/exam/nothing/${doc_id}")))
        self.assertTrue(any("matches no route" in p for p in self.check(doc)))

    def test_a_read_in_save_is_checked_like_a_step(self):
        doc = self.mutated(lambda d: d["steps"][0]["save"].update(extra={"api": "GET", "path": "/api/v1/modules/stock/nope"}))
        self.assertTrue(any("matches no route" in p for p in self.check(doc)))

    def test_a_step_without_expect_is_caught_unless_it_has_expect_refused(self):
        problems = self.check(self.mutated(lambda d: d["steps"][2].pop("expect")))
        self.assertTrue(any("step s3" in p and "no expect" in p for p in problems), problems)
        doc = self.mutated(lambda d: (d["steps"][2].pop("expect"), d["steps"][2].update(expect_refused="x")))
        self.assertEqual(self.check(doc), [])
        self.assertTrue(any("no expect" in p for p in self.check(self.mutated(lambda d: d["cleanup"][0].pop("expect")))))

    def test_shared_access_steps_are_checked_against_the_old_address_router(self):
        create = step("s6", "POST", "/api/v1/identity/shared-stock-access", save={"shared_access": {"secret": "$.value"}, "made": "y"})
        read = {"id": "s7", "http_as": "shared_access", "do": {"api": "GET", "path": "/movements"}, "expect": {"status": 200}}
        self.assertEqual(self.check(self.mutated(lambda d: d["steps"].extend([create, read]))), [])
        bad = dict(read, do={"api": "GET", "path": "/nothing-here"})
        problems = self.check(self.mutated(lambda d: d["steps"].extend([create, bad])))
        self.assertTrue(any("nothing-here" in p and "matches no route" in p for p in problems), problems)
        # the secret name is not a variable: ${shared_access} would be undefined
        leak = step("s8", "GET", "/api/v1/modules/stock/balances?x=${shared_access}")
        problems = self.check(self.mutated(lambda d: d["steps"].extend([create, leak])))
        self.assertTrue(any("${shared_access}" in p for p in problems), problems)

    def test_duplicate_step_ids_and_bad_json_and_a_missing_id(self):
        self.assertTrue(any("duplicate" in p for p in self.check(self.mutated(lambda d: d["steps"][1].update(id="s1")))))
        problems = check_processes.check_files([self.write(None, raw="{ not json")], root=self.root)
        self.assertTrue(any("not valid JSON" in p for p in problems))
        self.assertTrue(any("needs an id" in p for p in self.check({"steps": []})))
        self.assertTrue(any("steps" in p for p in self.check({"id": "x", "steps": []})))

    def test_without_routers_or_roster_only_the_other_rules_apply(self):
        bare = Path(self.tmp.name) / "bare"
        (bare / "test/uat/processes").mkdir(parents=True)
        path = bare / "test/uat/processes/BP-T.json"
        path.write_text(json.dumps(self.mutated(lambda d: d["steps"][1].update(actor="ghost"))))
        self.assertEqual(check_processes.check_files([path], root=bare), [])


class BpEntryAndDryRun(CheckCase):
    def doc(self, **over):
        doc = copy.deepcopy(GOOD)
        doc["bp_entry"] = "BP-T"
        doc["dry_run"] = {"tenant": "demo", "actors": {"admin": "demo-admin", "storekeeper": "demo-store"}, "inputs": {"item": "i-1"}}
        doc.update(over)
        return doc

    def test_strict_wants_bp_entry_and_dry_run(self):
        self.assertEqual(self.check(self.doc(), strict=True), [])
        problems = self.check(GOOD, strict=True)
        self.assertTrue(any("bp_entry is missing" in p for p in problems))
        self.assertTrue(any("dry_run is missing" in p for p in problems))
        self.assertEqual(self.check(GOOD, strict=False), [])  # not required without --strict

    def test_a_dry_run_block_must_be_complete_when_present(self):
        no_actor = self.doc(dry_run={"tenant": "demo", "actors": {"admin": "a"}, "inputs": {"item": "i"}})
        self.assertTrue(any("no user for actor 'storekeeper'" in p for p in self.check(no_actor)))
        no_input = self.doc(dry_run={"tenant": "demo", "actors": {"admin": "a", "storekeeper": "s"}, "inputs": {}})
        self.assertTrue(any("no value for the input 'item'" in p for p in self.check(no_input)))
        no_tenant = self.doc(dry_run={"actors": {}, "inputs": {}})
        self.assertTrue(any("dry_run.tenant" in p for p in self.check(no_tenant)))
        self.assertTrue(any("bp_entry must be a text" in p for p in self.check(self.doc(bp_entry=""))))


class Chains(CheckCase):
    def chain(self, procs, **over):
        for doc in procs:
            (self.root / "test/uat/processes" / f"{doc['id']}-x.json").write_text(json.dumps(doc))
        chain = {"id": "c", "processes": [d["id"] for d in procs], "inputs": {"item": "i"}}
        chain.update(over)
        return self.write(chain, rel="test/uat/chains/c.json")

    def producer(self):
        doc = copy.deepcopy(GOOD)
        doc["id"] = "BP-P"
        return doc

    def consumer(self, uses="receipt"):
        return {"id": "BP-C", "inputs": [uses], "steps": [step("s1", "GET", f"/api/v1/modules/stock/documents/${{{uses}}}")]}

    def test_a_variable_from_an_earlier_process_is_defined(self):
        path = self.chain([self.producer(), self.consumer()])
        self.assertEqual(check_processes.check_files([path], root=self.root), [])

    def test_a_variable_that_only_a_later_process_gives_is_undefined(self):
        path = self.chain([self.consumer(), self.producer()])
        problems = check_processes.check_files([path], root=self.root)
        self.assertTrue(any("'receipt'" in p and "BP-C" in p for p in problems), problems)

    def test_a_chain_input_is_a_variable_for_every_process(self):
        doc = self.consumer("item")
        path = self.chain([doc])
        self.assertEqual(check_processes.check_files([path], root=self.root), [])

    def test_a_process_missing_from_the_chain_folder_is_a_problem(self):
        path = self.chain([self.producer()], processes=["BP-P", "BP-GONE"])
        problems = check_processes.check_files([path], root=self.root)
        self.assertTrue(any("BP-GONE" in p for p in problems), problems)

    def test_problems_inside_a_chain_name_the_chain_and_the_process_file(self):
        bad = self.consumer()
        bad["steps"][0]["actor"] = "ghost"
        path = self.chain([self.producer(), bad])
        problems = check_processes.check_files([path], root=self.root)
        self.assertTrue(any(p.startswith("c.json > BP-C-x.json") and "ghost" in p for p in problems), problems)

    def test_strict_wants_a_dry_run_block_on_the_chain(self):
        path = self.chain([self.producer()])
        self.assertTrue(any("dry_run is missing" in p for p in check_processes.check_files([path], root=self.root, strict=True)))
        path = self.chain([self.producer()], dry_run={"tenant": "demo", "actors": {"admin": "a"}, "inputs": {"item": "i"}})
        self.assertEqual(check_processes.check_files([path], root=self.root, strict=True), [])


class RealFiles(unittest.TestCase):
    def test_bp01_passes_against_the_real_routers_and_roster(self):
        self.assertTrue((REPO / "lib/letflow/modules/stock/router.ex").is_file())
        problems = check_processes.check_files([REPO / "test/uat/processes/BP-01-receive-goods.json"], root=REPO)
        self.assertEqual(problems, [])

    def test_a_bp01_with_a_broken_path_fails_against_the_real_routers(self):
        doc = json.loads((REPO / "test/uat/processes/BP-01-receive-goods.json").read_text())
        step = next(s for s in doc["steps"] if s["id"] == "s2")  # by id: the process file may grow a step
        step["do"]["path"] = "/api/v1/modules/stock/documents/${doc_id}/launch"
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "BP-01.json"
            path.write_text(json.dumps(doc))
            problems = check_processes.check_files([path], root=REPO)
        self.assertEqual(len(problems), 1)
        self.assertIn("launch", problems[0])


class Cli(CheckCase):
    def run_main(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = check_processes.main(list(argv))
        return code, out.getvalue()

    def test_exit_codes_and_default_files(self):
        self.write(GOOD)
        code, out = self.run_main("--root", str(self.root))
        self.assertEqual((code, "0 problem(s)" in out), (0, True), out)
        self.write(self.mutated(lambda d: d["steps"][1].update(actor="ghost")))
        code, out = self.run_main("--root", str(self.root))
        self.assertEqual(code, 1)
        self.assertIn("ghost", out)

    def test_strict_flag(self):
        path = self.write(GOOD)
        self.assertEqual(self.run_main("--root", str(self.root), str(path))[0], 0)
        self.assertEqual(self.run_main("--root", str(self.root), "--strict", str(path))[0], 1)


if __name__ == "__main__":
    unittest.main()
