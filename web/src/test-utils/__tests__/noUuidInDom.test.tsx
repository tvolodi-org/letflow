// @vitest-environment jsdom
import { describe, it, expect, afterEach } from 'vitest'
import { cleanup, render } from '@testing-library/react'
import { noUuidInDom, uuidsInDom } from '../noUuidInDom'

afterEach(cleanup)

const ID = '5b58a738-1c2d-4e3f-8a9b-0c1d2e3f4a5b'

describe('noUuidInDom', () => {
  it('is true for readable text', () => {
    const { container } = render(<p title="Bolt">ITM-1 - Bolt M8</p>)
    expect(noUuidInDom(container)).toBe(true)
  })
  it('finds a uuid in text, a title and an input value', () => {
    const a = render(<p>Item {ID}</p>)
    expect(uuidsInDom(a.container)).toEqual([ID])
    const b = render(<p title={ID}>x</p>)
    expect(noUuidInDom(b.container)).toBe(false)
    const c = render(<input defaultValue={ID} />)
    expect(noUuidInDom(c.container)).toBe(false)
  })
  it('does not flag a short id or a document number', () => {
    const { container } = render(<p>i1 RC-2026-0007 en-7</p>)
    expect(noUuidInDom(container)).toBe(true)
  })
})
