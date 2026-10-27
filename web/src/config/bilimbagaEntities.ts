/** bilimbagaEntities — REQ-343
 *
 *  All ten BilimBaga admin-manageable entity types this requirement wires
 *  screens for (REQ-326: category, question, answer_option, question_tag,
 *  tag; REQ-327: exam, exam_section, exam_question_rule,
 *  exam_question_rule_tag, exam_manual_question). This is DATA, not an
 *  eleventh hand-written screen: one generic component
 *  (`web/src/pages/entities/EntityCrudPage.tsx`, the direct descendant of
 *  REQ-336's original `TagListPage.tsx` pilot for `tag` -- since superseded
 *  and removed, see ISS-0655) is parameterized by `entityType` from this
 *  list, rather than duplicating a hand-written list/create/edit/delete
 *  screen ten times. A single dynamic route (`/admin/bilimbaga/:entityType`
 *  in web/src/router.tsx) renders it.
 *
 *  NOTE — self-referential parent_id (REQ-586). category.parent_id and
 *  question.parent_id are declared on the exam module's entity definitions
 *  now, and EntityCrudPage renders them from the active definition like any
 *  other field: category.parent_id through the indented category tree picker
 *  (`entity-category-tree`, components/forms/widgets/categoryTreeSelect.tsx),
 *  question.parent_id through the generic fk reference lookup. parent_id is
 *  handled for those two entity types only. exam_assignment is still never
 *  rendered, listed or mocked here: it is not an admin-managed type and no
 *  entry for it exists below.
 */

export interface BilimBagaEntityConfig {
  /** The entity_type string exactly as declared in
   *  priv/packs/bilimbaga/entity_definitions/<entityType>.json's `name`. */
  entityType: string
}

export const BILIMBAGA_ENTITY_TYPES: BilimBagaEntityConfig[] = [
  { entityType: 'category' },
  { entityType: 'question' },
  { entityType: 'answer_option' },
  { entityType: 'question_tag' },
  { entityType: 'exam' },
  { entityType: 'exam_section' },
  { entityType: 'exam_question_rule' },
  { entityType: 'exam_question_rule_tag' },
  { entityType: 'exam_manual_question' },
  { entityType: 'tag' },
]

export function isBilimBagaEntityType(entityType: string | undefined): boolean {
  return BILIMBAGA_ENTITY_TYPES.some((e) => e.entityType === entityType)
}
