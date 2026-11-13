# QA/UAT note: a storekeeper-only user sees only own and group tasks (roles stage 0 S0-5)

Since the `TasksReadAll` change (T-1857, ruling T-1850 in `docs/design/storekeeper-task-visibility-ruling.md`), the
task read routes `GET /tasks`, `GET /tasks/inbox` and `GET /tasks/:id` decide by permission, not by role name.

What changed:
- A user whose only reading role is STOREKEEPER (no TASK_WORKER, none of the five roles below) used to see every task
  of the tenant in My Tasks. Now it sees only tasks addressed to the user, to one of its groups, or to one of its roles
  (for example tasks routed to the `STOREKEEPER` role). Unassigned tasks are no longer listed for it either.
- `GET /tasks/:id` of another person's task answers 404 (the same answer as for an id that does not exist).

What stays the same:
- PLATFORM_ADMIN (platform tenant), PROCESS_DESIGNER, PROCESS_OPERATOR, TENANT_ADMIN and TENANT_AUDITOR hold
  `TasksReadAll` and keep seeing every task of the tenant.
- A TASK_WORKER (also one who is a STOREKEEPER too) was already filtered and is unchanged.
- Stock counts and stock documents are module documents, not tasks (ruling point 7 / 2.4): they are not affected.
  Count and approval tasks routed to the storekeeper still reach it.

For testers: if a storekeeper-only test user no longer sees a task in My Tasks that it does not own, that is the
intended result, not a defect. Use a TENANT_ADMIN or PROCESS_OPERATOR to see the whole queue.
