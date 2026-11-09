# Letflow guide for the company administrator (English)

Other languages: [Русский](ru.md) · [Қазақша](kk.md). The three files have the same sections in the same order.

This guide is for the person who administers Letflow for a company (the **TENANT_ADMIN** role). You do not need to be a developer. Menu names below are the English ones; the screen shows them in your language. There are no screenshots on purpose: they go stale. Each work screen also has its own **Help** link; this guide only gives the order of use.

Items marked **(to be confirmed)** are not yet decided by the Letflow owner. Do not promise them to your colleagues.

## 1. First sign-in

1. Open the address of your company's Letflow that you were sent. Enter your company short name (slug) if the page asks for it.
2. You are redirected to your company's own sign-in page and enter your e-mail and password there. Letflow itself does not store passwords.
3. The first administrator is named by e-mail when the company is registered. You become administrator at your first sign-in **only if** the e-mail you sign in with is the same one and has been verified by the sign-in service. Otherwise you sign in as an ordinary user: ask the platform operator.
4. After sign-in the menu shows only what your roles allow. If a menu item is missing, you do not hold the role for it (section 3).
5. If your session ends while you work, you are signed in again and a notice says so. Unsaved text in a form may need to be typed again.

## 2. Users and groups

* **Admin > Users** lists the people who have signed in. A person appears after their first sign-in; there is no password to set here.
* **Admin > Groups** holds groups. Roles are given to **groups**, and a person gets roles by being a member of a group. To change what a person may do, change their group membership.
* Add or remove a member from the group page. Both actions are written to the audit log.
* **Admin > Tokens** creates access tokens for programs (not for people). A token can have only roles that you and the person it is made for already hold. Keep the token text secret: it is shown once.

## 3. Roles: what each may do

Nine built-in roles exist; a company cannot add new ones. Full text: `docs/roles.md`.

| Role | Plain meaning |
|---|---|
| TENANT_ADMIN | You. Users, groups, roles, tokens, settings, modules, audit. Only inside your company. |
| PROCESS_DESIGNER | Builds process definitions and forms. Cannot cancel processes, complete tasks, manage users or read the audit. |
| PROCESS_OPERATOR | Runs live processes: start, cancel, assign tasks, failed-message queue, webhooks, audit and metrics. Cannot change definitions or users. |
| TASK_WORKER | Does assigned tasks. Sees only processes they started or hold a task in. |
| TENANT_AUDITOR | Reads everything (definitions, tasks, audit, metrics, records), changes nothing, cannot export. |
| STOREKEEPER | Warehouse clerk: stock documents, counts, balances. Cannot see the asset register, the audit log or administration. |
| CANDIDATE | An outside person sitting an exam. |
| AGENT_RUNNER | A machine account; no human uses it. |
| PLATFORM_ADMIN | Staff of the company that runs Letflow. It does not work inside your company and must never be given to your users. |

To give a person a role: put them in the group that holds the role. To move a role to another group use the rebind action on the role (a reason is required and is recorded in the audit).

## 4. Modules

* **Admin > Module lifecycle** and **Solution Packs** show which modules (for example Assets, Stock) are installed for your company and let you install or retire them.
* A module adds menu items and permissions; people see them only if they hold a matching role.
* Retiring or removing a module is a deliberate act. Read the confirmation text; do not do it to "see what happens".
* A new module version is rolled out by the platform operator, not by you.

## 5. Import of lists

1. Open **Admin > Import data**. Choose the list type (for example locations or opening asset lines).
2. Download the template, fill it in Excel (.xlsx), keep the header row, and upload the file.
3. The screen reports what was accepted and which rows were refused, each with the row number and the reason. Correct those rows in the file and upload again.
4. Large files are read slowly; during a big import ask colleagues to avoid heavy exports (the Metrics page may turn to Check).
5. Only types that have an import function can be imported. Help for the asset and stock screens is linked from those screens.

## 6. Audit log

**Admin > Audit** answers "who did what and when". Each row has the time, the user (by name, not by number), the action (for example *Document posted*, *Document reversed*, *Role binding changed*, *Token created*), the object and the address.

* Filter by user, object type, object id and date range (dates as ISO 8601, `YYYY-MM-DD`). "From" must not be later than "To".
* **Export CSV** saves the filtered rows. At most the first 10 000 rows are exported; if the screen says so, narrow the filters. The export itself is recorded in the log.
* Entries cannot be edited or deleted by anyone.

## 7. Metrics and health: what the colours mean

**Admin > Metrics** opens with a *Support summary*. Every figure has a status word and a symbol (never colour alone) and one sentence on what to do.

| Status | Meaning | What you do |
|---|---|---|
| OK (green) | Normal. | Nothing. |
| Check (amber) | Worth watching; users may notice slowness. | Look again in a few minutes. Avoid large imports and exports meanwhile. |
| Problem (red) | Something is failing. | Do what the sentence under the figure says. Write down the time and the route names shown, and send them to the platform operator. |
| No data / Not measured yet | Nothing to judge from. This is not an error. | Nothing. |

Typical red figures: *Errors per minute* (server fails some requests), *Slow database work*, *Event-store write speed* (saving is slow: do not click Save repeatedly), *Background refresh* (a background job stopped: tell the operator). The full table "for developers" is below the summary; you can ignore it.

## 8. When sign-in fails

| What you see | Likely cause | What to do |
|---|---|---|
| Wrong password or a locked account on the sign-in page | After about 5 wrong attempts the sign-in service locks the account for a few minutes (up to 15). | Wait, then try once with the correct password. Use the sign-in page's reset link if you forgot it. |
| "Too many attempts, try again later" (wait message) | Many failed attempts from one network address in a minute (about 10). | Wait the time shown and try again. A whole office behind one address can share the limit. |
| Signed in, but menu items are missing | You hold no role for them. | Ask a TENANT_ADMIN to put you in the right group. |
| "Your session expired and you were signed in again" | The session ended while you worked. | Sign in; re-enter any unsaved text. |
| The company is not found | A wrong company short name or address. | Check the address you were sent. |

Recovery of an administrator who cannot sign in at all (lost e-mail, no other admin): **(to be confirmed)**. Until the owner decides, ask the platform operator; there is no self-service route.

## 9. Backups

* Data of all companies is saved once a day on the server's disk by the platform operator, and kept 14 days. This protects against a mistake or a bad update.
* A backup on the same disk does **not** protect against loss of the whole server. **(to be confirmed)** whether and when an off-server copy is provided.
* Restoring one company's data from a backup, the guaranteed maximum data loss and the restore time are **(to be confirmed)**; for the demo they are targets, not promises. Production is not yet approved.
* You cannot start a backup or a restore yourself. Ask the platform operator, and say which company, what was lost and when it was last correct.
* Technical text for the operator: `docs/runbooks/backup-restore.md`.

## Where else to read

* Help links on the asset and stock screens (in the product).
* `docs/roles.md` for the exact role list.
* Your platform operator for anything marked *to be confirmed*.
