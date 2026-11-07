# Demo showroom: the seed script (T-1470, D-108)

A second Letflow instance, reachable from the internet, shows partners and clients ONE tenant with
invented data they can walk through in five minutes. `scripts/demo/demo_showroom_seed.sh` builds that
tenant. It is one bash script that works only through the tenant's own HTTP API, so it runs against any
build, and it is safe to run again after every upgrade.

## What the demo shows

| Area | Content (all names, numbers and the BIN are invented; e-mails only `@example.com`) |
|---|---|
| Organisation | Legal entity "Altyn Tulpar LLP", site "Almaty office", org units Head office > Warehouse team, Sales team; 5 employees (two storekeepers, a sales manager, a sales assistant, an accountant) |
| Locations | Kazakhstan > Almaty > Central warehouse > Rack 01, Rack 02; Almaty > Showroom; Kazakhstan > Astana > Branch warehouse |
| Catalog | 12 items named in English, Russian and Kazakh (for example `Laptop 14"`, `Цемент М400`, `Сүт 2,5% 1 л`, `Қара шай 100 г`), 4 units of measure, 2 lots of milk with expiry dates, 3 barcodes and a QR code on Rack 01 |
| Stock | Documents of every kind, all posted: 2 receipts, a transfer, an issue, a hand over, a return, a write off, and an opening balance of the Sales team (approved by a second person); balances and the movements journal follow from them |
| Stock count | One full count of the Warehouse team taken through counting (one shortage, one surplus line), closed, sheet signed, differences sheet issued and signed. It is left **unposted**, so a partner can press Post live. The Inv-10 and Inv-18 forms (also Tug-10 / Tug-18) print from it |
| Assets | 6 cards (fixed, low value, intangible) and, when the build has the module, a commission, a hand over and a write off document |

**What the demo does not show.** The catalog item has no photo field and no per-language name field, so
"photos or names in three languages" is met by clean item names, some in each language. There is no second
(ordered) count: two open counts of one unit may not share a location, and the Sales team's count needs a chair
with a user account; order one on the screen.

Operator inputs for the public demo instance (realm files, smoke read, platform tenant bootstrap, survival counts): `docs/runbooks/demo-operator-inputs.md`. On the demo the password grant uses the client `letflow-demo-smoke` (`BPM_IDP_CLIENT_ID=letflow-demo-smoke`).

## How to run

Needs `bash`, `curl`, `jq`, GNU `date`, `cksum`. Everything comes from the environment; nothing secret is in the
repository.

```
BASE_URL=https://demo.example.org TENANT_SLUG=showroom \
ADMIN_USERNAME=... ADMIN_PASSWORD=... ADMIN_REALM=... \
ADMIN2_USERNAME=... ADMIN2_PASSWORD=... \
  bash scripts/demo/demo_showroom_seed.sh
```

| Variable | Meaning |
|---|---|
| `BASE_URL` | the instance; the API is `$BASE_URL/api/v1` (required) |
| `TENANT_SLUG` | the demo tenant, default `showroom` |
| `DEMO_TAG` | lowercase letters and digits, default `demo`; every code, external reference and idempotency key derives from it |
| `ACCESS_TOKEN`, or `ADMIN_USERNAME` + `ADMIN_PASSWORD` + `ADMIN_REALM` | sign-in of the tenant administrator (an interactive user: the stock routes answer 404 to an API token). The password grant uses `BPM_IDP_BASE_URL` and `BPM_IDP_CLIENT_ID` (default `letflow-web`). `ADMIN_USERNAME` is also needed with a token: it is linked to the storekeeper, the chair of the count |
| `ACCESS_TOKEN2`, or `ADMIN2_USERNAME` + `ADMIN2_PASSWORD` | optional second administrator (linked to the sales manager). The opening balance needs a second person to approve it; without one it stays *issued* and the script says so |
| `PLATFORM_ACCESS_TOKEN` + `DEMO_REALM` + `DEMO_HOSTNAME` | optional: create the tenant through `POST /api/v1/onboarding` when `TENANT_SLUG` does not exist. The Keycloak realm and the administrator accounts are infra's job; the script never creates them |
| `SKIP_DOCS=1` | masters, codes and asset cards only: no stock documents, no counts, no asset documents |

Both administrators must have signed in once for their accounts to exist. The script prints, at the end, the demo
logins **without passwords**, the scanner codes and the screens to open first. Exit code 0 is done, 1 is a
failed step (`STOP: ...`), 2 is a missing tool or bad input (nothing was requested).

Without `PLATFORM_ACCESS_TOKEN` the tenant must already exist; the script stops at `GET /me/modules` with a clear
line when it does not.

## Running it again (idempotent)

A second run changes nothing. Masters use the import route (`upsert by external ref`) or an idempotency key,
location nodes and lots are looked up by code, and each document and the count carry a marker note
(`demo:<tag>:<name>`) that the script reads back through the list routes. A run that failed half-way completes
on the next run (a document found issued but not posted gets its post task completed). The test
`test/scripts/demo_showroom_seed_test.exs` runs the script through a real HTTP listener, twice, and compares the
row counts of every table.

## Re-run after an upgrade

Run the script on the new build after every upgrade. It fills in what a new build needs and leaves the rest. A
renamed item goes through the external-reference upsert (updated, not duplicated). If a build changes the shape of
a document body the script fails loudly (`STOP: <step>: HTTP 422 <reason>`), never silently; fix the script in
the same change that changed the shape. On a build without the assets module (or without its routes) the assets step
is skipped with `skip assets: ...` and the script still exits 0. The check that an upgrade did not break the chain
is running this script on the new build.

## Reset

The script never deletes anything. To start again, drop the tenant (`DELETE /admin/v1/tenants/:id` with the
provisioner credential, see `docs/runbooks/tenant-provisioner-credential.md`), create it again (with
`PLATFORM_ACCESS_TOKEN` the script does that), and run the script. A new `DEMO_TAG` makes a second, separate data
set on the same tenant.

## Safety

Passwords go to `curl` on stdin; tokens go through a `0600` config file in a `0700` temporary directory that is
removed on exit; nothing secret is printed and `xtrace` is never on.
