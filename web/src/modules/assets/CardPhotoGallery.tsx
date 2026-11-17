/** CardPhotoGallery — T-2042 (photos P3). The Photos tab of an asset card: stage images (file button, camera, drop,
 *  paste), upload them one at a time, and manage the stored photos (caption, order, main, delete). Photo calls save at
 *  once and are separate from the card form's Save. Authority is the server's: `can_add` for adding, caption, order
 *  and main; `can_delete` of each photo for Delete; never a role name. Staged images live in this component only:
 *  the page asks before it leaves a card that still has some (`onPendingChange`), and there is no offline queue. */
import { useEffect, useRef, useState } from 'react'
import { useIntl } from 'react-intl'
import { useQueryClient } from '@tanstack/react-query'
import { ArrowLeft, ArrowRight, Star, Trash2 } from 'lucide-react'
import { useAuth } from '@/auth/AuthContext'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { EmptyState } from '@/components/ui/EmptyState'
import { Field } from '@/components/ui/Field'
import { PhotoUploadPicker } from '@/components/ui/PhotoUploadPicker'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { StatusPill } from '@/components/ui/StatusPill'
import { useObjectUrl } from '@/hooks/useObjectUrl'
import { useRemoteQuery } from '@/hooks/useRemoteQuery'
import { preparePhoto, type PrepareFailure } from '@/lib/photos/preparePhoto'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { assetsApi } from './assets.api'
import { assetsQueryKeys } from './assetsQueryKeys'
import { CardPhotoImage } from './CardPhotoImage'
import { codePoints, inOrder, photoErrorId, type CardPhoto, type CardPhotoList, type StagedPhoto } from './cardPhotosModel'

const LOCAL_ERROR: Record<PrepareFailure, string> = {
  type: 'assets.photos.error.local_type',
  decode: 'assets.photos.error.local_decode',
  encode: 'assets.photos.error.local_decode',
  too_large: 'assets.photos.error.photo_too_large',
}

let stagedCounter = 0

function StagedTile(props: { item: StagedPhoto; busy: boolean; onRemove: () => void; onRetry: () => void }) {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string>) => intl.formatMessage({ id }, values)
  const { item } = props
  const url = useObjectUrl(item.thumbnail)
  return (
    <li className="lf-staged" data-state={item.state} data-testid="photo-staged">
      {url !== null ? <img className="lf-staged__img" src={url} alt="" /> : <span className="lf-staged__img lf-photo__ph" aria-hidden="true" />}
      <span className="lf-staged__body">
        <span className="lf-staged__name">{item.label}</span>
        <span className="caption lf-faint" role={item.state === 'failed' ? 'alert' : undefined}>
          {item.state === 'failed' && item.errorId ? t(item.errorId) : t(`assets.photos.staged.${item.state}`)}
        </span>
      </span>
      <span className="lf-btn-row">
        {item.state === 'failed' && item.original ? (
          <Button variant="secondary" size="sm" disabled={props.busy} onClick={props.onRetry} data-testid="photo-retry">
            {t('assets.photos.retry')}
          </Button>
        ) : null}
        <Button variant="ghost" size="sm" disabled={item.state === 'uploading'} onClick={props.onRemove} data-testid="photo-staged-remove" aria-describedby={undefined}>
          {t('assets.photos.removeStaged')}
        </Button>
      </span>
    </li>
  )
}

export function CardPhotoGallery(props: {
  cardId: string
  /** number of staged images that are not stored yet */
  onPendingChange?: (count: number) => void
  /** true while a dialog of the gallery is open (the page lets Escape close the dialog, not the card) */
  onModalChange?: (open: boolean) => void
}) {
  const { cardId } = props
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id }, values)
  const { session } = useAuth()
  const qc = useQueryClient()
  const key = assetsQueryKeys.cardPhotos(session?.tenant_id ?? '', cardId)
  const query = useRemoteQuery<CardPhotoList>(key, () => assetsApi.listCardPhotos(cardId))
  const data = query.data
  const photos = inOrder(data?.photos ?? [])
  const state: RendererState = query.isError ? classifyError(query.error) : query.isPending ? 'loading' : 'success'

  const [staged, setStaged] = useState<StagedPhoto[]>([])
  const [notice, setNotice] = useState<string | null>(null)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [captionDraft, setCaptionDraft] = useState<string | null>(null)
  const [captionError, setCaptionError] = useState<string | null>(null)
  const [deleting, setDeleting] = useState<CardPhoto | null>(null)
  const uploading = useRef(false)
  const limits = data?.limits

  useEffect(() => {
    props.onPendingChange?.(staged.length)
  }, [staged.length]) // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    props.onModalChange?.(deleting !== null)
  }, [deleting]) // eslint-disable-line react-hooks/exhaustive-deps

  const patchStaged = (k: string, p: Partial<StagedPhoto>) => setStaged((all) => all.map((s) => (s.key === k ? { ...s, ...p } : s)))

  async function addFiles(files: File[]) {
    if (!limits) return
    setNotice(null)
    const remaining = Math.max(0, limits.max_photos - photos.length - staged.length)
    const take = files.slice(0, remaining)
    if (files.length > take.length) setNotice(t('assets.photos.capRefused', { count: files.length - take.length, max: limits.max_photos }))
    const items: StagedPhoto[] = take.map((f) => ({ key: `s${++stagedCounter}`, label: f.name || t('assets.photos.unnamed'), state: 'preparing' }))
    setStaged((all) => [...all, ...items])
    await Promise.all(
      take.map(async (file, i) => {
        const res = await preparePhoto(file, limits)
        if (res.ok) patchStaged(items[i].key, { state: 'ready', original: res.original, thumbnail: res.thumbnail })
        else patchStaged(items[i].key, { state: 'failed', errorId: LOCAL_ERROR[res.reason] })
      }),
    )
  }

  /** Sends the given items one after another; a refusal stops the queue and the rest stay for another try. */
  async function sendAll(items: StagedPhoto[]) {
    if (uploading.current) return
    uploading.current = true
    setBusy(true)
    setError(null)
    try {
      for (const item of items) {
        if (!item.original || !item.thumbnail) continue
        patchStaged(item.key, { state: 'uploading', errorId: undefined })
        try {
          await assetsApi.uploadCardPhoto(cardId, item.original, item.thumbnail, '')
          setStaged((all) => all.filter((s) => s.key !== item.key))
          await qc.invalidateQueries({ queryKey: key })
        } catch (err) {
          patchStaged(item.key, { state: 'failed', errorId: photoErrorId(err) })
          break
        }
      }
    } finally {
      uploading.current = false
      setBusy(false)
    }
  }

  async function run(action: () => Promise<void>) {
    setBusy(true)
    setError(null)
    try {
      await action()
    } catch (err) {
      setError(photoErrorId(err))
    } finally {
      setBusy(false)
    }
  }

  const current = photos.find((p) => p.id === selectedId) ?? photos[0] ?? null
  const index = current ? photos.findIndex((p) => p.id === current.id) : -1
  const canAdd = data?.can_add === true
  const full = limits ? photos.length + staged.length >= limits.max_photos : false
  const mutable = canAdd && current !== null && !current.locked
  const readyItems = staged.filter((s) => s.state === 'ready')
  const draft = captionDraft ?? current?.caption ?? ''
  const captionDirty = current !== null && draft.trim() !== (current.caption ?? '')

  function choose(id: string) {
    setSelectedId(id)
    setCaptionDraft(null)
    setCaptionError(null)
    setError(null)
  }

  async function saveCaption() {
    if (!current || !limits) return
    const text = draft.trim()
    if (codePoints(text) > limits.caption_max) {
      setCaptionError(t('assets.photos.captionTooLong', { max: limits.caption_max }))
      return
    }
    setCaptionError(null)
    setBusy(true)
    setError(null)
    try {
      await assetsApi.setCardPhotoCaption(cardId, current.id, text)
      setCaptionDraft(null)
      await qc.invalidateQueries({ queryKey: key })
    } catch (err) {
      const id = photoErrorId(err)
      if (id === 'assets.photos.error.caption_invalid') setCaptionError(t(id))
      else setError(id)
    } finally {
      setBusy(false)
    }
  }

  const move = (delta: number) =>
    run(async () => {
      const ids = photos.map((p) => p.id)
      const to = index + delta
      if (index < 0 || to < 0 || to >= ids.length) return
      ;[ids[index], ids[to]] = [ids[to], ids[index]]
      const list = await assetsApi.orderCardPhotos(cardId, ids)
      qc.setQueryData(key, list)
    })

  const makeMain = () =>
    run(async () => {
      if (!current) return
      await assetsApi.setCardPhotoMain(cardId, current.id)
      await qc.invalidateQueries({ queryKey: key })
    })

  async function confirmDelete() {
    const target = deleting
    if (!target) return
    setBusy(true)
    setError(null)
    try {
      await assetsApi.deleteCardPhoto(cardId, target.id)
      const at = photos.findIndex((p) => p.id === target.id)
      const next = photos[at + 1] ?? photos[at - 1] ?? null
      setSelectedId(next ? next.id : null)
      setCaptionDraft(null)
      for (const kind of ['original', 'thumbnail'] as const) {
        qc.removeQueries({ queryKey: assetsQueryKeys.cardPhotoContent(session?.tenant_id ?? '', cardId, target.id, kind) })
      }
      setDeleting(null)
      await qc.invalidateQueries({ queryKey: key })
    } catch (err) {
      setError(photoErrorId(err))
    } finally {
      setBusy(false)
    }
  }

  const errorText = error ? t(error) : null
  const missing = query.isError && (query.error as { status?: number } | null)?.status === 404

  return (
    <section className="lf-form__section lf-photos" data-testid="card-photos">
      <h3 className="lf-form__title">{t('assets.photos.title')}</h3>
      {missing ? (
        <Banner tone="warning">{t('assets.photos.unavailable')}</Banner>
      ) : (
        <QueryStateBoundary state={state} onRetry={() => void query.refetch()}>
          {limits ? (
            <>
              <p className="caption lf-faint">{t('assets.photos.limits', { max: limits.max_photos })}</p>
              {canAdd ? (
                <PhotoUploadPicker
                  labels={{ choose: t('assets.photos.choose'), take: t('assets.photos.take'), drop: t('assets.photos.drop'), target: t('assets.photos.target') }}
                  onFiles={(files) => void addFiles(files)}
                  disabled={full}
                  disabledReason={t('assets.photos.capReached', { count: photos.length + staged.length, max: limits.max_photos })}
                />
              ) : (
                <Banner tone="info">{t('assets.photos.readOnly')}</Banner>
              )}
              {notice ? <Banner tone="warning">{notice}</Banner> : null}
              {staged.length > 0 ? (
                <div className="lf-photos__staged" data-testid="photo-staging">
                  <h4 className="lf-form__title">{t('assets.photos.staged.title')}</h4>
                  <ul className="lf-staged-list">
                    {staged.map((s) => (
                      <StagedTile key={s.key} item={s} busy={busy} onRemove={() => setStaged((all) => all.filter((x) => x.key !== s.key))} onRetry={() => void sendAll([s])} />
                    ))}
                  </ul>
                  <div className="lf-btn-row">
                    <Button variant="primary" size="md" loading={busy} disabled={busy || readyItems.length === 0} onClick={() => void sendAll(readyItems)} data-testid="photo-upload">
                      {t('assets.photos.upload', { count: readyItems.length })}
                    </Button>
                  </div>
                </div>
              ) : null}
              {errorText && deleting === null ? (
                <Banner tone="danger">
                  <span data-testid="photo-error">{errorText}</span>
                </Banner>
              ) : null}
              {photos.length === 0 ? (
                <EmptyState title={t('assets.photos.empty.title')} text={t('assets.photos.empty.text')} data-testid="photos-empty" />
              ) : (
                <>
                  <ul className="lf-photo-grid" aria-label={t('assets.photos.stored')}>
                    {photos.map((p, i) => (
                      <li key={p.id}>
                        <button
                          type="button"
                          className="lf-photo-tile"
                          aria-pressed={current?.id === p.id}
                          aria-label={t('assets.photos.tile', { position: i + 1, total: photos.length })}
                          onClick={() => choose(p.id)}
                          data-testid={`photo-tile-${p.id}`}
                        >
                          {p.has_thumbnail ? <CardPhotoImage cardId={cardId} photoId={p.id} kind="thumbnail" alt="" className="lf-photo-tile__img" /> : <span className="lf-photo-tile__img lf-photo__ph" aria-hidden="true" />}
                          {p.is_main ? (
                            <span className="lf-photo-tile__main" aria-hidden="true">
                              <Star className="lf-icon" />
                            </span>
                          ) : null}
                        </button>
                      </li>
                    ))}
                  </ul>
                  {current ? (
                    <div className="lf-photo-view" data-testid="photo-view">
                      <CardPhotoImage key={current.id} cardId={cardId} photoId={current.id} kind="original" alt={current.caption || t('assets.photos.altDefault', { position: index + 1 })} className="lf-photo-view__img" />
                      <div className="lf-photo-view__side">
                        <div className="lf-btn-row">
                          <span className="caption lf-faint">{t('assets.photos.tile', { position: index + 1, total: photos.length })}</span>
                          {current.is_main ? (
                            <StatusPill tone="success" glyph="dot">
                              {t('assets.photos.main')}
                            </StatusPill>
                          ) : null}
                        </div>
                        {current.locked ? <Banner tone="info">{t('assets.photos.locked')}</Banner> : null}
                        {mutable ? (
                          <>
                            <Field label={t('assets.photos.caption')} optional hint={t('assets.photos.captionCount', { count: codePoints(draft), max: limits.caption_max })} error={captionError ?? undefined}>
                              <textarea name="photo_caption" rows={2} value={draft} onChange={(e) => { setCaptionDraft(e.target.value); setCaptionError(null) }} />
                            </Field>
                            <div className="lf-btn-row">
                              <Button variant="primary" size="sm" disabled={busy || !captionDirty} onClick={() => void saveCaption()} data-testid="photo-caption-save">
                                {t('assets.photos.captionSave')}
                              </Button>
                              {captionDirty ? (
                                <Button variant="ghost" size="sm" onClick={() => { setCaptionDraft(null); setCaptionError(null) }}>
                                  {t('assets.common.cancel')}
                                </Button>
                              ) : null}
                            </div>
                            <div className="lf-btn-row">
                              <Button variant="secondary" size="sm" icon={<ArrowLeft className="lf-icon" aria-hidden="true" />} disabled={busy || index <= 0} onClick={() => void move(-1)} data-testid="photo-earlier">
                                {t('assets.photos.moveEarlier')}
                              </Button>
                              <Button variant="secondary" size="sm" icon={<ArrowRight className="lf-icon" aria-hidden="true" />} disabled={busy || index >= photos.length - 1} onClick={() => void move(1)} data-testid="photo-later">
                                {t('assets.photos.moveLater')}
                              </Button>
                              {!current.is_main ? (
                                <Button variant="secondary" size="sm" icon={<Star className="lf-icon" aria-hidden="true" />} disabled={busy} onClick={() => void makeMain()} data-testid="photo-make-main">
                                  {t('assets.photos.makeMain')}
                                </Button>
                              ) : null}
                            </div>
                          </>
                        ) : current.caption ? (
                          <p className="lf-photo-view__caption" data-testid="photo-caption-read">
                            {current.caption}
                          </p>
                        ) : null}
                        {current.can_delete && !current.locked ? (
                          <div className="lf-btn-row">
                            <Button variant="danger" size="sm" icon={<Trash2 className="lf-icon" aria-hidden="true" />} disabled={busy} onClick={() => setDeleting(current)} data-testid="photo-delete">
                              {t('assets.photos.delete')}
                            </Button>
                          </div>
                        ) : null}
                      </div>
                    </div>
                  ) : null}
                </>
              )}
            </>
          ) : null}
        </QueryStateBoundary>
      )}
      <ConfirmDialog
        open={deleting !== null}
        title={t('assets.photos.deleteTitle')}
        body={t('assets.photos.deleteBody')}
        confirmText={t('assets.photos.deleteConfirm')}
        cancelText={t('assets.common.cancel')}
        confirmVariant="danger"
        isLoading={busy}
        error={deleting !== null && errorText ? errorText : null}
        onConfirm={() => void confirmDelete()}
        onCancel={() => { setDeleting(null); setError(null) }}
      />
    </section>
  )
}
