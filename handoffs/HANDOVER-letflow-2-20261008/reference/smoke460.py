import json, subprocess, time, urllib.parse, sys

B = 'https://qa.bizdala.com/api/v1'
E = 'C:/Users/tvolo/dev/ai-dala/ai-dala-infra/scripts/qa-uat-env.sh'


def tok(user):
    out = subprocess.run(['C:/Program Files/Git/bin/bash.exe', E, 'token', user], capture_output=True, text=True).stdout.strip().splitlines()
    return out[-1]


def call(t, method, path, body=None):
    args = ['curl', '-s', '-w', '\n%{http_code}', '-X', method, B + path, '-H', 'Authorization: Bearer ' + t,
            '-H', 'Content-Type: application/json']
    if body is not None:
        args += ['--data-binary', '@-']
    p = subprocess.run(args, input=json.dumps(body) if body is not None else None, capture_output=True, text=True)
    txt, code = p.stdout.rsplit('\n', 1)
    try:
        j = json.loads(txt) if txt.strip() else None
    except Exception:
        j = txt[:200]
    return int(code), j


def data(j):
    return j.get('data', j) if isinstance(j, dict) else j


admin = tok('vortex-admin-user')
sab = tok('actor-vortex-sabine')
print('tokens', len(admin), len(sab))

c, j = call(admin, 'GET', '/definitions/active/' + urllib.parse.quote('Production Order Release'))
d = data(j)
print('active def', c, d.get('version'), d.get('id'))
def_id = d['id']


def start(tag):
    c, j = call(admin, 'POST', '/instances', {'definition_id': def_id, 'initial_variables': {
        'order_id': f'smoke460-{tag}-{int(time.time())}', 'order_value_eur': 500}})
    print('start', tag, c, json.dumps(j)[:300] if c >= 300 else '')
    dd = data(j); print('start keys', sorted(dd.keys())[:12]); return dd.get('id') or dd.get('instance_id') or dd['instance']['id']


def find_task(inst, tries=10):
    for _ in range(tries):
        c, j = call(sab, 'GET', '/tasks?page_size=100')
        items = (j.get('items') if isinstance(j, dict) else None) or []
        for t in items:
            if t.get('instance_id') == inst and t.get('status', 'PENDING') in ('PENDING', 'OPEN', 'pending', 'open'):
                return t
        time.sleep(2)
    return None


def inst_status(inst):
    c, j = call(admin, 'GET', f'/instances/{inst}')
    return c, data(j).get('status')


i1 = start('a')
t1 = find_task(i1)
print('task found', bool(t1), (t1 or {}).get('node_id'), (t1 or {}).get('status'))
if not t1:
    sys.exit(1)
tid = t1['id']
BOGUS = 'zz-bogus-smoke-value'
print('--- (1)+(3) out-of-enum + a foreign key')
c, j = call(sab, 'POST', f'/tasks/{tid}/complete', {'capacity_decision': BOGUS, 'zz_foreign_key': 'q'})
raw = json.dumps(j)
print('complete bogus ->', c, 'code:', (j.get('code') if isinstance(j, dict) else None), 'rejected_keys:', j.get('rejected_keys') if isinstance(j, dict) else None,
      'missing_keys:', j.get('missing_keys') if isinstance(j, dict) else None)
print('value echoed in body:', BOGUS in raw, '| enum echoed:', ('approve' in raw) or ('reject' in raw), '| foreign key in body:', 'zz_foreign_key' in raw)
print('body keys:', sorted(j.keys()) if isinstance(j, dict) else j)
c, ti = call(sab, 'GET', f'/tasks/{tid}')
print('task after refusal:', c, data(ti).get('status') if isinstance(data(ti), dict) else ti)
print('instance after refusal:', inst_status(i1))
print('--- (2) retry with valid value')
c, j = call(sab, 'POST', f'/tasks/{tid}/complete', {'capacity_decision': 'approve'})
print('complete approve ->', c)
for _ in range(8):
    time.sleep(3)
    st = inst_status(i1)
    if st[1] not in ('RUNNING', 'ACTIVE', 'running', 'active'):
        break
print('instance after retry:', st)
print('--- (4) happy path, second instance, reject')
i2 = start('b')
t2 = find_task(i2)
c, j = call(sab, 'POST', f'/tasks/{t2["id"]}/complete', {'capacity_decision': 'reject'})
print('complete reject ->', c)
time.sleep(5)
print('instance 2:', inst_status(i2))
print('ids', i1, i2)
