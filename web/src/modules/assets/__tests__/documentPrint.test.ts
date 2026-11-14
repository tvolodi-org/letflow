/** W1 — T-1915: the print policy and the refusal messages of the asset document screen. */
import { describe, expect, it } from 'vitest'
import { DOC_KINDS, DOC_STATES, documentPrintable, printErrorMessageId } from '../documents/documentsModel'

const refusal = (status: number, reason?: string) => ({ status, message: 'x', code: String(status), details: reason ? { reason } : {} })

describe('W1 documentPrintable', () => {
  it.each(DOC_KINDS.flatMap((kind) => DOC_STATES.map((state) => [kind, state])))('%s %s', (kind, state) => {
    const four = ['commission', 'change', 'handover', 'writeoff'].includes(kind!)
    const active = ['issued', 'posted', 'reversed'].includes(state!)
    expect(documentPrintable({ kind: kind!, state: state! })).toBe(four && active)
  })
})

describe('W1 printErrorMessageId', () => {
  it('maps a known 422 reason, 404, and the rest to the generic message', () => {
    expect(printErrorMessageId(refusal(422, 'document_not_issued'))).toBe('assets.doc.print.reason.document_not_issued')
    expect(printErrorMessageId(refusal(422, 'unknown'))).toBe('assets.doc.error.generic')
    expect(printErrorMessageId(refusal(404))).toBe('assets.doc.error.notFound')
    expect(printErrorMessageId(refusal(403))).toBe('assets.doc.error.generic')
    expect(printErrorMessageId(refusal(500))).toBe('assets.doc.error.generic')
  })
})
