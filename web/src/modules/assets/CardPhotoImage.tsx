/** CardPhotoImage — T-2042 (photos P3). One stored photo as an image: the bytes are read with the authenticated
 *  client (a raw backend URL has no bearer token), the Blob is cached by the query layer, and the object URL is made
 *  and revoked by `useObjectUrl`. Original and thumbnail URLs are built only from the card and photo ids. While the
 *  bytes load, or when they cannot be read, a placeholder box with a translated label is shown. */
import { useIntl } from 'react-intl'
import { useAuth } from '@/auth/AuthContext'
import { useObjectUrl } from '@/hooks/useObjectUrl'
import { useRemoteQuery } from '@/hooks/useRemoteQuery'
import { assetsApi } from './assets.api'
import { assetsQueryKeys } from './assetsQueryKeys'

export function CardPhotoImage(props: {
  cardId: string
  photoId: string
  kind: 'original' | 'thumbnail'
  /** empty for a decorative image */
  alt: string
  className?: string
  enabled?: boolean
}) {
  const { cardId, photoId, kind, alt, enabled = true } = props
  const intl = useIntl()
  const { session } = useAuth()
  const query = useRemoteQuery(
    assetsQueryKeys.cardPhotoContent(session?.tenant_id ?? '', cardId, photoId, kind),
    async () => {
      const res = await assetsApi.cardPhotoContent(cardId, photoId, kind)
      if (!res.contentType.toLowerCase().startsWith('image/')) throw new Error('not an image')
      return res.blob
    },
    enabled,
  )
  const url = useObjectUrl(query.data)
  const cls = props.className ?? 'lf-photo__img'
  if (url !== null) return <img className={cls} src={url} alt={alt} />
  const failed = query.isError
  return (
    <span className={`${cls} lf-photo__ph${failed ? ' lf-photo__ph--failed' : ''}`} role="img" aria-label={alt === '' ? undefined : intl.formatMessage({ id: failed ? 'assets.photos.imageFailed' : 'assets.photos.imageLoading' })} aria-hidden={alt === '' ? true : undefined} data-testid={failed ? 'photo-failed' : 'photo-loading'} />
  )
}
