# BilimBaga study T2a: the five roles mapped to Letflow roles

Written finding, read-only study (task T2a of `docs/migration/bilimbaga-retirement-status.md`, criterion 2).
No product code, test or requirement file is changed by it. Date: 2026-10-26.

Sources read in the BilimBaga repo (`c:\Users\tvolo\dev\ai-dala\BilimBaga`, HEAD `445216d`) and in this repo
(`docs/roles.md`, `lib/letflow/api/authorization.ex`, `lib/letflow/modules/exam/exam.ex`,
`lib/letflow/modules/exam/router.ex`).

## 1. The "five roles" are four roles in the database

`docs/product-summary-en.md` (line 25) says "five roles: Super Admin, Department Admin, HR Admin, Examiner,
Employee". The code does not have five:

- `backend/migrations/003_roles_departments.up.sql` seeds `super_admin`, `hr_admin`, `department_admin`, `employee`.
- `backend/migrations/005_rbac.up.sql` (line 6) runs `UPDATE roles SET name = 'examiner' WHERE name = 'hr_admin'`.
  `docs/requirements/FR-BB16.RBAC.md` (Description, AC-2) states the rename as intended.
- `backend/migrations/034_role_management.up.sql` marks exactly four roles `is_system`:
  `super_admin`, `department_admin`, `examiner`, `employee`.
- `docs/requirements/conformance/PR48-PR52-conformance-20261009.md` (row 1.9) says `hr_admin` is a dead entry
  ("The role does not exist in the DB") that still sits in frontend guards (`frontend/src/App.tsx`).

So HR Admin and Examiner are one role under two names; the fifth role is a documentation leftover. FR-BB117
(`docs/requirements/FR-BB117.Role-management.md`, migration 034) also lets a super admin create further custom
roles at runtime, so a production database may hold more than four rows; this study could not read a production
database, only the seeds.

## 2. Mapping table

Letflow side: the eight built-in roles of `docs/roles.md`. The set is closed (0046 D10: a module cannot create a
role). A tenant role is never mapped to PLATFORM_ADMIN.

| # | BilimBaga role | Evidence read (BilimBaga repo) | Letflow role | Verdict |
|---|---|---|---|---|
| 1 | `super_admin` | `backend/migrations/005_rbac.up.sql` ("super_admin: all permissions"); `backend/internal/deptscope/scope.go` `FromContext` (only role that is unrestricted); `backend/internal/users/service.go` `isOrgWide`; `backend/migrations/034_role_management.up.sql` (`roles:read`, `roles:manage` for it only) | `TENANT_ADMIN` | Mapped |
| 2 | `department_admin` | `backend/migrations/005_rbac.up.sql` (permission list); `backend/internal/deptscope/scope.go` (restricted to the caller's department subtree); `backend/internal/users/service.go` (line 146, may read users in own scope) | none | Gap |
| 3 | `hr_admin` | `backend/migrations/003_roles_departments.up.sql` (seed), `backend/migrations/005_rbac.up.sql` line 6 (renamed to `examiner`), `docs/requirements/conformance/PR48-PR52-conformance-20261009.md` row 1.9 | none (retired alias of `examiner`) | No mapping needed |
| 4 | `examiner` | `backend/migrations/005_rbac.up.sql` (permission list); `backend/migrations/018_manual_grading.up.sql` (grading); `backend/internal/deptscope/scope.go` (`ExamOwnerID`: may grade the exams it owns); `backend/internal/exams/service.go` line 535 | none | Gap |
| 5 | `employee` | `backend/migrations/005_rbac.up.sql` ("employee": `portal:read`, `portal:submit` only; FR-BB16 AC-7) | `CANDIDATE` | Mapped |

### 2.1 `super_admin` to `TENANT_ADMIN`

BilimBaga permissions (all of `users`, `questions`, `exams` read/write/assign, `reports`, `portal`, `tenant`,
`audit`, `roles` read/manage) are the tenant owner's. `docs/roles.md` says TENANT_ADMIN holds "every
tenant-scope permission in its own tenant: users, groups, role bindings, API tokens, settings, modules and
solutions, audit log". It also holds `ExamAuthoringWrite` through the core rules (router moduledoc of
`lib/letflow/modules/exam/router.ex`).

Permissions needed in Letflow: all tenant-scope permissions plus `ExamAuthoringWrite`, entity read/write for the
exam types, `UsersGroupsRolesManage`, audit read. All held by TENANT_ADMIN today. Not PLATFORM_ADMIN: BilimBaga's
`tenant:manage` is the customer's branding/settings, which is tenant scope in Letflow.

### 2.2 `employee` to `CANDIDATE`

`portal:read` (list assigned exams, own results) and `portal:submit` (take and submit an exam) are the
candidate flow. Letflow's CANDIDATE holds the six exam-session grants from the exam module manifest
(`lib/letflow/modules/exam/exam.ex`, `role_grants`: `ExamSessionStart`, `ExamSessionRead`, `ExamSessionSave`,
`ExamSessionSubmit`, `ExamSessionReportEvent`, `ExamCertificateIssue`) and `MyModulesRead`, nothing else.

Caveat: BilimBaga's employee is a staff member in a department; the department is a user attribute that drives
who sees the employee's results. That attribute is not a role question and is the subject of the department
criterion (criterion 1 of the status doc), not of this table. Also open: whether an employee ever needs a
TASK_WORKER grant (BilimBaga has no task concept for them, so no).

### 2.3 `department_admin`: gap

BilimBaga permissions (`005_rbac.up.sql`): `users:read`, `users:manage`, `questions:read`, `exams:read`,
`exams:assign`, `reports:read`; `018_manual_grading.up.sql` also grants it `grading` read and write, and
`008_categories_tags.up.sql` gives it read-only `tags`. Every query is cut to the caller's department subtree
(`deptscope.Predicate`, recursive CTE over `departments`).

Why no Letflow role fits:
- TENANT_ADMIN is tenant-wide and holds far more (settings, tokens, modules). Giving it to a department head
  breaks least privilege.
- TENANT_AUDITOR is tenant-wide read-only; it cannot manage users or assign exams.
- PROCESS_OPERATOR can assign tasks and watch instances but holds no user management and no exam-assignment
  permission, and its read is tenant-wide unless scope enforcement narrows it (`docs/roles.md`, "Known
  limitation: scoped approvers"; scope grants exist only for TASK_WORKER-style task routes and platform-role
  bindings with scope nodes).

Permissions it needs: read users of its subtree, manage (create/deactivate) users of its subtree, read question
bank (no write), read exams, assign exams to users of its subtree, read results/reports of its subtree. The
missing part is not the permission atoms but the department-scoped grant for entity data and user management.
Which route to take (a scoped grant of an existing role through the scope-node mechanism, or a new role) is an
owner decision; 0046 D10 closes the role set, so a new role is a decision-record change. Not decided here.

### 2.4 `examiner` (and `hr_admin`): gap

BilimBaga permissions (`005_rbac.up.sql`): `questions:read`, `questions:write`, `exams:read`, `exams:write`,
`exams:assign`, `reports:read`; plus grading (`018_manual_grading.up.sql`), categories and tags
(`008_categories_tags.up.sql`). Restricted to the caller's department subtree, except that it may grade exams it
owns even when the candidates are in another department (`deptscope.Scope.ExamOwnerID`).

Why no Letflow role fits:
- `ExamAuthoringWrite` (the exam builder routes `POST/PUT/DELETE /authoring/:entity_type`) is held only through
  the core rules, that is by PLATFORM_ADMIN and TENANT_ADMIN. The router moduledoc says CANDIDATE and
  PROCESS_OPERATOR do not hold it; `docs/roles.md` does not give it to PROCESS_DESIGNER (its list is definitions
  and entity definitions, not exam content). This confirms point 4 of the "Missing" list in
  `bilimbaga-retirement-status.md`: there is no exam-author role below TENANT_ADMIN.
- Making every examiner a TENANT_ADMIN gives them user, token, settings and module control: not acceptable.

Permissions it needs: `ExamAuthoringWrite`; entity read/write for the question bank, categories, tags and exams;
exam assignment; manual grading of sessions (read answers, write scores) with the owner exception; results read.
Gap: an exam-author/grader role below TENANT_ADMIN. `hr_admin` needs nothing separate.

## 3. Summary for the owner

| BilimBaga | Letflow | Needs |
|---|---|---|
| `super_admin` | `TENANT_ADMIN` | nothing new |
| `employee` | `CANDIDATE` | nothing new |
| `examiner` (= former `hr_admin`) | gap | a role (or module role grant) holding `ExamAuthoringWrite`, question bank/exam entity write, assignment and grading, below TENANT_ADMIN |
| `department_admin` | gap | department-scoped user management, exam assignment and results read |

Follow-ups, none of which this study decides: an owner decision on whether the closed role set (0046 D10) is
widened or the exam module grants `ExamAuthoringWrite` to an existing role; T2b screens depend on it. Also check
with the portfolio whether production BilimBaga holds custom roles created through FR-BB117 (see section 1).
