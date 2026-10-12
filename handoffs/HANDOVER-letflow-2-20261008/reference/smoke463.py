import json, subprocess, time, urllib.parse, sys, datetime

exec(open(r'C:\Users\tvolo\AppData\Local\Temp\claude\c--Users-tvolo-dev-ai-dala-letflow-2\c4c4ca8f-e4ea-4e0d-af65-aa964cbd17f7\scratchpad\smoke460.py').read().split("admin = tok(")[0])

DATE = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%d')
NAME = f'zz-smoke-distinct-from-{DATE}'
ROLE = sys.argv[1] if len(sys.argv) > 1 else 'TASK_WORKER'
DEF = {
    'name': NAME, 'version': '1.0',
    'description': 'THROWAWAY smoke definition for REQ-463 (distinct_from). Deprecated right after the run.',
    'graph': {
        'nodes': [
            {'id': 'start', 'node_type': 'START', 'attributes': {}},
            {'id': 'vote-a', 'node_type': 'HUMAN_TASK', 'attributes': {'role': ROLE}},
            {'id': 'vote-b', 'node_type': 'HUMAN_TASK', 'attributes': {'role': ROLE, 'distinct_from': ['vote-a']}},
            {'id': 'end', 'node_type': 'END', 'attributes': {}},
        ],
        'edges': [
            {'id': 'e0', 'source': 'start', 'target': 'vote-a'},
            {'id': 'e1', 'source': 'vote-a', 'target': 'vote-b'},
            {'id': 'e2', 'source': 'vote-b', 'target': 'end'},
        ],
    },
}
json.dump(DEF, open(r'C:\Users\tvolo\AppData\Local\Temp\claude\c--Users-tvolo-dev-ai-dala-letflow-2\c4c4ca8f-e4ea-4e0d-af65-aa964cbd17f7\scratchpad\zz-smoke-def.json', 'w'), indent=1)

admin = tok('vortex-admin-user')
karl = tok('actor-vortex-karl'); sab = tok('actor-vortex-sabine'); dirk = tok('actor-vortex-dirk')
created = []
insts = []
CONST = {'detail': 'separation of duties', 'status': 403}


def raw(t, method, path, body=None):
    args = ['curl', '-s', '-w', '\n%{http_code}', '-X', method, B + path, '-H', 'Authorization: Bearer ' + t, '-H', 'Content-Type: application/json']
    if body is not None:
        args += ['--data-binary', '@-']
    p = subprocess.run(args, input=json.dumps(body) if body is not None else None, capture_output=True, text=True)
    txt, code = p.stdout.rsplit('\n', 1)
    return int(code), txt


def pend(t, inst, node, tries=12):
    for _ in range(tries):
        c, j = call(t, 'GET', '/tasks?page_size=100')
        for x in (j.get('items') or []):
            if x.get('instance_id') == inst and x.get('node_id') == node and x.get('status') in ('PENDING',):
                return x
        time.sleep(2)


def new_instance():
    c, j = call(admin, 'POST', '/instances', {'definition_id': did, 'initial_variables': {'smoke': 'zz'}})
    i = data(j).get('instance_id'); insts.append(i); return i


def audit_rows(task_id):
    c, j = call(admin, 'GET', '/audit?page_size=100')
    items = (j.get('items') if isinstance(j, dict) else None) or []
    return [x.get('action') for x in items if 'completion_refused' in str(x.get('action')) and task_id in json.dumps(x)]


try:
    c, j = call(admin, 'POST', '/definitions', DEF)
    print('create def', c, json.dumps(j)[:200] if c >= 300 else '')
    did = data(j)['id']; created.append(did)
    c, v = call(admin, 'POST', f'/definitions/{did}/validate', {})
    print('validate', c, 'warnings', v.get('warnings') if isinstance(v, dict) else v)
    c, j = call(admin, 'POST', f'/definitions/{did}/activate', {})
    print('activate', c)

    # --- instance 1: same user (karl) does vote-a, then tries vote-b
    i1 = new_instance()
    ta = pend(karl, i1, 'vote-a'); print('vote-a task found', bool(ta))
    c, j = call(karl, 'POST', f"/tasks/{ta['id']}/complete", {}); print('karl completes vote-a:', c)
    tb = pend(karl, i1, 'vote-b'); print('vote-b task visible to karl:', bool(tb))
    tbid = tb['id']
    c, body_claim = raw(karl, 'POST', f'/tasks/{tbid}/claim', {})
    print('(a) karl CLAIM vote-b:', c, body_claim)
    print('    audit rows after claim:', audit_rows(tbid))
    c, body_complete = raw(karl, 'POST', f'/tasks/{tbid}/complete', {})
    print('(b) karl COMPLETE vote-b:', c, body_complete)
    print('    audit rows after complete:', audit_rows(tbid))
    print('    constant body identical claim vs complete:', body_claim == body_complete, '| exact:', json.loads(body_complete) == CONST)
    # (e) second refusal by same user via complete again -> byte identical?
    c, body2 = raw(karl, 'POST', f'/tasks/{tbid}/complete', {})
    print('(e) repeat complete byte-identical:', body2 == body_complete, '| audit rows:', len(audit_rows(tbid)))
    print('    instance status:', data(call(admin, 'GET', f'/instances/{i1}')[1]).get('status'))
    # (c) different user sabine claims + completes
    c, _ = raw(sab, 'POST', f'/tasks/{tbid}/claim', {}); print('(c) sabine claim:', c)
    c, _ = raw(sab, 'POST', f'/tasks/{tbid}/claim', {}); print('(d) sabine idempotent re-claim:', c)
    c, _ = raw(sab, 'POST', f'/tasks/{tbid}/complete', {}); print('(c) sabine complete:', c)
    time.sleep(3)
    print('    instance status:', data(call(admin, 'GET', f'/instances/{i1}')[1]).get('status'))

    # --- instance 2: TENANT_ADMIN not exempt (admin completes vote-a if allowed, then vote-b)
    i2 = new_instance()
    ta2 = pend(karl, i2, 'vote-a')
    c, b = raw(admin, 'POST', f"/tasks/{ta2['id']}/complete", {}); print('admin completes vote-a (eligibility probe):', c, b[:120])
    if c == 200:
        tb2 = pend(admin, i2, 'vote-b') or pend(karl, i2, 'vote-b')
        c, b = raw(admin, 'POST', f"/tasks/{tb2['id']}/complete", {})
        print('(e) TENANT_ADMIN same-user COMPLETE vote-b:', c, b, '| exact:', (json.loads(b) == CONST) if c == 403 else None)

    # --- instance 3: three distinct users pass (karl a, sabine b)
    i3 = new_instance()
    ta3 = pend(karl, i3, 'vote-a'); call(karl, 'POST', f"/tasks/{ta3['id']}/complete", {})
    tb3 = pend(dirk, i3, 'vote-b')
    c, _ = raw(dirk, 'POST', f"/tasks/{tb3['id']}/complete", {}); print('distinct user dirk completes vote-b:', c)
    time.sleep(3)
    print('    instance status:', data(call(admin, 'GET', f'/instances/{i3}')[1]).get('status'))
finally:
    for i in insts:
        s = data(call(admin, 'GET', f'/instances/{i}')[1]).get('status')
        if s == 'ACTIVE':
            print('cancel', i[:8], call(admin, 'POST', f'/instances/{i}/cancel', {})[0])
    for d in created:
        print('deprecate', d, call(admin, 'POST', f'/definitions/{d}/deprecate', {})[0])
        print('definition status now:', data(call(admin, 'GET', f'/definitions/{d}')[1]).get('status'))
