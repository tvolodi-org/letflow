// @vitest-environment jsdom
import { existsSync, readFileSync } from 'node:fs'
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
    // the script must come before the module entry (styles are imported by it; no external stylesheet link)
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

  it('index.html names no external font host; the self-hosted @font-face rules cover the three families', () => {
    const html = readFileSync(join(__dirname, '../../../index.html'), 'utf8')
    expect(html).not.toMatch(/fonts\.(googleapis|gstatic)\.com/)
    const css = readFileSync(join(__dirname, '../../styles/components.css'), 'utf8')
    expect(css).not.toMatch(/fonts\.(googleapis|gstatic)\.com/)
    for (const f of ['Geologica', 'Onest', 'IBM Plex Mono']) expect(css).toContain(`font-family: '${f}'`)
    for (const m of css.matchAll(/url\("\.\.\/fonts\/([^"]+\.woff2)"\)/g)) {
      expect(existsSync(join(__dirname, '../../fonts', m[1]))).toBe(true)
    }
  })
})
