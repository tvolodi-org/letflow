import React from 'react'
import ReactDOM from 'react-dom/client'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { RouterProvider } from 'react-router-dom'
import './styles/tokens.css'
import { router } from './router'
import { fetchTenantConfig } from './auth/tenantConfig'
import { registerBuiltinWidgets } from './components/forms/widgets'
import { BrandingProvider } from './theming/BrandingProvider'
import { AuthProvider } from './auth/AuthProvider'
import { AccessProvider } from './auth/access'

// Pre-warm tenant config cache so OIDC config is ready before the first auth redirect.
void fetchTenantConfig(window.location.hostname)

// REQ-284 — populate fieldRegistry with the closed x-ui.widget vocabulary
// before the first render.
registerBuiltinWidgets()

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      retry: 0,
    },
  },
})

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <AccessProvider>
          <BrandingProvider>
            <RouterProvider router={router} />
          </BrandingProvider>
        </AccessProvider>
      </AuthProvider>
    </QueryClientProvider>
  </React.StrictMode>,
)
