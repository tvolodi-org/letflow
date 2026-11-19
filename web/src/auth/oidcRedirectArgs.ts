import { resolveRealmFromUrl } from './tenantConfig'
import { isSafeRestorePath } from './safeRestorePath'

/**
 * Builds signinRedirect args that embed the current tenant realm slug in the
 * redirect_uri so that OidcCallbackPage can identify the realm without relying
 * on sessionStorage state alone, and optionally captures the pre-redirect path
 * (via oidc-client-ts's `state` option) so it can be restored after the OIDC
 * round trip completes.
 *
 * `capturePath`, when provided and validated safe by `isSafeRestorePath`, is
 * carried as `state` — oidc-client-ts persists it in its stateStore across the
 * full-page navigation to Keycloak and back, and it is available as `user.state`
 * once `signinRedirectCallback()` resolves. An unsafe or omitted `capturePath`
 * results in `state` being omitted entirely from the returned object (not set
 * to `undefined` explicitly) — see
 * lib/letflow/design/iss-0726-oidc-redirect-path-restore.md §2.3.
 *
 * `options.loginHint` (REQ-438, design req434 section 8.1), when a non-empty string,
 * is returned as `login_hint` so Keycloak pre-fills the username field with the
 * address typed on the email-first page. It is omitted entirely otherwise, so
 * existing callers' results are unchanged.
 *
 * Returns `{ redirect_uri, state?, login_hint? }` when a realm slug is resolvable, or
 * `undefined` to let the UserManager use its configured default redirect_uri.
 */
export function buildRedirectArgs(
  capturePath?: string,
  options?: { loginHint?: string },
): { redirect_uri?: string; state?: string; login_hint?: string } | undefined {
  const slug = resolveRealmFromUrl()
  if (!slug) {
    // Default realm: keep UserManager's configured redirect_uri but still carry the
    // requested inner path (T-2241), so a reload or typed address returns to it.
    // '/' is the default landing anyway, so it stays "no args".
    if (capturePath !== undefined && capturePath !== '/' && isSafeRestorePath(capturePath)) {
      return { state: capturePath }
    }
    return undefined
  }

  const redirect_uri =
    window.location.origin + '/auth/callback?realm=' + encodeURIComponent(slug)

  const args: { redirect_uri?: string; state?: string; login_hint?: string } = { redirect_uri }
  if (capturePath !== undefined && isSafeRestorePath(capturePath)) {
    args.state = capturePath
  }
  if (options?.loginHint) {
    args.login_hint = options.loginHint
  }
  return args
}
