# state:ready issues against main, 2026-11-11

Task T-1748 (B13#1), source `docs/uat/ba-decisions/T-1739.md` item 1. Docs only: no issue was closed, relabelled or commented.

## How it was made

* List: `gh api -X GET "repos/tvolodi-org/letflow/issues?state=open&labels=state:ready&per_page=100" --paginate`, pull requests excluded: 59 issues, taken at main `af12a9f69`.
* For each REQ id: `git log origin/main --grep "REQ-N(?![0-9])" -P`, minus the "Next-priority candidates" batch commits, then the squash-merge PR number from the subject, then the PR body (`gh api repos/tvolodi-org/letflow/pulls/<n>`): the `Closes` / `Refs` lines. Plus the issue timeline (`cross-referenced` pull requests).
* A commit title naming a requirement is not delivery. `Closes #N` in a merged PR is delivery; `Refs #N` is not (the remainder it names is quoted).
* Limit: a build PR that names neither the REQ id nor the issue number is not found, so an OPEN row means "no merged evidence found", not "proved unbuilt".

## Verdicts

| Verdict | Meaning | Rows |
|---|---|---|
| DELIVERED | a merged PR says `Closes #N` and the issue is still open: needs confirm and close | 1 |
| PROBABLY DELIVERED | the build or the docs the requirement asks for is on main, but no merged PR says `Closes #N`; the operator checks the acceptance list before closing | 18 |
| PARTIAL | merged PRs `Refs` the issue and name a remainder that is not on main | 17 |
| OPEN | no merged build found (requirement entry only, or nothing) | 22 |
| N/A | not a requirement issue | 1 |

## Delivered, needs confirm/close

| Issue | Requirement | Verdict | Evidence |
|---|---|---|---|
| #3796 | REQ-732 | DELIVERED | PR 3819 merged with `Closes #3796`; the issue is still open. |

## Probably delivered, needs the operator to confirm

| Issue | Requirement | Verdict | Evidence |
|---|---|---|---|
| #4215 | REQ-805 | PROBABLY DELIVERED | Docs-only design note PR 4216 merged; body does not name #4215. |
| #4211 | REQ-804 | PROBABLY DELIVERED | Build PR 4217 (and requirement PR 4212) merged; neither body names #4211, so no `Closes`. |
| #4209 | REQ-803 | PROBABLY DELIVERED | Addendum PR 4236 merged (`Refs`, remainder = the sweep build); build PR 4245 merged. The requirement is docs only, so 4236 covers it. |
| #4191 | REQ-802 | PROBABLY DELIVERED | Docs-only proposal note PR 4192 merged; body does not name #4191. |
| #4188 | REQ-795 | PROBABLY DELIVERED | Window and operator screen PR 4173 merged (`Refs #4155`, not #4188). |
| #4187 | REQ-800 | PROBABLY DELIVERED | Requirement-only task: entry amended by PR 4190, verdict PR 4179, one producer built by PR 4194 (`Refs REQ-800`, no issue number). |
| #4186 | REQ-799 | PROBABLY DELIVERED | Replay screen PR 4175 merged; body `Refs #4151`, not #4186. |
| #4153 | REQ-787 | PROBABLY DELIVERED | Fleet driver PR 4133 merged (`Refs #3915`, "REQ-787 has no issue of its own yet"); parts 2 and 3 by PR 4173. |
| #4152 | REQ-792 | PROBABLY DELIVERED | PR 4161 merged, `Refs #4152` with no remainder named; title says "part 1". |
| #4135 | REQ-788 | PROBABLY DELIVERED | Build PR 4163 merged (reset-password route with mail); body does not name #4135. |
| #4037 | REQ-782 | PROBABLY DELIVERED | Docs-only decision record PR 4038 merged; PR 4047 `Refs #4037` names G5 posting as remainder, which is another requirement. |
| #3988 | REQ-774 | PROBABLY DELIVERED | Server part 1 PR 3999 merged (`Refs #3988`); the remainder named is the client part, which is REQ-775. |
| #3880 | REQ-740 | PROBABLY DELIVERED | PR 3913 merged (`Refs #3880`); the tests it leaves belong to REQ-741. |
| #3873 | REQ-747 | PROBABLY DELIVERED | Mobile slice PR 3946 merged (`Refs #3873`); only the real-device microphone check is left out. |
| #3723 | REQ-689 | PROBABLY DELIVERED | Docs-only specification PR 3869 merged (`Closes #3871`, a different issue). |
| #3674 | REQ-680 | PROBABLY DELIVERED | Docs-only decision record PR 3731 merged (`Refs #3674`); its only open item is the CI criterion left to the merge queue. |
| #3567 | REQ-639 | PROBABLY DELIVERED | PR 3821 merged (`Refs #3567`); remainder named is UAT scenarios, a later task, not an acceptance criterion of the build. |
| #3503 | REQ-626 | PROBABLY DELIVERED | Parts A (PR 3817) and B (PR 3867) merged, both `Refs #3503`; part B lists the criteria that were left in part A. |

## Partial: a named remainder is still open

| Issue | Requirement | Verdict | Evidence |
|---|---|---|---|
| #4227 | REQ-807 | PARTIAL | Backend PR 4260 merged (`Refs #4227`, remainder: infra provisioner side and wire-contract check). Runbook PR 4275 (`Closes #4227`) is closed and NOT merged. |
| #4014 | REQ-781 | PARTIAL | PR 4022 merged (`Refs #4014`); remainder: mobile ARB and print-table checks. |
| #3919 | REQ-769 | PARTIAL | PR 3931 merged (`Refs #3919`); remainder: upgrade apply, dry run, audit, admin action. |
| #3915 | REQ-773 | PARTIAL | PR 4114 merged (`Refs #3915`); remainder: fencing token, resumable runner, cutover lock_timeout, capacity and progress block. |
| #3901 | REQ-760 | PARTIAL | PR 4026 merged (`Refs #3901`); remainder: pair reversal, card retirement, refusal after a card moved. |
| #3900 | REQ-761 | PARTIAL | No commit names REQ-761. PR 4029 (C16 web screen) is probably its build but says `Refs #3902`; remainder: reverse action in the UI. |
| #3899 | REQ-762 | PARTIAL | PR 3973 merged (`Refs #3899`); remainder: end-to-end test of `asset_kind_locked`. |
| #3889 | REQ-753 | PARTIAL | PR 4003 merged (`Refs #3889`); remainder: card org_unit_id sync on hand over, `assets_card` handler target. |
| #3888 | REQ-754 | PARTIAL | PR 3966 merged but its body says `Refs #3894`, not #3888; the employee lookup answers `:none` until the register lands. |
| #3879 | REQ-741 | PARTIAL | PR 3926 merged (`Refs #3879`); "the issue's remaining slices are not part of this change". |
| #3772 | REQ-728 | PARTIAL | PR 3801 merged (`Refs #3772`); remainder: masked-leg file test. |
| #3763 | REQ-718 | PARTIAL | PRs 3833 and 3884 merged (`Refs #3763`); remainder: the count freeze (split plan row C7). PR 4066 built the freeze but closed #3906. |
| #3761 | REQ-720 | PARTIAL | PR 3854 merged (`Refs #3761`); remainder: criterion 3 (post, posting record, reverse) and REQ-718-only messages. |
| #3749 | REQ-712 | PARTIAL | PR 3805 merged (`Refs #3749`); remainder: REQ-713 posting handler, reversal and cancel. |
| #3742 | REQ-704 | PARTIAL | PRs 3803 and 3855 merged (`Refs`); remainder: harness screens for the as-of state. |
| #3736 | REQ-701 | PARTIAL | PR 3822 merged (`Refs #3736`); remainder: freeze C7 and a REQ-701 text amendment. |
| #3389 | REQ-603 | PARTIAL | PR 3828 merged (`Refs #3389`); remainder: part B (DocumentsPurge permission, Purge module, events, audit, shared-bytes count). |

## Open: no merged build

| Issue | Requirement | Verdict | Evidence |
|---|---|---|---|
| #4246 | REQ-814 | OPEN | Only requirement PR 4247 (entry) is on main; no build. |
| #4243 | REQ-813 | OPEN | Only requirement PR 4244 (entry) is on main; no build. |
| #4233 | REQ-811 | OPEN | PR 4259 built the PIN sign-in of REQ-810 (`Closes #4234`); no passkey or WebAuthn code on main (batch 13 BA note). |
| #4073 | REQ-786 | OPEN | Only requirement PR 4074 is on main; no rollout runbook build found. |
| #4058 | REQ-784 | OPEN | Only requirement PR 4059 is on main; PR 4047 is the G6 import, but names #4037, not #4058: check by hand. |
| #4057 | REQ-785 | OPEN | Only requirement PR 4059 is on main; no readiness runbook build found. |
| #4016 | REQ-780 | OPEN | No commit names REQ-780. |
| #3997 | REQ-776 | OPEN | Only the mapping PR 3998 names REQ-776. |
| #3996 | REQ-777 | OPEN | Only the mapping PR 3998 names REQ-777. |
| #3995 | REQ-778 | OPEN | Only the mapping PR 3998 names REQ-778. |
| #3987 | REQ-775 | OPEN | Only docs PR 3993 merged; it marks REQ-775 SUPERSEDED. Not built; operator decides whether to close as obsolete. |
| #3905 | REQ-766 | OPEN | No commit names REQ-766. |
| #3891 | REQ-751 | OPEN | Only PR 4038 mentions REQ-751; no build. |
| #3887 | REQ-755 | OPEN | No commit names REQ-755. |
| #3886 | REQ-756 | OPEN | No commit names REQ-756. |
| #3885 | REQ-757 | OPEN | Only requirement PRs 3896 and 3904 name REQ-757. |
| #3881 | REQ-739 | OPEN | Only requirement PR 3882 names REQ-739. |
| #3878 | REQ-742 | OPEN | No commit names REQ-742. |
| #3877 | REQ-743 | OPEN | No commit names REQ-743. |
| #3876 | REQ-744 | OPEN | No commit names REQ-744. |
| #3875 | REQ-745 | OPEN | No commit names REQ-745. |
| #3375 | REQ-600 | OPEN | Only requirement PR 3376 names REQ-600. |

## Not a requirement

| Issue | Requirement | Verdict | Evidence |
|---|---|---|---|
| #3137 | - | N/A | Not a requirement (team:improvement, prio 2): outside the planner scope, left for the operator. |

## Notes for the operator

* PR 4275 (`Closes #4227`, runbook lines for `LETFLOW_REALM_USERS_ENABLED`) is closed without a merge; its content is not on main.
* PR 4004 (`Closes #3903`) and PR 4066 (`Closes #3906`) did close their own issues; the neighbours #3901 and #3763 stay PARTIAL.
* Several issues have no pointer from the build PR (REQ-787 "has no issue of its own yet", REQ-800, REQ-799, REQ-754): the `gh:` pointer in `docs/requirements.yaml` and the PR body disagree. Only the operator can fix the pointer or close.
