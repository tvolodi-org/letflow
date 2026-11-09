/** T-1514: the stock document kinds and their header keys agree on server and web (parallel to the assets M1 test). */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { DOC_KINDS, buildBody, emptyForm, type DocKind, type FormState } from '../documents/documentsModel'

const KINDS_EX = path.resolve(__dirname, '../../../../../lib/letflow/modules/stock/documents/kinds.ex')

// Server kinds with no web form yet. Empty today: every server kind (opening included) has a web form.
const WEB_PENDING_KINDS: readonly string[] = []

/** Resolve a `~w(...)` word list, or a module attribute naming one, the way kinds.ex builds them. */
function serverKinds(): Map<string, string[]> {
  const src = readFileSync(KINDS_EX, 'utf-8')
  const attrs = new Map<string, string[]>()
  for (const m of src.matchAll(/^\s*@(\w+) ~w\(([^)]*)\)/gm)) attrs.set(m[1], m[2].trim().split(/\s+/))
  for (const m of src.matchAll(/^\s*@(\w+) @(\w+) \+\+ (~w\(([^)]*)\)|\["(\w+)"\])/gm)) {
    attrs.set(m[1], [...(attrs.get(m[2]) ?? []), ...(m[4] ? m[4].trim().split(/\s+/) : [m[5]])])
  }
  const out = new Map<string, string[]>()
  for (const m of src.matchAll(/kind: "(\w+)"[\s\S]*?header_keys:\s*(?:@(\w+)|~w\(([^)]*)\))/g)) {
    const keys = m[2] ? attrs.get(m[2]) : m[3].trim().split(/\s+/)
    expect(keys, `header_keys of ${m[1]} resolved`).toBeTruthy()
    out.set(m[1], keys as string[])
  }
  return out
}

/** The header keys the web sends for a kind: a form with every field filled, minus `kind` and `lines`. */
function webHeaderKeys(kind: DocKind): string[] {
  const side = { orgUnitId: 'o', locationId: 'l', responsibleId: 'r' }
  const f: FormState = {
    ...emptyForm(kind),
    eventTime: '2026-11-04T10:00', from: side, to: side, ...side,
    counterpartyId: 'c', note: 'n', supplierRef: 's', receivedOn: '2026-11-01', reasonCode: 'lost', reasonText: 't',
    externalRefSystem: 'x', externalRefId: 'y',
  }
  return Object.keys(buildBody(f)).filter((k) => k !== 'kind' && k !== 'lines').sort()
}

describe('T-1514 stock document kinds: server Kinds vs web model', () => {
  it('the kinds of the server table equal DOC_KINDS (less WEB_PENDING_KINDS), in order', () => {
    const server = [...serverKinds().keys()].filter((k) => !WEB_PENDING_KINDS.includes(k))
    expect(server).toEqual([...DOC_KINDS])
  })
  it('the header keys of every kind equal the keys buildBody sends (everything filled)', () => {
    const server = serverKinds()
    for (const kind of DOC_KINDS) {
      expect([...(server.get(kind) ?? [])].sort(), kind).toEqual(webHeaderKeys(kind))
    }
  })
})
