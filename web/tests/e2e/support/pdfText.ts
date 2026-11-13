/**
 * T-1912: TypeScript port of the Elixir `PdfProbe.items/1` in
 * `test/letflow/modules/stock/count_print_probe.exs`. Reads the text items from a PDF
 * produced by the FormPrint engine (Prawn-based). The CMap is in object 8; content streams
 * are even-numbered objects with index >= 10.
 *
 * Uses only Node.js built-ins (`node:zlib`) — no new dependency.
 */
import { inflateSync } from 'node:zlib'

interface Stream {
  n: number
  text: string
}

function streams(buf: Buffer): Stream[] {
  const src = buf.toString('binary')
  const result: Stream[] = []
  const objRe = /(\d+) 0 obj\n<< ([^>]*)>>\nstream\n/g
  let m: RegExpExecArray | null
  while ((m = objRe.exec(src)) !== null) {
    const n = parseInt(m[1], 10)
    const header = m[2]
    const dataStart = m.index + m[0].length
    const lenMatch = /\/Length (\d+)/.exec(header)
    if (!lenMatch) continue
    const len = parseInt(lenMatch[1], 10)
    try {
      const compressed = buf.subarray(dataStart, dataStart + len)
      const text = inflateSync(compressed).toString('binary')
      result.push({ n, text })
    } catch {
      // skip non-deflate streams
    }
  }
  return result
}

function buildCmap(cmapText: string): Map<number, string> {
  const map = new Map<number, string>()
  const re = /<([0-9A-F]{4})> <([0-9A-F]+)>/g
  let m: RegExpExecArray | null
  while ((m = re.exec(cmapText)) !== null) {
    const cid = parseInt(m[1], 16)
    const hex = m[2]
    // decode UTF-16 BE
    const bytes = Buffer.from(hex, 'hex')
    map.set(cid, bytes.toString('utf16le').split('').map((_, i, a) =>
      i % 2 === 0 ? String.fromCharCode(a[i].charCodeAt(0) * 256 + (a[i + 1]?.charCodeAt(0) ?? 0)) : ''
    ).join(''))
  }
  // simpler: iterate pairs of bytes
  map.clear()
  const re2 = /<([0-9A-F]{4})> <([0-9A-F]+)>/g
  while ((m = re2.exec(cmapText)) !== null) {
    const cid = parseInt(m[1], 16)
    const hexStr = m[2]
    // convert hex pairs to unicode string (UTF-16 BE)
    let str = ''
    for (let i = 0; i < hexStr.length; i += 4) {
      const code = parseInt(hexStr.slice(i, i + 4), 16)
      str += String.fromCharCode(code)
    }
    map.set(cid, str)
  }
  return map
}

/**
 * Returns the text items from a PDF buffer in page order.
 * Each item is one BT…ET block decoded through the CMap.
 */
export function pdfTextItems(buf: Buffer): string[] {
  const all = streams(buf)

  // Find the CMap stream: object 8, or fallback: search for /CMapName
  let cmapStream = all.find(s => s.n === 8)
  if (!cmapStream) {
    cmapStream = all.find(s => s.text.includes('/CMapName'))
  }
  if (!cmapStream) return []

  const cmap = buildCmap(cmapStream.text)

  // Content streams: even-numbered objects with n >= 10
  return all
    .filter(s => s.n >= 10 && s.n % 2 === 0)
    .sort((a, b) => a.n - b.n)
    .flatMap(s => {
      const items: string[] = []
      const btEtRe = /BT\n([\s\S]*?)ET\n/g
      let m: RegExpExecArray | null
      while ((m = btEtRe.exec(s.text)) !== null) {
        const block = m[1]
        let decoded = ''
        const tjRe = /<([0-9A-F]*)> Tj/g
        let tj: RegExpExecArray | null
        while ((tj = tjRe.exec(block)) !== null) {
          const hex = tj[1]
          for (let i = 0; i < hex.length; i += 4) {
            const cid = parseInt(hex.slice(i, i + 4), 16)
            decoded += cmap.get(cid) ?? ''
          }
        }
        if (decoded) items.push(decoded)
      }
      return items
    })
}
