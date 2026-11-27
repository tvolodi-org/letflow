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
        (self.root / "test/uat/fixtures").mkdir()

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

    def test_a_positional_index_into_an_api_list_is_caught_in_expect_and_save(self):
        for where in ("expect", "save"):
            def change(doc):
                if where == "expect":
                    doc["steps"][2]["expect"] = {"status": 200, "json": {"$.items[12].name": "tenant.validate"}}
                else:
                    doc["steps"][2]["save"] = {"first": "$.items[0].id"}

            problems = self.check(self.mutated(change))
            self.assertTrue(any("positional index" in p and "step s3" in p for p in problems), (where, problems))

    def test_a_name_selector_passes_the_positional_rule(self):
        def change(doc):
            doc["steps"][2]["expect"] = {"status": 200, "json": {"$.items[?name=tenant.validate].name": "tenant.validate"}}

        self.assertEqual(self.check(self.mutated(change)), [])

    def test_a_positional_index_with_a_reason_is_exempt_and_an_empty_reason_is_not(self):
        def exempt(doc):
            doc["steps"][2]["expect"] = {"status": 200, "json": {"$.items[0].id": {"exists": True}}}
            doc["steps"][2]["positional_ok"] = "sorted by contract: newest first"

        self.assertEqual(self.check(self.mutated(exempt)), [])

        def empty(doc):
            exempt(doc)
            doc["steps"][2]["positional_ok"] = " "

        self.assertTrue(any("positional index" in p for p in self.check(self.mutated(empty))))

    def test_a_database_row_path_is_not_an_api_list(self):
        def change(doc):
            doc["steps"][2]["expect"] = {"status": 200, "json": {"$.rows[0].n": 1, "$[0]": 1}}

        self.assertEqual(self.check(self.mutated(change)), [])

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

    def _forwarded(self):
        pipeline = self.root / "lib/letflow/plugs/api_pipeline.ex"
        pipeline.parent.mkdir(parents=True, exist_ok=True)
        pipeline.write_text(
            '  forward("/tenant/settings", to: Letflow.Routers.TenantSettings)\n'
            '  forward("/tenant/modules", to: Letflow.Routers.TenantModules)\n'
            '  forward("/tenant/solutions", to: Letflow.Routers.TenantSolutions)\n')
        for name, text in (("tenant_settings", 'authz_get "/", :SettingsRead do\n'),
                           ("tenant_modules", 'authz_post "/", :ModulesManage do\n authz_post "/:module_id/upgrade", :ModulesManage do\n'),
                           ("tenant_solutions", 'authz_post "/", :SolutionsManage do\n')):
            (self.root / f"lib/letflow/routers/{name}.ex").write_text(text)

    def test_routers_forwarded_at_tenant_name_match_their_mount(self):
        self._forwarded()
        for method, path in (("GET", "/api/v1/tenant/settings"), ("POST", "/api/v1/tenant/modules"),
                             ("POST", "/api/v1/tenant/modules/${doc_id}/upgrade"), ("POST", "/api/v1/tenant/solutions")):
            problems = self.check(self.mutated(lambda d, m=method, p=path: d["steps"].append(step("s6", m, p))))
            self.assertEqual(problems, [], (path, problems))

    def test_a_tenant_route_that_does_not_exist_still_fails(self):
        self._forwarded()
        for method, path in (("POST", "/api/v1/tenant/modules/${doc_id}/explode"), ("DELETE", "/api/v1/tenant/modules"),
                             ("POST", "/api/v1/tenant/nothing")):
            problems = self.check(self.mutated(lambda d, m=method, p=path: d["steps"].append(step("s6", m, p))))
            self.assertTrue(any("matches no route" in p for p in problems), (path, problems))

    def test_the_real_forwards_of_api_pipeline_are_all_read(self):
        text = (REPO / "lib/letflow/plugs/api_pipeline.ex").read_text()
        mounts = check_processes.forwarded_mounts(REPO)
        self.assertEqual(sum(len(v) for v in mounts.values()), text.count("\n  forward(\""))
        self.assertIn(["tenant", "modules"], mounts["tenant_modules"])
        self.assertIn(["tenant", "solutions"], mounts["tenant_solutions"])
        self.assertIn(["tenant", "settings"], mounts["tenant_settings"])

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
    def test_a_placeholder_anywhere_in_a_process_is_refused(self):
        doc = self.mutated(lambda d: d.update(defaults={"quantity": "REPLACE-WITH-QUANTITY"}))
        problems = self.check(doc)
        self.assertTrue(any("REPLACE-WITH-QUANTITY" in p and "placeholder" in p for p in problems), problems)


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

    def test_only_an_output_listed_in_pass_is_defined_for_a_later_process(self):
        path = self.chain([self.producer(), self.consumer()], **{"pass": {"BP-P": ["receipt"]}})
        self.assertEqual(check_processes.check_files([path], root=self.root), [])
        path = self.chain([self.producer(), self.consumer()])
        problems = check_processes.check_files([path], root=self.root)
        self.assertTrue(any("'receipt'" in p and "BP-C" in p for p in problems), problems)

    def test_a_pass_list_must_name_an_output_of_its_process(self):
        path = self.chain([self.producer()], **{"pass": {"BP-P": ["not_an_output"]}})
        problems = check_processes.check_files([path], root=self.root)
        self.assertTrue(any("pass" in p and "not_an_output" in p for p in problems), problems)

    def test_the_cleanup_mode_of_a_chain_is_checked(self):
        path = self.chain([self.producer()], cleanup="per_process")
        self.assertEqual(check_processes.check_files([path], root=self.root), [])
        path = self.chain([self.producer()], cleanup="per_prozess")
        problems = check_processes.check_files([path], root=self.root)
        self.assertTrue(any("cleanup must be one of" in p and "per_prozess" in p for p in problems), problems)

    def test_a_placeholder_in_a_chain_or_a_fixture_is_refused(self):
        path = self.chain([self.producer()], inputs={"item": "REPLACE-WITH-ITEM-ID"})
        problems = check_processes.check_files([path], root=self.root)
        self.assertTrue(any("REPLACE-WITH-ITEM-ID" in p for p in problems), problems)
        fixture = copy.deepcopy(GOOD)
        fixture.update(description="fixture", leaves="nothing", provides=["doc_id"])
        fixture["steps"][0]["do"]["path"] += "&other=REPLACE-WITH-OTHER"
        path = self.write(fixture, rel="test/uat/fixtures/fx.json")
        problems = check_processes.check_files([path], root=self.root)
        self.assertTrue(any("REPLACE-WITH-OTHER" in p for p in problems), problems)

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


class RcSssChain(unittest.TestCase):
    """The shipped release-candidate chain (T-2463, M3): the real files, the real route table."""

    ROOT = check_processes.default_root()
    CHAIN = ROOT / "test/uat/chains/rc-sss.json"

    def test_order_is_the_one_the_owner_gave(self):
        doc = json.loads(self.CHAIN.read_text())
        self.assertEqual(doc["processes"], ["BP-01", "BP-02", "BP-03", "BP-04", "BP-05", "BP-06",
                                         {"process": "BP-08", "dry_run": True}, "BP-09", "BP-07"])

    def test_every_process_resolves_and_passes_the_static_check(self):
        self.assertEqual(check_processes.check_files([self.CHAIN], root=self.ROOT, strict=True), [])

    def test_chain_gives_every_input_the_processes_need(self):
        doc = json.loads(self.CHAIN.read_text())
        for entry in doc["processes"]:
            name = entry["process"] if isinstance(entry, dict) else entry
            pdoc = json.loads(check_processes.runner.resolve_process_file(self.CHAIN.parent, name).read_text())
            own = set(pdoc.get("dry_run", {}).get("inputs") or {}) if isinstance(entry, dict) else set(doc["inputs"])
            missing = [i for i in pdoc.get("inputs", []) if i not in own]
            self.assertEqual(missing, [], name)

    def test_second_place_is_a_fixture_and_no_placeholder_remains(self):
        doc = json.loads(self.CHAIN.read_text())
        self.assertIn("second_place", doc.get("fixtures") or [])
        self.assertNotIn("place_to", doc["inputs"])
        self.assertNotIn("REPLACE-WITH-", self.CHAIN.read_text())
        transfer = json.loads(check_processes.runner.resolve_process_file(self.CHAIN.parent, "BP-03").read_text())
        self.assertIn("second_place", transfer.get("fixtures") or [])
        self.assertEqual(check_processes.check_files([self.ROOT / "test/uat/fixtures/second_place.json"],
                                                     root=self.ROOT), [])


class PlatformRunFiles(CheckCase):
    """The wait_mail step and the platform_residue block of a platform process (G18)."""

    def wait_step(self, sid="s6", **extra):
        spec = {"recipient": "${admin_email}", "subject": "Tenant registered"}
        spec.update(extra)
        return {"id": sid, "actor": "admin", "do": {"wait_mail": spec}, "expect": {"status": 200}}

    def test_a_wait_mail_step_is_accepted(self):
        doc = self.mutated(lambda d: (d["inputs"].append("admin_email"),
                                      d["steps"].append(self.wait_step())))
        self.assertEqual(self.check(doc), [])

    def test_an_undefined_name_in_a_wait_mail_step_is_caught(self):
        doc = self.mutated(lambda d: d["steps"].append(self.wait_step()))
        problems = self.check(doc)
        self.assertTrue(any("${admin_email}" in p and "step s6" in p for p in problems), problems)

    def test_a_wait_mail_time_that_is_a_number_is_accepted(self):
        doc = self.mutated(lambda d: (d["inputs"].append("admin_email"),
                                      d["steps"].append(self.wait_step(within_s=60, interval_s=2))))
        self.assertEqual(self.check(doc), [])

    def test_a_wait_mail_time_that_is_a_name_of_the_context_is_accepted(self):
        # the value is substituted before it is read: the loader accepts it, so the checker does not report it
        doc = self.mutated(lambda d: (d["inputs"].extend(["admin_email", "wait_s"]),
                                      d["steps"].append(self.wait_step(within_s="${wait_s}"))))
        self.assertEqual(self.check(doc), [])

    def test_a_wait_mail_time_that_is_no_number_is_caught(self):
        doc = self.mutated(lambda d: (d["inputs"].append("admin_email"),
                                      d["steps"].append(self.wait_step(within_s="soon"))))
        problems = self.check(doc)
        self.assertTrue(any("wait_mail within_s must be a number" in p for p in problems), problems)

    def test_a_wait_mail_step_without_a_recipient_and_a_subject_is_caught(self):
        doc = self.mutated(lambda d: d["steps"].append({"id": "s6", "actor": "admin",
                                                        "do": {"wait_mail": {"subject": "Tenant registered"}},
                                                        "expect": {"status": 200}}))
        problems = self.check(doc)
        self.assertTrue(any("wait_mail needs a recipient and a subject" in p for p in problems), problems)

    def test_a_platform_residue_block_is_accepted(self):
        doc = self.mutated(lambda d: d.update(platform_residue={"definitions": ["platform.register_tenant"],
                                                                 "instances": ["${doc_id}"]}))
        self.assertEqual(self.check(doc), [])

    def test_an_unknown_key_of_the_block_is_caught(self):
        doc = self.mutated(lambda d: d.update(platform_residue={"tenants": ["uat-tmp-x"]}))
        problems = self.check(doc)
        self.assertTrue(any("platform_residue has unknown keys" in p for p in problems), problems)

    def test_a_block_that_is_not_a_list_of_names_is_caught(self):
        doc = self.mutated(lambda d: d.update(platform_residue={"definitions": "platform.register_tenant"}))
        problems = self.check(doc)
        self.assertTrue(any("platform_residue.definitions must be a list of names" in p for p in problems), problems)

    def test_an_undefined_name_in_the_block_is_caught(self):
        doc = self.mutated(lambda d: d.update(platform_residue={"instances": ["${never_saved}"]}))
        problems = self.check(doc)
        self.assertTrue(any("platform_residue.instances" in p and "${never_saved}" in p for p in problems), problems)


class CleanupCoverage(CheckCase):
    """T-2885: a created document type has a cleanup that undoes it, or a residue_allow with reason and owner."""

    def setUp(self):
        super().setUp()
        (self.root / "lib/letflow/modules/stock/router.ex").write_text(
            STOCK_ROUTER + '''  authz_post "/documents/:id/reverse", :StockReverse,
  authz_post "/documents/:id/cancel", :StockReverse,
  authz_post "/quick-counts", :StockQuickCount do
''')

    def doc(self, steps, cleanup=(), **extra):
        d = {"id": "BP-T", "steps": steps, "cleanup": list(cleanup), **extra}
        return d

    CREATE = step("s1", "POST", "/api/v1/modules/stock/documents", save={"doc_id": "$.id"}, **{})
    REVERSE = step("c1", "POST", "/api/v1/modules/stock/documents/${doc_id}/reverse", requires=["doc_id"])

    def problems(self, doc):
        return [p for p in self.check(doc, strict=True) if "creates a" in p or "residue_allow" in p]

    def test_created_and_cleaned_passes(self):
        self.assertEqual(self.problems(self.doc([self.CREATE], [self.REVERSE])), [])

    def test_a_cancel_or_delete_is_a_cleanup_too(self):
        cancel = step("c1", "POST", "/api/v1/modules/stock/documents/${doc_id}/cancel", requires=["doc_id"])
        self.assertEqual(self.problems(self.doc([self.CREATE], [cancel])), [])

    def test_created_without_cleanup_fails_naming_file_step_and_type(self):
        create = copy.deepcopy(self.CREATE)
        create["do"]["body"] = {"kind": "receipt"}
        probs = self.problems(self.doc([create]))
        self.assertEqual(len(probs), 1, probs)
        self.assertIn("BP-T.json", probs[0])
        self.assertIn("step s1", probs[0])
        self.assertIn("stock/documents:receipt", probs[0])

    def test_a_quick_count_needs_a_documents_cleanup(self):
        qc = step("s1", "POST", "/api/v1/modules/stock/quick-counts")
        self.assertEqual(len(self.problems(self.doc([qc]))), 1)
        self.assertEqual(self.problems(self.doc([qc], [self.REVERSE])), [])

    def test_residue_allow_with_reason_and_owner_passes(self):
        allow = [{"type": "stock/documents", "reason": "kept for the audit demo", "owner": "BA"}]
        self.assertEqual(self.problems(self.doc([self.CREATE], residue_allow=allow)), [])

    def test_residue_allow_without_reason_fails(self):
        allow = [{"type": "stock/documents", "owner": "BA"}]
        probs = self.problems(self.doc([self.CREATE], residue_allow=allow))
        self.assertTrue(any("residue_allow[0]" in p for p in probs), probs)
        self.assertTrue(any("creates a" in p for p in probs), probs)

    def test_a_read_only_process_passes(self):
        read = step("s1", "GET", "/api/v1/modules/stock/documents/x")
        self.assertEqual(self.problems(self.doc([read])), [])

    def test_the_check_is_strict_only(self):
        self.assertEqual([p for p in self.check(self.doc([self.CREATE])) if "creates a" in p], [])


if __name__ == "__main__":
    unittest.main()
