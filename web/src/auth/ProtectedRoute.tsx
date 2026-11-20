/** Protected route — redirects unauthenticated users to Keycloak via OIDC */

import type { ReactNode } from 'react'
import { useEffect, useState } from 'react'
import { Navigate } from 'react-router-dom'
import { useAuth } from './AuthContext'
import { getOidcManager } from './OidcManager'
import { buildRedirectArgs } from './oidcRedirectArgs'
import { isEmailFirstLoginEnabled } from './emailFirstFlag'
import { clearRealmSlug, isCompanyCodeUnknown, resolveRealmFromUrl } from './tenantConfig'
import { CompanyNotFound } from './CompanyNotFound'

export function ProtectedRoute({ children }: { children: ReactNode }) {
  const { isAuthenticated, isLoading } = useAuth()
  const [redirecting, setRedirecting] = useState(false)
  const [companyUnknown, setCompanyUnknown] = useState(false)

  // REQ-438 precedence (design req434 section 11): (1) explicit ?realm=,
  // (2) stored bpm_realm_slug -- both resolved, in that order, by
  // resolveRealmFromUrl(); (3) the email-first screen when the build flag is
  // on; (4) otherwise today's default-realm redirect. With the flag off this
  // is false and nothing below changes.
  const needsEmailFirst =
    !isLoading && !isAuthenticated && isEmailFirstLoginEnabled() && resolveRealmFromUrl() === null

  useEffect(() => {
    if (!isLoading && !isAuthenticated && !redirecting && !needsEmailFirst) {
      setRedirecting(true)
      const go = () =>
        getOidcManager().then(m => {
          void m.signinRedirect(
            buildRedirectArgs(window.location.pathname + window.location.search),
          )
        })
      // T-2350: an explicit company code that names no company never reaches the identity provider.
      const slug = resolveRealmFromUrl()
      if (slug === null) {
        void go()
      } else {
        void isCompanyCodeUnknown(slug).then(unknown => {
          if (unknown) {
            clearRealmSlug()
            setCompanyUnknown(true)
          } else {
            void go()
          }
        })
      }
    }
  }, [isLoading, isAuthenticated, redirecting, needsEmailFirst])

  if (needsEmailFirst) {
    // The pre-redirect path rides in router state; LoginPage hands it to
    // buildRedirectArgs, which drops it unless isSafeRestorePath accepts it.
    return (
      <Navigate
        to="/login"
        replace
        state={{ from: window.location.pathname + window.location.search }}
      />
    )
  }

  if (companyUnknown) return <CompanyNotFound />

  if (isLoading || redirecting) {
    return (
      <div
        style={{ display: 'flex', justifyContent: 'center', alignItems: 'center', height: '100vh' }}
        data-testid="auth-loading"
      >
        Redirecting to login…
      </div>
    )
  }

  if (!isAuthenticated) {
    return null
  }

  return <>{children}</>
}
