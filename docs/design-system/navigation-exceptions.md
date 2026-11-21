# Pages outside the main menu

Owner checklist item 22: every built page needs a plain menu name or an explicit
exception below. `navGuardParity.test.tsx` checks the live router, including module
routes, against this table. Dynamic detail and action pages belong to their list
entry; they do not each need their own menu item.

| Route | Entry point or reason |
| --- | --- |
| `/` | Sign-in landing page and company home. |
| `/*` | Unknown URL error page. |
| `/__harness/:screen/*` | Development-only screen fixtures; excluded from production builds. |
| `/admin/appearance` | Appearance link in the shell settings menu. |
| `/admin/assets/counts/:id` | Selected count from Asset counts. |
| `/admin/assets/documents/:id` | Selected asset document. |
| `/admin/assets/documents/new` | New action on Asset documents or a card. |
| `/admin/assets/help/:topic` | Help links on asset screens. |
| `/admin/bilimbaga` | Legacy exam administration landing route. |
| `/admin/bilimbaga/:entityType` | Exam entity browser from exam administration. |
| `/admin/bilimbaga/exam-builder/:examId` | Builder action on an exam. |
| `/admin/maintenance/requests/:id` | Selected request from Maintenance requests. |
| `/admin/maintenance/requests/new` | Report a problem action on Maintenance requests and on an asset card. |
| `/admin/onboarding` | Alias of Register Tenant. |
| `/admin/onboarding/:onboardingId/progress` | Registration progress after submission. |
| `/admin/onboarding/:onboardingId/result` | Registration result after completion. |
| `/admin/questions/:recordId/edit` | Edit action on a question. |
| `/admin/questions/new` | New action on Questions. |
| `/admin/stock/counts/:id` | Selected stock count. |
| `/admin/stock/documents/:id` | Selected stock document. |
| `/admin/stock/documents/new` | New action on Stock documents. |
| `/admin/stock/help/:topic` | Help links on stock screens. |
| `/admin/stock/workbook-import` | Opened from the Load balances from Excel button on the Balances screen (REQ-887). |
| `/admin/tenants/:slug/edit` | Edit action on Tenants. |
| `/admin/users/:userId` | Selected user. |
| `/admin/users/import` | Import action on Users. |
| `/auth/callback` | Identity-provider callback, never a user destination. |
| `/dashboard` | Company home reached from the shell logo. |
| `/definitions/:id` | Open process action on Business processes. |
| `/definitions/:id/promotions/:reviewId` | Selected promotion review. |
| `/definitions/:id/rollback` | Rollback action on an active process. |
| `/definitions/new` | New process action on Business processes. |
| `/entities/:entityType` | Entity lists reached from their module. |
| `/entities/:entityType/reports` | Report builder reached from Reports. |
| `/exam/:examId/session` | Start or resume an exam. |
| `/exam/grading/:sessionId/:questionId` | Selected grading question. |
| `/exam/results` | Results link from the exam screen. |
| `/exam/sessions/:sessionId/result` | Result of one exam session. |
| `/help/:topic` | Contextual Help links. |
| `/instances/:id` | Selected instance. |
| `/instances/:id/attachments/:attachmentId` | Attachment link within an instance. |
| `/login` | Public sign-in entry. |
| `/me/problem-reports` | My reports link in the shell top bar and the receipt of Report a problem. |
| `/me/settings` | My settings link in the shell. |
| `/platform-dashboard` | Platform home selected for platform users. |
| `/solution-packs/:packId/overrides` | Overrides action within a solution pack. |
| `/solution-packs/:packId/update-review` | Review opened by the pack update launcher. |
| `/verify/:handle` | Public certificate link provided to its holder. |

Legacy routes above are exceptions to main-menu placement, not evidence that an
action exists on every deployment. New top-level features must have a menu entry;
do not silently add an exception just to make this guard pass.
