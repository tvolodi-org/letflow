import { expect, it } from 'vitest'
import { recordCodesKeys } from '@/lib/codes/recordCodes.api'
import { codesQueryKeys } from '../codesQueryKeys'
it('K1 record codes and Codes screen invalidate the same tenant prefix', () => {
  expect(recordCodesKeys.all('t')).toEqual(codesQueryKeys.all('t'))
  expect(recordCodesKeys.record('t', 'catalog_item', 'x').slice(0, 2)).toEqual(codesQueryKeys.all('t'))
  expect(recordCodesKeys.all('a')).not.toEqual(recordCodesKeys.all('b'))
})
