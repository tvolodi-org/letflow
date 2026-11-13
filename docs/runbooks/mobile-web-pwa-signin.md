# Mobile PWA sign-in: Keycloak setup per environment

Applies to the web build of `apps/mobile` (PWA M2, plan D-112). The native app signs in with the
fixed redirect `com.bizdala.letflow:/oauth2redirect`. The PWA signs in with a browser redirect
back to its own page, so each environment needs one more registered URI.

The shared realm template (`priv/keycloak/realms/bpm-default.json`) is **not** changed: its tests
pin the native redirect as the only entry (no http(s), no wildcard), and the PWA host differs per
environment. Adding the URI is a manual infra step; automating it in the provisioner is a follow-up.

## Prerequisite: the `letflow-mobile` client must exist in the tenant realm

The Keycloak client `letflow-mobile` is defined in `priv/keycloak/realms/bpm-default.json`, but the
provisioner's tenant realm template (`priv/keycloak/provisioner/v2/tenant-realm.json`, v1 frozen)
creates only `letflow-web`. A realm made by the provisioner therefore has NO `letflow-mobile`
client (infra created it by hand in realm `gate-b6`). Until the gap below is closed, create it
once per tenant realm from the `letflow-mobile` block of `bpm-default.json`: public client, standard
flow only, PKCE `S256`, implicit flow and direct access grants off, the `realm-roles` and
`letflow-mobile-audience` mappers, then do the steps below.

Gap (decision needed from PM/infra, not built in T-1863): the provisioner should create the client
too. It is not a one-line addition to a client list: the template is versioned and pinned by drift
tests (`keycloak_tenant_realm_template_v2_test.exs`), so it means a new template version, and the
redirect URIs and web origin differ per environment (the PWA host), so the provisioner needs a
setting for them. Infra owns the template and the provisioner; proposed shape: template v3 with
`letflow-mobile` (native redirect plus the environment's PWA URI substituted like the `letflow-web`
placeholders).

## Steps (per environment, per tenant realm that serves the PWA)

1. Decide the PWA address: `https://<pwa-host><base-href>`, for example
   `https://letflow-qa.ai-dala.com/mobile/` (example only; the base href is the one the app was
   built with, `flutter build web --base-href /mobile/`). The app derives its redirect URI at
   runtime from the page location (origin plus base path, trailing slash), so the registered value
   must match that exactly.
2. In the realm's `letflow-mobile` client add:
   - **Valid redirect URIs**: the exact URI from step 1. No wildcard.
   - **Web origins**: the origin only (`https://<pwa-host>`), needed for the browser's call to the
     token endpoint (CORS).
   - **Valid post logout redirect URIs**: the exact URI from step 1.
3. Keep PKCE method `S256` required on the client, and the token lifetimes of the template
   (short access token). Do not enable implicit flow or direct grants.
4. Only for a build with `LETFLOW_PWA_KEEP_SIGNED_IN=true` (stay signed in for 30 days, REQ-810):
   in the Keycloak 26.2 admin console, for the tenant realm,
   - Realm settings, Sessions tab: turn **Offline Session Max Limited** on and set **Offline Session
     Max** to 30 days (the identity provider then enforces the same 30 days as the app);
   - Clients, `letflow-mobile`, Client scopes tab: make sure the `offline_access` scope is assigned to
     the client (add it as **Optional** if it is not), so the app's `offline_access` request is granted.
   Without this the sign-in still works, but the 30 days then depend on the SSO session only.
5. Check: open the PWA, enter the tenant slug, sign in; the browser returns to the PWA URL and
   the address bar shows no `code`/`state` afterwards.

## Behaviour to know

- Flag off (default): tokens are kept in memory only (see `apps/mobile/README.md`, "Web sign-in
  (M2)"). A reload signs in again through Keycloak, silently while the SSO session lives.
- Flag on: after a full sign-in the user may accept "stay signed in for 30 days" and set a six-digit
  PIN. The refresh token then survives a closed page as ciphertext; opening the PWA shows the PIN
  screen, and a correct PIN refreshes the session without the identity provider's page. 30 days
  count from the full sign-in; 5 wrong PINs in a row delete the stored session.
- Logout clears the app's memory tokens and tenant pointer but does not end the Keycloak SSO
  session (follow-up).
- Sign-out revokes the refresh token at the realm's revocation endpoint (flag on) and deletes the
  stored session even when that request fails.
- Errors: `invalid_redirect_uri` from Keycloak means step 2 is missing or the base href differs.
  A CORS error on the token call means the Web origin is missing.

Code: `WebAppAuthAdapter`, `TenantTokenStore.production`, `WebPointerKv`.

## Lost or stolen device

Applies to a build with the 30-day sign-in on. Letflow cannot revoke a session in the identity
provider (decision 0072 D1: Letflow holds no Keycloak admin client), and a tenant's first
administrator has no Keycloak admin rights (decision 0072, first-administrator row). So neither
Letflow nor the tenant's administrator can do this; the operator, who holds realm admin, does:

1. The user tells the operator which account lost the device.
2. In the Keycloak admin console, in the tenant realm: Users, the user, **Consents / Sessions**
   (Sessions tab), and **Sign out** / revoke the user's offline sessions (Offline sessions are listed
   per client; remove the `letflow-mobile` offline session). If the account should be locked as well,
   disable the user.
3. At its next unlock the lost device's refresh is answered with `invalid_grant`; the app deletes its
   stored session and shows the sign-in entry.

Until step 2 the remaining limits on the lost device are the six-digit PIN, the limit of 5 wrong PINs
in a row (kept in the browser, see the README's residual risks) and the 30-day maximum.
