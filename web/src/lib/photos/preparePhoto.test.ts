// @vitest-environment jsdom
/** P3-I1..I4 — T-2042: geometry, decoder and encoder options, caps and failures. jsdom has no canvas or EXIF, so the
 *  browser primitives are faked; real orientation and HEIC decoding are checked in the QA browser walk. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { fitWithin, isAcceptedImage, preparePhoto, type PhotoCaps } from './preparePhoto'

const CAPS: PhotoCaps = { original_max_bytes: 1000, original_max_px: 4096, thumbnail_max_bytes: 100, thumbnail_max_px: 512 }

interface Draw { w: number; h: number }
let draws: Draw[]
let quality: unknown[]
let sizes: number[]

function fakeCanvas(blobFor: (call: number) => Blob | null) {
  let call = 0
  const real = document.createElement.bind(document)
  vi.spyOn(document, 'createElement').mockImplementation((tag: string) => {
    if (tag !== 'canvas') return real(tag)
    const canvas = { width: 0, height: 0 } as unknown as HTMLCanvasElement
    canvas.getContext = (() => ({ fillStyle: '', fillRect: () => undefined, drawImage: (_s: unknown, _x: number, _y: number, w: number, h: number) => draws.push({ w, h }) })) as never
    canvas.toBlob = ((cb: BlobCallback, type?: string, q?: unknown) => {
      quality.push([type, q])
      cb(blobFor(call++))
    }) as never
    return canvas
  })
}
const file = (type = 'image/jpeg', name = 'a.jpg') => new File(['x'], name, { type })

beforeEach(() => {
  draws = []
  quality = []
  sizes = []
  vi.stubGlobal('createImageBitmap', vi.fn(async () => ({ width: 4000, height: 3000, close: vi.fn() })))
})
afterEach(() => {
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
})

describe('P3-I1 geometry', () => {
  it('fits the long edge, keeps the ratio, never enlarges', () => {
    expect(fitWithin(4000, 3000, 2048)).toEqual({ width: 2048, height: 1536 })
    expect(fitWithin(3000, 4000, 320)).toEqual({ width: 240, height: 320 })
    expect(fitWithin(800, 600, 2048)).toEqual({ width: 800, height: 600 })
    expect(fitWithin(10000, 1, 320)).toEqual({ width: 320, height: 1 })
  })
  it('accepts jpeg png webp heic, refuses gif and svg', () => {
    expect(isAcceptedImage({ type: 'image/png', name: 'a' })).toBe(true)
    expect(isAcceptedImage({ type: '', name: 'IMG_1.HEIC' })).toBe(true)
    expect(isAcceptedImage({ type: 'image/gif', name: 'a.gif' })).toBe(false)
    expect(isAcceptedImage({ type: 'image/svg+xml', name: 'a.svg' })).toBe(false)
  })
})

describe('P3-I2 decode and encode', () => {
  it('decodes with the image orientation and encodes original 2048 and thumbnail 320 as JPEG 0.85', async () => {
    fakeCanvas(() => new Blob(['j']))
    const res = await preparePhoto(file(), CAPS)
    expect(res.ok).toBe(true)
    expect(createImageBitmap).toHaveBeenCalledWith(expect.any(File), { imageOrientation: 'from-image' })
    expect(draws).toEqual([{ w: 2048, h: 1536 }, { w: 320, h: 240 }])
    expect(quality).toEqual([['image/jpeg', 0.85], ['image/jpeg', 0.85]])
  })
  it('honours smaller server pixel caps', async () => {
    fakeCanvas(() => new Blob(['j']))
    await preparePhoto(file(), { ...CAPS, original_max_px: 1000, thumbnail_max_px: 100 })
    expect(draws).toEqual([{ w: 1000, h: 750 }, { w: 100, h: 75 }])
  })
})

describe('P3-I3 caps', () => {
  it('fails locally when the encoded original is over the byte cap', async () => {
    fakeCanvas((i) => new Blob([i === 0 ? 'x'.repeat(2000) : 'y']))
    expect(await preparePhoto(file(), CAPS)).toEqual({ ok: false, reason: 'too_large' })
  })
  it('fails locally when the thumbnail is over its cap', async () => {
    fakeCanvas((i) => new Blob([i === 0 ? 'x' : 'y'.repeat(500)]))
    expect(await preparePhoto(file(), CAPS)).toEqual({ ok: false, reason: 'too_large' })
  })
})

describe('P3-I4 failures', () => {
  it('reports an unsupported type, a decode failure and a null blob', async () => {
    expect(await preparePhoto(file('image/gif', 'a.gif'), CAPS)).toEqual({ ok: false, reason: 'type' })
    vi.stubGlobal('createImageBitmap', vi.fn(async () => { throw new Error('bad') }))
    expect(await preparePhoto(file(), CAPS)).toEqual({ ok: false, reason: 'decode' })
    vi.stubGlobal('createImageBitmap', vi.fn(async () => ({ width: 10, height: 10, close: vi.fn() })))
    fakeCanvas(() => null)
    expect(await preparePhoto(file(), CAPS)).toEqual({ ok: false, reason: 'encode' })
    expect(sizes).toEqual([])
  })
})
