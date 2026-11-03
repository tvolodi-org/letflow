// @vitest-environment jsdom
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { THEME_STORAGE_KEY, currentTheme, readStoredTheme, setTheme } from '../theme'

afterEach(() => {
  document.documentElement.removeAttribute('data-theme')
  window.localStorage.clear()
})

describe('theme', () => {
  it('setTheme writes data-theme and storage', () => {
    setTheme('dark')
    expect(document.documentElement.getAttribute('data-theme')).toBe('dark')
    expect(window.localStorage.getItem(THEME_STORAGE_KEY)).toBe('dark')
    expect(currentTheme()).toBe('dark')
  })

  it('readStoredTheme ignores an unknown stored value', () => {
    window.localStorage.setItem(THEME_STORAGE_KEY, 'purple')
    expect(readStoredTheme()).toBeNull()
    window.localStorage.setItem(THEME_STORAGE_KEY, 'light')
    expect(readStoredTheme()).toBe('light')
  })

  it('the head script in index.html reads the same key and sets data-theme before paint', () => {
    const html = readFileSync(join(__dirname, '../../../index.html'), 'utf8')
    const script = html.match(/<script>([\s\S]*?)<\/script>/)?.[1]
    expect(script).toBeTruthy()
    expect(script).toContain(`'${THEME_STORAGE_KEY}'`)
    // the script must come before any stylesheet and the module entry
    expect(html.indexOf('<script>')).toBeLessThan(html.indexOf('stylesheet'))
    expect(html.indexOf('<script>')).toBeLessThan(html.indexOf('src="/src/main.tsx"'))

    window.localStorage.setItem(THEME_STORAGE_KEY, 'dark')
    new Function(script as string)()
    expect(document.documentElement.getAttribute('data-theme')).toBe('dark')
  })

  it('the head script leaves the attribute off for an invalid stored value', () => {
    const html = readFileSync(join(__dirname, '../../../index.html'), 'utf8')
    const script = html.match(/<script>([\s\S]*?)<\/script>/)?.[1] as string
    window.localStorage.setItem(THEME_STORAGE_KEY, 'bogus')
    new Function(script)()
    expect(document.documentElement.hasAttribute('data-theme')).toBe(false)
  })

  it('index.html preconnects and loads Geologica, Onest and IBM Plex Mono', () => {
    const html = readFileSync(join(__dirname, '../../../index.html'), 'utf8')
    expect(html).toContain('rel="preconnect" href="https://fonts.googleapis.com"')
    expect(html).toContain('rel="preconnect" href="https://fonts.gstatic.com"')
    for (const f of ['Geologica', 'Onest', 'IBM+Plex+Mono']) expect(html).toContain(`family=${f}`)
  })
})
