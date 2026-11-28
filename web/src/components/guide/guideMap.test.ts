/** T-3160: the build must carry the three designer-guide documents; an empty map shows "not available". */
import { describe, it, expect } from 'vitest'

import { guideLocalesInBundle } from './DesignerGuidePanel'

describe('designer guide map', () => {
  it('has a loader for en, ru and kk', () => {
    expect(guideLocalesInBundle()).toEqual(['en', 'ru', 'kk'])
  })
})
