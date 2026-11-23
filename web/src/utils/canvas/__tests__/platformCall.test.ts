/** platformCall — T-2599 (pilot gap G5a): the pure rules of the function picker and of the typed var/const
 *  argument mapping. P1 the call is read from the attribute (and a malformed one is "no call"), P2 the reads are
 *  derived from the `var` arguments, P3 the writes are derived from the catalogue outputs, P4 the two mapping
 *  sides are what the server reads, P5 the constant follows the declared type, P6 the conflict of two arguments
 *  of different types on one variable is reported, P9 the rule of a variable name, P10 a catalogue type is
 *  DECLARED with its JSON-Schema name. */
import { describe, expect, it } from 'vitest'
import type { PlatformFunctionEntry } from '@/types/api'
import {
  argSource,
  argText,
  constText,
  deriveReads,
  deriveWrites,
  emptyPlatformCall,
  isPlainVariableName,
  parseConst,
  parsePlatformCall,
  readConflicts,
  withArg,
  withDerivedMapping,
} from '../platformCall'

const entry: PlatformFunctionEntry = {
  name: 'platform.validate_registration',
  family: 'platform',
  version: '1',
  permission: 'TenantsManage',
  platform_tenant_only: true,
  idempotency_inputs: ['slug'],
  inputs: [
    { name: 'slug', type: 'string', required: true, source_class: 'start' },
    { name: 'display_name', type: 'string', required: true, source_class: 'start' },
    { name: 'email', type: 'string', required: true, source_class: 'start' },
  ],
  outputs: [
    { name: 'normalized_slug', type: 'string' },
    { name: 'email_domain', type: 'string' },
  ],
  side_effects: [{ text: 'reads nothing and writes nothing', class: 'read' }],
}

const mixedEntry: PlatformFunctionEntry = {
  ...entry,
  name: 'tenant.provision',
  inputs: [
    { name: 'tenant_id', type: 'uuid', required: true, source_class: 'step' },
    { name: 'retries', type: 'integer', required: false, source_class: 'start' },
  ],
  outputs: [{ name: 'schema_name', type: 'string' }],
}

/** An entry of the REAL catalogue: a uuid in, a uuid out (the tenant family publishes `type: :uuid`). */
const uuidEntry: PlatformFunctionEntry = {
  ...entry,
  name: 'tenant.create',
  inputs: [{ name: 'tenant_id', type: 'uuid', required: true, source_class: 'step' }],
  outputs: [{ name: 'tenant_id', type: 'uuid' }],
}

describe('platformCall', () => {
  it('P1 reads a well-formed call and refuses a malformed one', () => {
    expect(parsePlatformCall({ function: 'platform.validate_registration', args: {}, reads: {}, writes: {} })).toEqual({
      function: 'platform.validate_registration',
      args: {},
      reads: {},
      writes: {},
    })
    expect(parsePlatformCall({ function: 'x', args: { a: { var: 'v' } }, reads: { v: 'string' }, writes: {} })).toEqual({
      function: 'x',
      args: { a: { var: 'v' } },
      reads: { v: 'string' },
      writes: {},
    })
    // No function, a blank one, an argument with two keys, a source with an unknown key: all "no call".
    expect(parsePlatformCall({ args: {}, reads: {}, writes: {} })).toBeNull()
    expect(parsePlatformCall({ function: '  ', args: {}, reads: {}, writes: {} })).toBeNull()
    expect(parsePlatformCall({ function: 'x', args: { a: { var: 'v', const: 1 } }, reads: {}, writes: {} })).toBeNull()
    expect(parsePlatformCall({ function: 'x', args: { a: { other: 'v' } }, reads: {}, writes: {} })).toBeNull()
    expect(parsePlatformCall({ function: 'x', args: [], reads: {}, writes: {} })).toBeNull()
    expect(parsePlatformCall('x')).toBeNull()
    expect(parsePlatformCall(undefined)).toBeNull()
  })

  it('P2 derives the reads from the variable arguments only', () => {
    const call = withArg(withArg(emptyPlatformCall(entry.name), 'slug', 'var', 'slug'), 'display_name', 'const', 'Acme')
    expect(deriveReads(call, entry)).toEqual({ slug: 'string' })
    // A chosen source with no value yet reads nothing.
    expect(deriveReads(withArg(emptyPlatformCall(entry.name), 'slug', 'var', ''), entry)).toEqual({})
  })

  it('P3 derives the writes from the catalogue outputs only', () => {
    const call = { ...emptyPlatformCall(entry.name), writes: { normalized_slug: 'string', not_an_output: 'string' } }
    expect(deriveWrites(call, entry)).toEqual({ normalized_slug: 'string' })
  })

  it('P4 the derived mapping is the shape the server reads', () => {
    const call = withArg(withArg(emptyPlatformCall(entry.name), 'slug', 'var', 'slug'), 'email', 'const', 'a@b.test')
    const full = withDerivedMapping({ ...call, writes: { normalized_slug: 'string' } }, entry)
    expect(full).toEqual({
      function: 'platform.validate_registration',
      args: { slug: { var: 'slug' }, email: { const: 'a@b.test' } },
      reads: { slug: 'string' },
      writes: { normalized_slug: 'string' },
    })
  })

  it('P5 the constant follows the declared type', () => {
    expect(parseConst('string', 'Acme')).toEqual({ ok: true, value: 'Acme' })
    expect(parseConst('number', '42')).toEqual({ ok: true, value: 42 })
    expect(parseConst('number', '4.5')).toEqual({ ok: true, value: 4.5 })
    expect(parseConst('integer', '3')).toEqual({ ok: true, value: 3 })
    expect(parseConst('integer', '3.5')).toEqual({ ok: false, error: 'not_a_number' })
    expect(parseConst('number', 'many')).toEqual({ ok: false, error: 'not_a_number' })
    expect(parseConst('boolean', 'true')).toEqual({ ok: true, value: true })
    expect(parseConst('boolean', 'no')).toEqual({ ok: false, error: 'not_a_boolean' })
    expect(parseConst('object', '{"a":1}')).toEqual({ ok: true, value: { a: 1 } })
    expect(parseConst('object', '{a:1}')).toEqual({ ok: false, error: 'not_json' })
    expect(parseConst('array', '[1,2]')).toEqual({ ok: true, value: [1, 2] })
    expect(parseConst('array', '{"a":1}')).toEqual({ ok: false, error: 'not_json' })
    // The text of a value follows the type too.
    expect(constText('string', 'Acme')).toBe('Acme')
    expect(constText('number', 42)).toBe('42')
    expect(constText('boolean', false)).toBe('false')
    expect(constText('object', { a: 1 })).toBe('{"a":1}')
  })

  it('P6 reports the variable two arguments of different types would read', () => {
    const call = withArg(withArg(emptyPlatformCall(mixedEntry.name), 'tenant_id', 'var', 'shared'), 'retries', 'var', 'shared')
    expect(readConflicts(call, mixedEntry)).toEqual(['shared'])
    const same = withArg(withArg(emptyPlatformCall(entry.name), 'slug', 'var', 'x'), 'display_name', 'var', 'x')
    expect(readConflicts(same, entry)).toEqual([])
    // Two arguments that DECLARE the same type are no conflict: a uuid and a string are both declared as a string.
    const uuidAndString = withArg(withArg(emptyPlatformCall(mixedEntry.name), 'tenant_id', 'var', 'shared'), 'slug', 'var', 'shared')
    expect(readConflicts(uuidAndString, { ...mixedEntry, inputs: [...mixedEntry.inputs, { name: 'slug', type: 'string', required: true, source_class: 'start' }] })).toEqual([])
  })

  it('P7 the argument source is read back from the mapping', () => {
    const call = withArg(withArg(emptyPlatformCall(entry.name), 'slug', 'var', 'slug'), 'display_name', 'const', 'Acme')
    expect(argSource(call, 'slug')).toBe('var')
    expect(argSource(call, 'display_name')).toBe('const')
    expect(argSource(call, 'email')).toBeNull()
    expect(argText(call, 'slug', 'string')).toBe('slug')
    expect(argText(call, 'display_name', 'string')).toBe('Acme')
  })

  it('P8 a chosen source keeps its key; only "not mapped" removes the argument', () => {
    const chosen = withArg(emptyPlatformCall(entry.name), 'slug', 'var', '')
    expect(chosen.args).toEqual({ slug: { var: '' } })
    expect(argSource(chosen, 'slug')).toBe('var')
    expect(withArg(chosen, 'slug', null, null).args).toEqual({})
  })

  it('P9 a variable name is plain: no dot, not empty, within the bound', () => {
    expect(isPlainVariableName('slug')).toBe(true)
    expect(isPlainVariableName('tenant.slug')).toBe(false)
    expect(isPlainVariableName('')).toBe(false)
    expect(isPlainVariableName('x'.repeat(256))).toBe(false)
    expect(isPlainVariableName('x'.repeat(255))).toBe(true)
  })

  it('P10 a catalogue type is DECLARED with its JSON-Schema name (a uuid is a string)', () => {
    // The server accepts only the six JSON-Schema names (`Letflow.Definitions.StepMapping`), so the catalogue's own
    // type names cannot be copied into the declaration.
    // The READ of a uuid-typed argument is declared as a string.
    const read = withArg(emptyPlatformCall(uuidEntry.name), 'tenant_id', 'var', 'tenant')
    expect(deriveReads(read, uuidEntry)).toEqual({ tenant: 'string' })
    // The WRITE of a uuid-typed output is declared as a string.
    const written = { ...emptyPlatformCall(uuidEntry.name), writes: { tenant_id: 'string' } }
    expect(deriveWrites(written, uuidEntry)).toEqual({ tenant_id: 'string' })
    // The whole mapping the server reads.
    expect(withDerivedMapping(read, uuidEntry)).toEqual({
      function: 'tenant.create',
      args: { tenant_id: { var: 'tenant' } },
      reads: { tenant: 'string' },
      writes: {},
    })
  })
})
