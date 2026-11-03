import { useTenantContext } from '@/auth/useTenantContext'

export function TenantHeader(): JSX.Element {
  const { tenantDisplayName, isUnknown } = useTenantContext()

  return (
    <div
      className="lf-sidenav__ws"
      data-testid={isUnknown ? 'tenant-display-name-unknown' : 'tenant-display-name'}
      title={tenantDisplayName}
    >
      {tenantDisplayName}
    </div>
  )
}
