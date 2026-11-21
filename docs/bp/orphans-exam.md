# Orphans of the area exam

Every item of `python3 scripts/uat/bp_inventory.py exam` (15 routes, 13 screens, 2 rules) is used by a task of
`docs/bp/exam.json`; no inventory item is orphaned.

Not in the inventory, noted for the owner (not a listed orphan row): `Letflow.Modules.Exam.Authoring.create_assignment`
(`lib/letflow/modules/exam/authoring.ex:131`) is the only writer of `exam_assignment`; no route and no screen
calls it, only the mix seed task (REQ-582). Proposed action: give a process (an assignment screen and route),
otherwise assignment stays a seed-only platform function. The owner decides.

| function | file:line | what it does | history | why it exists | proposed action |
|---|---|---|---|---|---|
