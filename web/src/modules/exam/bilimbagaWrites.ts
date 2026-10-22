/** bilimbagaWrites — GH #2680 / REQ-510 slice 2
 *
 *  The write side of the ten BilimBaga authoring entity types (the list in
 *  ./bilimbagaEntities.ts). `EntityCrudPage` takes it as its `writes` prop from
 *  BilimBagaEntityRoute, so create, update and delete for these types go through the exam
 *  module's authoring routes (`/modules/exam/authoring/...`, gated by `ExamAuthoringWrite`)
 *  instead of the generic `/entities/records` routes. Every other entity type keeps the
 *  page's default (`EntitiesRecordsWrite`, `/entities/records`).
 */

import { examAuthoringApi } from './exam.api'
import type { EntityWrites } from '@/pages/entities/EntityCrudPage'

/** The exam module's dedicated write permission (lib/letflow/modules/exam/exam.ex). A module
 *  permission, so a plain string rather than a core `P` entry (see auth/access/types.ts). */
export const EXAM_AUTHORING_WRITE = 'ExamAuthoringWrite'

export const BILIMBAGA_WRITES: EntityWrites = {
  api: examAuthoringApi,
  permission: EXAM_AUTHORING_WRITE,
}
