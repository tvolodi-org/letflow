# Demo instance: the index page (T-1516, D-108)

Start here if you are new. The demo instance is a second, public Letflow installation that shows partners and clients
one tenant with invented data. This page says what runs where, which script does what, who owns what, how a new build
is promoted onto it and how to go back. It points to the detailed pages; it holds no secrets (passwords come from files
or the environment, never from the repository).

## What runs where

| Part | What it is | Where |
|---|---|---|
| Letflow backend and web app | One build of this repository (the Elixir backend serving the React app), with its own PostgreSQL database that is kept from build to build | `https://demo.letflow.ai-dala.com` |
| Keycloak (sign-in) | One realm per tenant: `demo-showroom` (the showroom tenant) and `demo-platform` (the platform tenant, operator only) | `https://auth-demo.letflow.ai-dala.com` |
| Showroom tenant | Slug `showroom`: organisation, locations, catalog, stock documents, a stock count, asset cards. All names and numbers are invented, e-mails only `@example.com` | inside the backend database |
| Platform tenant | Slug `platform`: only the operator's `PLATFORM_ADMIN` lives there; it is used to create and drop the showroom tenant | inside the backend database |

The demo is not production and not QA: it keeps its data so that a partner can walk through the same story every time.
Names and values of the realms, clients and users: `docs/runbooks/demo-operator-inputs.md`.

## Pages and scripts

| Page or script | Use it to |
|---|---|
| `docs/runbooks/demo-operator-inputs.md` | Read the environment values, the realm files in `docs/runbooks/demo-realm/`, the exact order of a first install, the smoke and survival checks |
| `docs/runbooks/demo-showroom.md` | Understand what the demo shows, run the seed, re-run it, reset the tenant |
| `docs/runbooks/demo-upgrade-notes.md` | Check that data survived an upgrade, apply the module upgrade chain, read the list of builds that break an in-place promote |
| `scripts/demo_smoke_read.sh` | Sign in as the smoke user and read one authenticated endpoint; prints `PASS` when login and the tenant work |
| `scripts/demo/demo_platform_bootstrap.sh` | On a brand-new database: create the platform tenant, then (after the backend was restarted with its id) finish and verify the `PLATFORM_ADMIN` role group |
| `scripts/demo/demo_showroom_seed.sh` | Build the showroom data through the tenant's HTTP API; safe to run again |
| `scripts/demo/demo_counts.sh` | `snapshot` and `compare` row counts: nothing may be lost by a promote |
| `scripts/demo/demo_upgrade_check.sh` | `snapshot` before and `verify` after a promote: counts, checksums and whether every module is `up_to_date`; read-only |
| `scripts/demo_upgrade_chain.sh` | Apply the module upgrade chain to the demo tenants (plan, apply, plan again); never acknowledges a destructive step |

Every script reads its settings from the environment and says what it needs in its header comment.

## Who owns what

| Owner | Owns |
|---|---|
| Letflow team (this repository) | The product build, the seed and check scripts above, the realm files, these pages, and fixing the seed when a build changes a document shape |
| Infra | The hosts, the reverse proxy, Keycloak itself, the database and its backups, the environment variables of the release, and `promote-demo.sh`, the promote command that runs the scripts in order |
| Product owner | Decisions: when to promote, whether `LETFLOW_MODULE_UPGRADE_ON_BOOT` is on, a destructive (class B) upgrade step, and anything that touches real partners' use of the demo |

If you are unsure, ask the product owner; do not change the database or Keycloak by hand.

## How to promote a new build

1. Infra takes a database backup.
2. `demo_upgrade_check.sh snapshot FILE` (and, if you want, `demo_counts.sh snapshot`) records the state before.
3. Infra promotes the build (`promote-demo.sh`): new release, then `scripts/demo_upgrade_chain.sh` applies the module upgrades.
4. `demo_upgrade_check.sh verify FILE` (and `demo_counts.sh compare`) checks that nothing was lost.
5. `demo_showroom_seed.sh` runs again: it fills in what the new build needs and changes nothing else.
6. `demo_smoke_read.sh` must print `PASS`.

Exit codes of the check and what each means: `docs/runbooks/demo-upgrade-notes.md`. In short: 0 done, 1 data differs
(roll back), 2 bad call, 3 data equal but a module is still pending (an administrator must apply it, writes to that
module answer 409 `upgrade_required` until then), 4 a request failed so the check cannot judge.

## How to roll back

- Exit 1 from `verify`, or a `LOST` line from `demo_counts.sh compare`: stop the demo, restore the database backup taken
  before the promote, put the previous build back, and report the output of the check.
- Exit 3 is not data loss: apply the pending plan as an administrator, or wait for a build with a declared step.
- To start the showroom tenant from nothing, not to undo a promote: drop the tenant and run the seed again, as described
  under "Reset" in `docs/runbooks/demo-showroom.md`. The seed itself never deletes anything.
- A brand-new database follows the first-install order in `docs/runbooks/demo-operator-inputs.md`.
