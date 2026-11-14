// @vitest-environment jsdom
/** W4/W5/W11 (T-1950): the client rings of a problem report. */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { installActionCapture, recordAction, recordRequest, resetCapture, snapshot } from '../capture'
import { buildReportBody } from '../payload'

let remove: () => void

beforeEach(() => {
  resetCapture()
  remove = installActionCapture()
})
afterEach(() => {
  remove()
  document.body.innerHTML = ''
})

function click(el: Element) {
  el.dispatchEvent(new MouseEvent('click', { bubbles: true }))
}

describe('actions (W4)', () => {
  it('(a) a button is named by its data-testid', () => {
    document.body.innerHTML = '<button data-testid="x-save">Save Ivan</button>'
    click(document.querySelector('button')!)
    expect(snapshot().actions).toMatchObject([{ kind: 'click', name: 'x-save' }])
  })
  it('(b) a span inside a menuitem without testid is named by the role', () => {
    document.body.innerHTML = '<div role="menuitem"><span id="s">Go</span></div>'
    click(document.getElementById('s')!)
    expect(snapshot().actions[0]).toMatchObject({ kind: 'click', name: 'menuitem' })
  })
  it('(c) a nav name drops the query and ids', () => {
    recordAction('nav', '/a/12345?q=1')
    expect(snapshot().actions[0]).toMatchObject({ kind: 'nav', name: '/a/:id' })
  })
  it('(d) keeps the last 20, oldest first', () => {
    for (let i = 0; i < 25; i++) recordAction('click', `b${i}x`)
    const a = snapshot().actions
    expect(a).toHaveLength(20)
    expect(a[0].name).toBe('b5x')
    expect(a[19].name).toBe('b24x')
  })
  it('(e) two equal navs collapse', () => {
    recordAction('nav', '/tasks')
    recordAction('nav', '/tasks')
    expect(snapshot().actions).toHaveLength(1)
  })
  it('(f) an id inside a testid becomes :id', () => {
    recordAction('click', 'row-0b9f8e7a-1111-4222-8333-444455556666')
    expect(snapshot().actions[0].name).toBe('row-:id')
  })
})

describe('what is never recorded (W5)', () => {
  it('ignores inputs, contenteditable and the report dialog; never reads text', () => {
    document.body.innerHTML = `
      <input id="i"><textarea id="t"></textarea><select id="s"><option>a</option></select>
      <div contenteditable="true"><button id="ce">x</button></div>
      <div data-testid="report-dialog"><button id="in-dialog">Send</button></div>
      <button id="named">Ivan Petrov</button>`
    for (const id of ['i', 't', 's', 'ce', 'in-dialog']) click(document.getElementById(id)!)
    expect(snapshot().actions).toHaveLength(0)
    click(document.getElementById('named')!)
    const snap = snapshot()
    expect(snap.actions).toMatchObject([{ name: 'button' }])
    expect(JSON.stringify(snap)).not.toContain('Ivan')
  })
})

describe('requests (W4f)', () => {
  const get = (path: string, status: number) => recordRequest(null, 'GET', path, status, null)
  it('keeps errors while polls flood the ring', () => {
    get('/api/v1/e1', 500)
    get('/api/v1/e2', 404)
    get('/api/v1/e3', 0)
    for (let i = 0; i < 12; i++) get(`/api/v1/poll${i}x`, 200)
    const r = snapshot().requests
    expect(r).toHaveLength(10)
    expect(r.filter((e) => e.status !== 200)).toHaveLength(3)
  })
  it('the same successful call twice is one entry, moved to the end', () => {
    get('/api/v1/a', 200)
    get('/api/v1/b', 200)
    get('/api/v1/a', 200)
    expect(snapshot().requests.map((e) => e.path)).toEqual(['/api/v1/b', '/api/v1/a'])
  })
  it('only when all ten are errors is the oldest error dropped', () => {
    for (let i = 0; i < 11; i++) get(`/api/v1/err${i}x`, 500)
    const r = snapshot().requests
    expect(r).toHaveLength(10)
    expect(r[0].path).toBe('/api/v1/err1x')
  })
  it('ignores non-api urls, unknown methods and the report route; validates the trace id', () => {
    recordRequest(null, 'GET', '/assets/app.js', 200, null)
    recordRequest(null, 'POST', '/api/v1/me/problem-reports', 201, null)
    recordRequest(null, 'TRACE', '/api/v1/x', 200, null)
    recordRequest(null, 'get', '/api/v1/tasks/0b9f8e7a-1111-4222-8333-444455556666?x=1', 500, 'bad id!')
    const r = snapshot().requests
    expect(r).toEqual([expect.objectContaining({ method: 'GET', path: '/api/v1/tasks/:id', status: 500 })])
    expect(r[0].trace_id).toBeUndefined()
  })
})

describe('tenant isolation of the rings (W11)', () => {
  it('resetCapture empties both rings', () => {
    recordAction('nav', '/a')
    recordRequest(null, 'GET', '/api/v1/x', 200, null)
    resetCapture()
    expect(snapshot()).toEqual({ actions: [], requests: [] })
  })
})

describe('buildReportBody', () => {
  it('masks the text and the crash, and carries the snapshot', () => {
    recordAction('nav', '/tasks')
    const body = buildReportBody('  mail ivan.petrov@example.kz ', snapshot(), {
      uiLanguage: 'ru',
      crash: new Error('boom 12345 for a@b.kz'),
    })
    expect(body.consent).toBe(true)
    expect(body.text).toBe('mail [email]')
    expect(body.context.ui_language).toBe('ru')
    expect(body.context.crash).toEqual({ name: 'Error', message: 'boom 12345 for [email]' })
    expect(body.context.actions).toHaveLength(1)
    expect('crash' in buildReportBody('x', snapshot(), { uiLanguage: 'en' }).context).toBe(false)
  })
})
