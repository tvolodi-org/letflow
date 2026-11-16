// @vitest-environment jsdom
/** Tests for processImageFile, extractPastedImages, extractDroppedImages (T-2015). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { MAX_IMAGE_BYTES, MAX_TOTAL_BYTES, processImageFile, extractPastedImages, extractDroppedImages } from '../images'

// Minimal 1×1 PNG (magic bytes \x89PNG)
const PNG_MAGIC = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])

function makePngFile(size = PNG_MAGIC.length): File {
  const data = new Uint8Array(size)
  data.set(PNG_MAGIC.slice(0, Math.min(8, size)))
  return new File([data], 'test.png', { type: 'image/png' })
}

function makeDataUrl(mime: string, data = 'AAAA'): string {
  return `data:${mime};base64,${data}`
}

beforeEach(() => {
  // Mock URL.createObjectURL / revokeObjectURL
  vi.stubGlobal('URL', {
    ...URL,
    createObjectURL: vi.fn(() => 'blob:mock'),
    revokeObjectURL: vi.fn(),
  })

  // Mock Image loading
  vi.stubGlobal('Image', class {
    naturalWidth = 1
    naturalHeight = 1
    onload: (() => void) | null = null
    onerror: (() => void) | null = null
    set src(_: string) {
      Promise.resolve().then(() => this.onload?.())
    }
  })

  // Mock canvas
  const mockDataUrl = makeDataUrl('image/png', 'iVBORw0KGgo=')
  HTMLCanvasElement.prototype.getContext = vi.fn(() => ({
    drawImage: vi.fn(),
  })) as unknown as typeof HTMLCanvasElement.prototype.getContext
  HTMLCanvasElement.prototype.toDataURL = vi.fn(() => mockDataUrl)
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

describe('processImageFile', () => {
  it('returns a ReportImage for a valid PNG file', async () => {
    const file = makePngFile()
    const result = await processImageFile(file)
    expect(result).not.toBeNull()
    expect(result?.contentType).toBe('image/png')
    expect(result?.name).toBe('test.png')
    expect(result?.dataBase64).toBeTruthy()
    expect(result?.preview).toMatch(/^data:image\/png/)
    expect(result?.size).toBeGreaterThan(0)
  })

  it('returns null for a non-image file (text/plain)', async () => {
    const file = new File(['hello'], 'doc.txt', { type: 'text/plain' })
    const result = await processImageFile(file)
    expect(result).toBeNull()
  })

  it('returns null when the re-encoded result exceeds MAX_IMAGE_BYTES', async () => {
    // toDataURL returns base64; atob length of a large base64 string will be large
    const bigBase64 = 'A'.repeat(MAX_IMAGE_BYTES * 2)
    HTMLCanvasElement.prototype.toDataURL = vi.fn(() => `data:image/png;base64,${bigBase64}`)
    const file = makePngFile()
    const result = await processImageFile(file)
    expect(result).toBeNull()
  })

  it('populates the size field with the decoded byte count', async () => {
    // The mocked toDataURL returns 'iVBORw0KGgo=' (10 base64 chars → 7 bytes)
    const file = makePngFile()
    const result = await processImageFile(file)
    expect(result?.size).toBe(atob('iVBORw0KGgo=').length)
  })
})

describe('MAX_TOTAL_BYTES', () => {
  it('is defined and smaller than 2 MiB (the JSON body cap)', () => {
    // base64 overhead is ~33%; MAX_TOTAL_BYTES * 1.34 + 10 KB JSON must fit under 2 MiB
    expect(MAX_TOTAL_BYTES).toBeLessThan(2 * 1024 * 1024)
  })
})

describe('extractPastedImages', () => {
  it('returns image files from a ClipboardEvent', () => {
    const file = makePngFile()
    const event = { clipboardData: { files: [file] } } as unknown as ClipboardEvent
    expect(extractPastedImages(event)).toEqual([file])
  })

  it('returns empty array for non-image clipboard content', () => {
    const file = new File(['x'], 'x.txt', { type: 'text/plain' })
    const event = { clipboardData: { files: [file] } } as unknown as ClipboardEvent
    expect(extractPastedImages(event)).toEqual([])
  })
})

describe('extractDroppedImages', () => {
  it('returns image files from a DragEvent', () => {
    const file = makePngFile()
    const event = { dataTransfer: { files: [file] } } as unknown as DragEvent
    expect(extractDroppedImages(event)).toEqual([file])
  })

  it('returns empty array when dataTransfer is null', () => {
    const event = { dataTransfer: null } as unknown as DragEvent
    expect(extractDroppedImages(event)).toEqual([])
  })
})
