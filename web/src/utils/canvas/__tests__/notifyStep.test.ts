/** notifyStep — T-2600 (pilot gap G5b): the pure rules of the notification step's form. N1 the step is read
 *  from the attribute (and a malformed one is "no step"), N2 the attribute the server reads carries only the
 *  keys the CHANNEL allows, N3 switching the channel drops what the other channel carried, N4 the rule of a
 *  variable name, N5 the rule of a file name, N6 the problems of a step, in the order the server checks them. */
import { describe, expect, it } from 'vitest'
import {
  emptyNotifyStep,
  fileNameProblem,
  isUsableVariableName,
  notifyAttribute,
  notifyProblems,
  parseNotifyStep,
  valueSource,
  withChannel,
  withValue,
} from '../notifyStep'

const PLACEHOLDERS = ['tenant_name', 'tenant_slug', 'registered_by']

describe('notifyStep — the attribute', () => {
  it('N1 the step is read from the attribute; a malformed one is "no step"', () => {
    const step = parseNotifyStep({
      channel: 'email',
      template_key: 'tenant_registered',
      recipient: { var: 'admin_email' },
      values: { tenant_name: { var: 'tenant_name' }, tenant_slug: { const: 'known-co' } },
    })
    expect(step).toEqual({
      channel: 'email',
      templateKey: 'tenant_registered',
      recipientVar: 'admin_email',
      fileName: '',
      values: { tenant_name: { var: 'tenant_name' }, tenant_slug: { const: 'known-co' } },
    })

    // The channel is optional: without one it is the mail channel.
    expect(parseNotifyStep({ template_key: 'tenant_registered', values: {} })?.channel).toBe('email')

    // A malformed attribute is no step.
    expect(parseNotifyStep(null)).toBeNull()
    expect(parseNotifyStep('nope')).toBeNull()
    expect(parseNotifyStep({ template_key: '', values: {} })).toBeNull()
    expect(parseNotifyStep({ template_key: 'tenant_registered', values: {}, channel: 'sms' })).toBeNull()
    expect(parseNotifyStep({ template_key: 'tenant_registered', values: { a: { var: 1 } } })).toBeNull()
  })

  it('N2 the attribute the server reads carries only the keys the channel allows', () => {
    const mail = {
      ...emptyNotifyStep(),
      templateKey: 'tenant_registered',
      recipientVar: 'admin_email',
      fileName: 'left-over',
      values: { tenant_name: { var: 'tenant_name' } },
    }
    expect(notifyAttribute(mail)).toEqual({
      template_key: 'tenant_registered',
      recipient: { var: 'admin_email' },
      values: { tenant_name: { var: 'tenant_name' } },
    })

    const file = { ...emptyNotifyStep('file'), templateKey: 'tenant_registered', fileName: 'notice', recipientVar: 'admin_email' }
    expect(notifyAttribute(file)).toEqual({
      template_key: 'tenant_registered',
      channel: 'file',
      file_name: 'notice',
      values: {},
    })
  })

  it('N3 switching the channel drops what the other channel carried', () => {
    const mail = { ...emptyNotifyStep(), templateKey: 'tenant_registered', recipientVar: 'admin_email', fileName: 'notice' }
    const file = withChannel(mail, 'file')
    expect(file.channel).toBe('file')
    expect(file.recipientVar).toBe('')
    expect(file.fileName).toBe('notice')

    const back = withChannel(file, 'email')
    expect(back.channel).toBe('email')
    expect(back.fileName).toBe('')
    expect(back.recipientVar).toBe('')
  })

  it('N4 the rule of a variable name', () => {
    expect(isUsableVariableName('admin_email')).toBe(true)
    expect(isUsableVariableName('')).toBe(false)
    expect(isUsableVariableName('tenant.slug')).toBe(false)
    expect(isUsableVariableName('_sys')).toBe(false)
    expect(isUsableVariableName('_sys.state')).toBe(false)
    expect(isUsableVariableName(42)).toBe(false)
  })

  it('N5 the rule of a file name', () => {
    expect(fileNameProblem('notice')).toBeNull()
    expect(fileNameProblem('')).toBe('empty')
    expect(fileNameProblem('/tmp/x')).toBe('path')
    expect(fileNameProblem('a/b')).toBe('path')
    expect(fileNameProblem('a\\b')).toBe('path')
    expect(fileNameProblem('../x')).toBe('path')
    expect(fileNameProblem('C:file')).toBe('path')
    expect(fileNameProblem('~/file')).toBe('path')
    expect(fileNameProblem(`a${String.fromCharCode(7)}b`)).toBe('not_text')
    expect(fileNameProblem('a'.repeat(256))).toBe('too_long')
  })

  it('N6 the problems of a step, in the order the server checks them', () => {
    const keys = ['tenant_registered']

    expect(notifyProblems(emptyNotifyStep(), PLACEHOLDERS, keys)).toEqual(['template_missing'])

    const noRecipient = { ...emptyNotifyStep(), templateKey: 'tenant_registered' }
    expect(notifyProblems(noRecipient, PLACEHOLDERS, keys)).toEqual(['recipient_missing'])

    const unknownTemplate = { ...noRecipient, templateKey: 'nope' }
    expect(notifyProblems(unknownTemplate, PLACEHOLDERS, keys)).toEqual(['template_unknown', 'recipient_missing'])

    const badRecipient = { ...noRecipient, recipientVar: 'tenant.slug' }
    expect(notifyProblems(badRecipient, PLACEHOLDERS, keys)).toEqual(['recipient_invalid'])

    const file = { ...emptyNotifyStep('file'), templateKey: 'tenant_registered' }
    expect(notifyProblems(file, PLACEHOLDERS, keys)).toEqual(['file_name_missing'])

    const badFile = { ...file, fileName: '../x' }
    expect(notifyProblems(badFile, PLACEHOLDERS, keys)).toEqual(['file_name_invalid'])

    const badValue = { ...noRecipient, recipientVar: 'admin_email', values: { other: { var: 'x' } } }
    expect(notifyProblems(badValue, PLACEHOLDERS, keys)).toEqual(['value_unknown'])

    const good = {
      ...noRecipient,
      recipientVar: 'admin_email',
      values: { tenant_name: { var: 'tenant_name' }, tenant_slug: { const: 'known-co' } },
    }
    expect(notifyProblems(good, PLACEHOLDERS, keys)).toEqual([])
  })

  it('a value keeps its key while its source is chosen but its value is empty', () => {
    const step = withValue({ ...emptyNotifyStep(), templateKey: 'tenant_registered' }, 'tenant_name', { var: '' })
    expect(valueSource(step, 'tenant_name')).toEqual({ var: '' })
    const dropped = withValue(step, 'tenant_name', null)
    expect(valueSource(dropped, 'tenant_name')).toBeNull()
  })
})
