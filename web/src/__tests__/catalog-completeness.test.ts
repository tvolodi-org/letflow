/** catalog-completeness.test.ts — T-1457
 *
 * Checks every flat en/ru/kk message catalog in the SPA:
 *  1. Every key present in `en` is also present in `ru` and `kk`.
 *  2. No value in any locale is an empty string.
 *
 * A failure names the module and key so the gap is found immediately without
 * reading a diff. Structured catalogs (where TypeScript interfaces enforce
 * key presence at compile time) are also checked for empty string values.
 *
 * Sub-catalogs that are spread into a parent (e.g. countsEn into stockMessages,
 * questionMessages into examMessages) are covered through the merged parent; the
 * individual split exports are also checked separately to catch gaps at their source.
 */
import { describe, it, expect } from 'vitest'

import { loginMessages } from '@/i18n/loginMessages'
import { entitiesMessages } from '@/i18n/entitiesMessages'
import { solutionOverridesMessages } from '@/i18n/solutionOverridesMessages'
import { importMessages } from '@/i18n/importMessages'
import { assetsMessages } from '@/modules/assets/assetsMessages'
import { catalogItemsMessages } from '@/modules/catalog_items/catalogItemsMessages'
import { catalogItemsItemsMessages } from '@/modules/catalog_items/catalogItemsItemsMessages'
import { codesMessages } from '@/modules/codes/codesMessages'
import { examMessages } from '@/modules/exam/examMessages'
import {
  questionMessagesEn,
  questionMessagesRu,
  questionMessagesKk,
} from '@/modules/exam/questionMessages'
import { locationsMessages } from '@/modules/locations/locationsMessages'
import { orgMessages } from '@/modules/org/orgMessages'
import { stockMessages } from '@/modules/stock/stockMessages'
import {
  countsEn,
  countsRu,
  countsKk,
} from '@/modules/stock/counts/countsMessages'
import {
  docEn,
  docRu,
  docKk,
} from '@/modules/stock/documents/documentsMessages'
import {
  formEn,
  formRu,
  formKk,
} from '@/modules/stock/forms/officialFormMessages'
import { formMessages } from '@/components/ui/formMessages'
import { layoutMessages } from '@/components/ui/layout/layoutMessages'
import { navMessages } from '@/components/layout/navMessages'
import { uiMessages } from '@/components/ui/uiMessages'
import { mySettingsMessages } from '@/pages/me/mySettingsMessages'
import { TASK_MESSAGES } from '@/pages/tasks/taskMessages'
import { REFERENCE_MESSAGES } from '@/lib/references/referenceMessages'

const LOCALES = ['en', 'ru', 'kk'] as const
type Locale = (typeof LOCALES)[number]

/** Recursively flattens a nested object to `[dotpath, stringValue]` pairs.
 *  Only string leaves are emitted; non-string leaves (numbers, etc.) are skipped. */
function flattenStrings(obj: unknown, prefix = ''): Array<[string, string]> {
  if (typeof obj === 'string') return [[prefix, obj]]
  if (typeof obj !== 'object' || obj === null) return []
  return Object.entries(obj as Record<string, unknown>).flatMap(([k, v]) =>
    flattenStrings(v, prefix ? `${prefix}.${k}` : k),
  )
}

/**
 * Checks a flat `Record<Locale, Record<string, string>>` catalog.
 *  - Every key in `en` is present in `ru` and `kk`.
 *  - No value in any locale is the empty string (after trimming whitespace).
 *
 * On any violation the assertion message names both the module and the key.
 */
function checkFlatCatalog(
  module: string,
  catalog: Record<Locale, Record<string, string>>,
): void {
  const enKeys = Object.keys(catalog.en)
  expect(enKeys.length, `${module}: catalog is empty`).toBeGreaterThan(0)

  for (const key of enKeys) {
    expect(key in catalog.ru, `${module}: key '${key}' missing in ru`).toBe(true)
    expect(key in catalog.kk, `${module}: key '${key}' missing in kk`).toBe(true)
  }

  for (const locale of LOCALES) {
    for (const [key, value] of Object.entries(catalog[locale])) {
      expect(
        value.trim(),
        `${module}: ${locale}.${key} is empty`,
      ).not.toBe('')
    }
  }
}

/**
 * Checks a structured catalog whose value type may be a nested object.
 * TypeScript interfaces enforce key presence at compile time, so only
 * empty-string values are checked here (recursively through the structure).
 */
function checkStructuredCatalog(
  module: string,
  catalog: Record<Locale, unknown>,
): void {
  for (const locale of LOCALES) {
    const pairs = flattenStrings(catalog[locale])
    expect(pairs.length, `${module}: ${locale} catalog is empty`).toBeGreaterThan(0)
    for (const [path, value] of pairs) {
      expect(value.trim(), `${module}: ${locale}.${path} is empty`).not.toBe('')
    }
  }
}

/** Normalises three separate locale exports into a single Record<Locale, Record<string,string>>. */
function fromSplit(
  en: Record<string, string>,
  ru: Record<string, string>,
  kk: Record<string, string>,
): Record<Locale, Record<string, string>> {
  return { en, ru, kk }
}

describe('catalog-completeness — T-1457: every en/ru/kk key present and non-empty', () => {
  // --- flat catalogs (Record<Locale, Record<string, string>>) ---

  it('loginMessages: all en keys in ru/kk, no empty values', () => {
    checkFlatCatalog('login', loginMessages)
  })

  it('entitiesMessages (includes solutionOverrides): all en keys in ru/kk, no empty values', () => {
    checkFlatCatalog('entities', entitiesMessages)
  })

  it('solutionOverridesMessages: all en keys in ru/kk, no empty values', () => {
    checkFlatCatalog('solutionOverrides', solutionOverridesMessages)
  })

  it('importMessages: all en keys in ru/kk, no empty values', () => {
    checkFlatCatalog('import', importMessages)
  })

  it('assetsMessages: all en keys in ru/kk, no empty values', () => {
    checkFlatCatalog('assets', assetsMessages)
  })

  it('catalogItemsMessages (includes catalogItemsItems): all en keys in ru/kk, no empty values', () => {
    checkFlatCatalog('catalog_items', catalogItemsMessages)
  })

  it('catalogItemsItemsMessages (sub-catalog): all en keys in ru/kk, no empty values', () => {
    checkFlatCatalog(
      'catalog_items.items',
      catalogItemsItemsMessages as Record<Locale, Record<string, string>>,
    )
  })

  it('codesMessages: all en keys in ru/kk, no empty values', () => {
    checkFlatCatalog('codes', codesMessages)
  })

  it('examMessages (includes questionMessages): all en keys in ru/kk, no empty values', () => {
    checkFlatCatalog('exam', examMessages)
  })

  it('questionMessages (sub-catalog): all en keys in ru/kk, no empty values', () => {
    checkFlatCatalog('exam.question', fromSplit(questionMessagesEn, questionMessagesRu, questionMessagesKk))
  })

  it('locationsMessages: all en keys in ru/kk, no empty values', () => {
    checkFlatCatalog('locations', locationsMessages)
  })

  it('orgMessages: all en keys in ru/kk, no empty values', () => {
    checkFlatCatalog('org', orgMessages)
  })

  it('stockMessages (includes counts/documents/forms): all en keys in ru/kk, no empty values', () => {
    checkFlatCatalog('stock', stockMessages)
  })

  it('countsMessages (sub-catalog): all en keys in ru/kk, no empty values', () => {
    checkFlatCatalog('stock.counts', fromSplit(countsEn, countsRu, countsKk))
  })

  it('documentsMessages (sub-catalog): all en keys in ru/kk, no empty values', () => {
    checkFlatCatalog('stock.documents', fromSplit(docEn, docRu, docKk))
  })

  it('officialFormMessages (sub-catalog): all en keys in ru/kk, no empty values', () => {
    checkFlatCatalog('stock.forms', fromSplit(formEn, formRu, formKk))
  })

  // --- structured catalogs (TypeScript interface guarantees key presence; check empty values) ---

  it('formMessages (structured): no empty values in any locale', () => {
    checkStructuredCatalog('formMessages', formMessages)
  })

  it('layoutMessages (structured): no empty values in any locale', () => {
    checkStructuredCatalog('layoutMessages', layoutMessages)
  })

  it('navMessages (structured): no empty values in any locale', () => {
    checkStructuredCatalog('nav', navMessages)
  })

  it('uiMessages (structured): no empty values in any locale', () => {
    checkStructuredCatalog('ui', uiMessages)
  })

  it('mySettingsMessages (structured): no empty values in any locale', () => {
    checkStructuredCatalog('mySettings', mySettingsMessages)
  })

  it('TASK_MESSAGES (structured): no empty values in any locale', () => {
    checkStructuredCatalog('tasks', TASK_MESSAGES)
  })

  it('REFERENCE_MESSAGES (structured): no empty values in any locale', () => {
    checkStructuredCatalog('reference', REFERENCE_MESSAGES)
  })
})
