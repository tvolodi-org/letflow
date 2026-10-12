import json, subprocess, time, urllib.parse, sys

exec(open(r'C:\Users\tvolo\AppData\Local\Temp\claude\c--Users-tvolo-dev-ai-dala-letflow-2\c4c4ca8f-e4ea-4e0d-af65-aa964cbd17f7\scratchpad\smoke460.py').read().split("admin = tok(")[0])


def start(admin, name, vars_):
    c, j = call(admin, 'GET', '/definitions/active/' + urllib.parse.quote(name))
    d = data(j)
    c, j = call(admin, 'POST', '/instances', {'definition_id': d['id'], 'initial_variables': vars_})
    return c, data(j).get('instance_id'), d.get('version')


def find(tk, inst, node, tries=12):
    for _ in range(tries):
        c, j = call(tk, 'GET', '/tasks?page_size=100')
        for x in (j.get('items') or []):
            if x.get('instance_id') == inst and x.get('node_id') == node and x.get('status') == 'PENDING':
                return x
        time.sleep(2)


def status(admin, inst):
    return data(call(admin, 'GET', f'/instances/{inst}')[1]).get('status')


def ts(tk, tid):
    d = data(call(tk, 'GET', f'/tasks/{tid}')[1])
    return d.get('status') if isinstance(d, dict) else d


def refusal(label, c, j):
    print(f'  {label}: {c} code={j.get("code") if isinstance(j, dict) else None} missing={j.get("missing_keys") if isinstance(j, dict) else None} rejected={j.get("rejected_keys") if isinstance(j, dict) else None}')


ts_ = int(time.time())
print('### VORTEX capacity-review (Production Order Release 1.6)')
va = tok('vortex-admin-user'); sab = tok('actor-vortex-sabine')
c, i, v = start(va, 'Production Order Release', {'order_id': f'smoke462-{ts_}', 'order_value_eur': 500})
print(' start', c, 'v', v)
t = find(sab, i, 'capacity-review')
c, j = call(sab, 'POST', f"/tasks/{t['id']}/complete", {}); refusal('(1) no key', c, j)
print('   task after:', ts(sab, t['id']), '| instance:', status(va, i))
c, j = call(sab, 'POST', f"/tasks/{t['id']}/complete", {'capacity_decision': None}); refusal('(3) null key', c, j)
c, j = call(sab, 'POST', f"/tasks/{t['id']}/complete", {'capacity_decision': 'zz-bogus'}); refusal('    out-of-enum', c, j)
print('   body contains bogus value:', 'zz-bogus' in json.dumps(j))
print('   task after:', ts(sab, t['id']), '| instance:', status(va, i))
c, j = call(sab, 'POST', f"/tasks/{t['id']}/complete", {'capacity_decision': 'approve'}); print('  (2) resubmit with key:', c)
for _ in range(8):
    time.sleep(3)
    s = status(va, i)
    if s != 'ACTIVE':
        break
print('   instance:', s)
c, i2, _ = start(va, 'Production Order Release', {'order_id': f'smoke462b-{ts_}', 'order_value_eur': 500})
t2 = find(sab, i2, 'capacity-review')
c, j = call(sab, 'POST', f"/tasks/{t2['id']}/complete", {'capacity_decision': 'reject'}); print('  (4) scenario happy path (reject):', c)
for _ in range(8):
    time.sleep(3)
    s = status(va, i2)
    if s != 'ACTIVE':
        break
print('   instance:', s)

print('### SWIFTROUTE ops-review (Shipment Approval 1.6)')
sa = tok('swiftroute-admin-user'); marco = tok('actor-swiftroute-marco')
c, i3, v = start(sa, 'Shipment Approval', {'shipment_id': f'smoke462-{ts_}', 'destination': 'Munich', 'declared_value': 750, 'cargo_type': 'standard', 'requesting_actor_id': 'actor-swiftroute-lena'})
print(' start', c, 'v', v)
t3 = find(marco, i3, 'ops-review')
print('   ops-review task found:', bool(t3))
if t3:
    c, j = call(marco, 'POST', f"/tasks/{t3['id']}/complete", {}); refusal('(1) no key', c, j)
    print('   task after:', ts(marco, t3['id']), '| instance:', status(sa, i3))
    c, j = call(marco, 'POST', f"/tasks/{t3['id']}/complete", {'ops_decision': 'approve'}); print('  (2) resubmit with key:', c)
print('   cancel', call(sa, 'POST', f'/instances/{i3}/cancel', {})[0])

print('### MERIDIAN non-adopted credit-memo-review (Loan Origination 1.13)')
ma = tok('meridian-admin-user'); ben = tok('actor-meridian-ben')
c, i4, v = start(ma, 'Loan Origination', {'application_id': f'smoke462-{ts_}', 'applicant_id': 'borrower-smb-001', 'requested_amount_eur': 50000, 'product_type': 'term_loan', 'tenor_months': 24, 'analyst_actor_id': 'actor-meridian-sophie', 'purpose': 'smoke'})
print(' start', c, 'v', v)
t4 = find(ben, i4, 'credit-memo-review')
print('   credit-memo-review found:', bool(t4))
if t4:
    c, j = call(ben, 'POST', f"/tasks/{t4['id']}/complete", {}); print('  (5) complete WITHOUT credit_decision:', c, (j.get('code') if isinstance(j, dict) else None))
    print('   task after:', ts(ben, t4['id']), '| instance:', status(ma, i4))
print('   cancel', call(ma, 'POST', f'/instances/{i4}/cancel', {})[0])
