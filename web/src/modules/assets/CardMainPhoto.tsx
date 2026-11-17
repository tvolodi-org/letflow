/** CardMainPhoto — T-2042 (photos P3). The main-photo thumbnail in a row of the card list. The list answer has no
 *  main-photo id and there is no batch route, so each row asks for its own gallery metadata, but only once the row
 *  comes near the viewport (IntersectionObserver); a page of 100 rows therefore does not start 100 reads. Only the
 *  main photo's thumbnail is read, and only when the server says it has one: the original is never a substitute. A
 *  card without a main thumbnail, or one whose photos cannot be read, shows a placeholder. The metadata query is the
 *  same cache entry the gallery of the open card uses. */
import { useEffect, useRef, useState } from 'react'
import { useIntl } from 'react-intl'
import { ImageOff } from 'lucide-react'
import { useAccess } from '@/auth/access/useAccess'
import { useAuth } from '@/auth/AuthContext'
import { useRemoteQuery } from '@/hooks/useRemoteQuery'
import { assetsApi } from './assets.api'
import { CardPhotoImage } from './CardPhotoImage'
import { mainThumbnail } from './cardPhotosModel'
import { ASSETS_READ } from './assetsPermissions'
import { assetsQueryKeys } from './assetsQueryKeys'

/** True once the element has come within a screen of the viewport; stays true. Without the browser API it is true. */
function useNearViewport(): [React.RefObject<HTMLSpanElement>, boolean] {
  const ref = useRef<HTMLSpanElement>(null)
  const [near, setNear] = useState(typeof IntersectionObserver === 'undefined')
  useEffect(() => {
    const el = ref.current
    if (near || el === null) return
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) {
          setNear(true)
          observer.disconnect()
        }
      },
      { rootMargin: '200px' },
    )
    observer.observe(el)
    return () => observer.disconnect()
  }, [near])
  return [ref, near]
}

export function CardMainPhoto({ cardId }: { cardId: string }) {
  const intl = useIntl()
  const { can } = useAccess()
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const [ref, near] = useNearViewport()
  const query = useRemoteQuery(
    assetsQueryKeys.cardPhotos(tenantId, cardId),
    () => assetsApi.listCardPhotos(cardId),
    near && can(ASSETS_READ),
  )
  const main = mainThumbnail(query.data)
  return (
    <span className="lf-photo-thumb" ref={ref} data-testid={`card-main-photo-${cardId}`}>
      {main !== null ? (
        <CardPhotoImage cardId={cardId} photoId={main.id} kind="thumbnail" alt="" className="lf-photo-thumb__img" />
      ) : (
        <span className="lf-photo-thumb__img lf-photo__ph" role="img" aria-label={intl.formatMessage({ id: 'assets.photos.noMain' })} data-testid="card-main-photo-none">
          <ImageOff className="lf-icon" aria-hidden="true" />
        </span>
      )}
    </span>
  )
}
