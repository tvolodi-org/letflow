# The outbound allow-list (T-2597, pilot gap G14)

A tenant's **definitions** may reach **outside the tenant** only where its own list says so (the exceptions are listed under "What is NOT governed here"). The list is
per tenant, it is **empty by default**, and only a holder of the narrow atom
`:OutboundDestinationsManage` may change it.

This is the guardrail of the "Register a tenant" pilot (decision record G2, decision
(c)): before G14, a definition author could send the variables of a process to any
public HTTPS host, and nothing but the permission to edit a definition stood between
the process data and the outside world.


## Grandfathering (follows decision G2 (c))

When the allow-list arrives, the channels and literal hosts that a tenant's
ALREADY-ACTIVE definitions use are listed as allowed by the migration
(`OutboundDestinations.grandfather/1`). Each such row carries the id of the
definition and the reason `grandfathered by G14`; `GET /api/v1/outbound-destinations`
shows `definition_id` and `reason`. A dynamic host (`{{variables.host}}`) is not
listed. Only NEW destinations are deny by default, so the QA fixture seeding of
definitions that are already active keeps working without giving
`PROCESS_DESIGNER` the `OutboundDestinationsManage` atom.

## What the list holds

Two kinds of entry, one table (`outbound_destinations`, one row per tenant schema):

| Row | Meaning |
|---|---|
| `destination IS NULL` | the **CHANNEL** itself is allowed -- the door (`email`, `file`, `http`) |
| `destination IS NOT NULL` | one **DESTINATION** on that channel -- a recipient domain for the mail channel, a host for the HTTP channel |

A destination is matched **exactly** and in lower case, and an HTTP host entry covers **every port** of that host (the list holds a bare host, never `host:port`): `uat.letflow.internal` does
not cover `mail.uat.letflow.internal`, and a subdomain is its own entry. A
destination is never an address of a person (`person@example.com` is refused) and
never a URL (`https://host/path` is refused): the list holds names, not personal data
(INV-4).

The **file** channel has no destination: it writes into the tenant's own file area,
so there is nothing outside to allow.

## Who may change it

| Role | Holds `:OutboundDestinationsManage` |
|---|---|
| `PLATFORM_ADMIN` | yes |
| `TENANT_ADMIN` | yes |
| `PROCESS_DESIGNER` | **no** |
| every other role | no |

The person who draws the process is not the person who opens the door (decision
record G2 (c)). Every change is an audit row with the actor
(`outbound_destinations.add` / `outbound_destinations.remove`).

**Who has to open the door, and when.** A definition that reaches outside is
switched on only after the door is open, so the person who deploys such a
definition needs the door opened FIRST -- by someone who holds the atom. The QA
seed scripts of the shipped fixture definitions (`scripts/seed_*_definition.sh`,
whose inline HTTP steps reach `httpbin.org`) run with a definition author's token
and therefore cannot open the door themselves: a tenant administrator has to add
the `http` channel and the `httpbin.org` host for that tenant before the seed
activates the definition.

Since T-2730 the seed scripts open them themselves, right before the first
activate call (`scripts/lib/seed_outbound_open.sh`): the `http` channel and every
literal host of the rewritten payload, through `POST /api/v1/outbound-destinations`.
That call needs a token holding `OutboundDestinationsManage` (TENANT_ADMIN); a
token without it stops the seed with a named error before anything is changed.
Entries already on the list are not added again, and no URL (so no credential in
`SERVICE_TASK_MOCK_BASE_URL`) is ever printed. Test: `bash scripts/test_seed_outbound_open.sh`.

## The platform's own standard definition

The platform's own seed of the pilot's registration definition
(`Letflow.PlatformProcesses.Seed`, `platform.register_tenant` v1) writes into
the **platform tenant** and its version ends in a notification step, so the
platform tenant's list has to allow the mail channel -- or the platform's own
standard version could never be switched on.

The seed therefore opens the **channels its own version uses** for the tenant
it writes into, right before the switch-on
(`Letflow.OutboundDestinations.open_channels/3`). Three things it does not do:

* it opens **no destination**: a recipient domain stays a human decision, so a
  notification still goes only to a domain somebody listed;
* it does **not** re-open a channel after the switch-on: the channels are
  opened on the path where the seed writes and switches on its own version, and
  on the path where it finishes an interrupted switch-on of that version; a
  channel an administrator closed after a **completed** switch-on stays closed;
  on the interrupted-switch-on path the seed re-opens the channel of its own
  version, which opens no address (a destination is still needed for a send);
* it does not invent the authority: the seed opens a channel only with the
  authority of an administrator who **holds** `:OutboundDestinationsManage`
  (`{:error, :activator_not_permitted}` otherwise) -- the same rule the seed
  already follows for `:TenantsManage`.

A channel alone opens nothing: a send still needs a listed destination. The
seed's own switch-on therefore leaves the platform tenant with an open mail
channel and a closed address book -- which is what the pilot's acceptance list
expects ("a notify step whose recipient domain is not allowed is refused").

## The routes

| Route | Body / query | Answer |
|---|---|---|
| `GET /api/v1/outbound-destinations` | -- | the tenant's entries |
| `POST /api/v1/outbound-destinations` | `channel`, optional `destination` | 201 with the entry |
| `DELETE /api/v1/outbound-destinations` | query `channel`, optional `destination` | 204, or 404 when the entry was not there |

The tenant comes only from the DB-resolved `auth_context` (INV-1, INV-10): a
`tenant_id` in the body or the query is never read. A refusal names the field
(`channel is invalid`, `destination is invalid`) and never echoes the submitted
value.

## Where the list is checked -- twice

1. **At activation** (`Letflow.Definitions.check_outbound_destinations/2`, shared by
   the four paths that switch a version on: activate, reactivate, version rollback,
   promotion apply). A step whose channel or destination is not on the list is
   refused with `{:outbound_destinations_invalid, violations}` and the codes
   `:outbound_channel_not_allowed`, `:outbound_destination_not_allowed` or
   `:outbound_allow_list_unavailable`.

   Over HTTP every one of those paths (and the solution-pack override activation) answers **422** with
   `{"error": "outbound_destinations_invalid", "violations": [{"node_id", "index",
   "code"}]}` (the body shape of `notify_calls_invalid`; never the submitted value),
   and nothing is activated or promoted. For a promotion apply the list that counts
   is the TARGET tenant's.

   A **notification** step sends on the channel its declaration names; its recipient
   is read from a *variable* of the running instance, so the destination is not
   known at activation time and only the channel is checked there. An **inline HTTP**
   step names its host in the definition, so its destination IS checked there -- and a
   **dynamic host** (`https://{{variables.host}}/hook`) is REFUSED there: the list
   names hosts, not templates, so a host that cannot be checked is a host that is not
   allowed. A templated PATH with a literal host (`https://api.example.com/{{...}}`)
   is fine: the request still reaches the one host the list names.

2. **At dispatch**. The list is read again, so a destination that was removed after the
   activation stops the step that would have used it (decision record G2, S7: "the list
   widened after activation").

   * a **notification** step is re-read by `Letflow.NotificationSteps.Dispatcher`; the
     refusal is one code, `:notify_destination_not_allowed`: the caller learns that
     the step cannot run, not which part of the list it missed;
   * an **inline HTTP** step is re-read by `Letflow.Engine.ServiceTaskDispatcher`
     (`dispatch_inline/4`), on the very attempt that would open the socket. The HOST of
     the rendered URL is checked against the list -- the same target the activation
     fence checks, so a host that was removed from the list after the activation stops
     the step. A host that cannot be READ (no host, a placeholder host, a URL too long
     or not valid UTF-8) cannot be CHECKED, and a target nobody can check is a target
     nobody may reach. The refusal is `{:request_build_error,
     :outbound_destination_not_allowed}`: the request was never made, the outcome is
     not retriable, and no outbound-request audit row is written for a request that
     was never sent.

The check is **fail closed**: a list that cannot be read allows nothing.

## What is NOT governed here

* The platform's own notifications to a tenant's **own users** (the per-user path of
  `Letflow.Notifications`) are not outbound and stay as they are.
* **Webhook subscriptions** (`WebhookSubscriptionsManage`) reach outside the tenant
  too and are NOT covered by this list: they are a separate feature with their own
  permission. Closing that door is a later slice.
* A **catalogue service** step (`service_id`) resolves its endpoint from the tenant's
  pinned service catalogue, not from the definition, so its host is not on this list
  either -- neither at activation nor at dispatch: the catalogue's own governance is a
  separate question.
* The **Telegram adapter** does not exist yet; the channel vocabulary is designed so
  that one is one more value.

## The extension point (owner decision D-180, not built here)

The list is a tenant's own data, not a definition's: a tenant that later forks a
standard definition (`custom`, `based_on: <standard key>@<version>`) brings its own
list with it, and the per-tenant binding that says which definition runs changes
nothing here. Nothing in this feature assumes that a definition is editable by
whoever sees it, nor that a tenant has exactly one definition per key.

## Residual risks, stated plainly

* A `PLATFORM_ADMIN` session that is stolen can open the door for every tenant: the
  audit row shows it, it does not prevent it (the same residual risk the decision
  record states for the whole authority rule).
* A list that is too wide is an open door: the list is the tenant's own choice, and
  the audit shows who widened it and when.
