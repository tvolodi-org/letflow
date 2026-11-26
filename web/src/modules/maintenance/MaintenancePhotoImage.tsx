/** MaintenancePhotoImage — GH 4802 / REQ-898. One stored photo of a request as an image: the bytes are read with
 *  the authenticated client (a raw backend URL carries no bearer token), the Blob is cached by the query layer and
 *  the object URL is made and revoked by `useObjectUrl`. While the bytes load, or when they cannot be read, a
 *  placeholder box with a translated label is shown. */
import { useIntl } from 'react-intl'
import { useAuth } from '@/auth/AuthContext'
import { useObjectUrl } from '@/hooks/useObjectUrl'
import { useRemoteQuery } from '@/hooks/useRemoteQuery'
import { maintenanceApi } from './maintenance.api'
import { maintenanceQueryKeys } from './maintenanceQueryKeys'

export function MaintenancePhotoImage(props: {
  requestId: string
  photoId: string
  kind: 'original' | 'thumbnail'
  /** empty for a decorative image */
  alt: string
  className?: string
  enabled?: boolean
}) {
  const intl = useIntl()
  const { session } = useAuth()
  const query = useRemoteQuery(
    maintenanceQueryKeys.photos(session?.tenant_id ?? '', `${props.requestId}/${props.photoId}/${props.kind}`),
    async () => {
      const res = await maintenanceApi.photoContent(props.requestId, props.photoId, props.kind)
      if (!res.contentType.toLowerCase().startsWith('image/')) throw new Error('not an image')
      return res.blob
    },
    props.enabled ?? true,
  )
  const url = useObjectUrl(query.data)
  const cls = props.className ?? 'lf-photo__img'
  if (url !== null) return <img className={cls} src={url} alt={props.alt} />
  const failed = query.isError
  return (
    <span
      className={`${cls} lf-photo__ph${failed ? ' lf-photo__ph--failed' : ''}`}
      role="img"
      aria-label={props.alt === '' ? undefined : intl.formatMessage({ id: failed ? 'maintenance.photos.error.generic' : 'maintenance.common.loading' })}
      aria-hidden={props.alt === '' ? true : undefined}
      data-testid={failed ? 'photo-failed' : 'photo-loading'}
    />
  )
}
