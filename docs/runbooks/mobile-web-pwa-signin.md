# Mobile PWA sign-in: Keycloak setup per environment

Applies to the web build of `apps/mobile` (PWA M2, plan D-112). The native app signs in with the
fixed redirect `com.bizdala.letflow:/oauth2redirect`. The PWA signs in with a browser redirect
back to its own page, so each environment needs one more registered URI.

The shared realm template (`priv/keycloak/realms/bpm-default.json`) is **not** changed: its tests
pin the native redirect as the only entry (no http(s), no wildcard), and the PWA host differs per
environment. Adding the URI is a manual infra step; automating it in the provisioner is a follow-up.

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
4. Check: open the PWA, enter the tenant slug, sign in; the browser returns to the PWA URL and
   the address bar shows no `code`/`state` afterwards.

## Behaviour to know

- Tokens are kept in memory only (see `apps/mobile/README.md`, "Web sign-in (M2)"). A reload signs
  in again through Keycloak, silently while the SSO session lives.
- Logout clears the app's memory tokens and tenant pointer but does not end the Keycloak SSO
  session (follow-up).
- Errors: `invalid_redirect_uri` from Keycloak means step 2 is missing or the base href differs.
  A CORS error on the token call means the Web origin is missing.

Code: `WebAppAuthAdapter`, `TenantTokenStore.production`, `WebPointerKv`.
