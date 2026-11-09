# Open-source licence: DRAFT package (not in force)

> **Status: DRAFT for review by a lawyer. This is not legal advice and nothing here grants
> any right.** No file in this folder is a licence of the repository. There is deliberately
> **no `LICENSE` file at the repository root**, so GitHub does not detect one. The licence choice
> waits for the owner's answer to **Q2** (business model) in
> [`docs/uat/ba-decisions/T-1521.md`](../uat/ba-decisions/T-1521.md) section 9. Background and the
> edition split (Community vs Corporate) are in the same note, sections 1-5.

Files in this folder (all drafts):

| File | What it is |
|---|---|
| `LICENSE-APACHE-2.0.draft.txt` | Official Apache-2.0 text, fetched from apache.org (`LICENSE-2.0.txt`) |
| `LICENSE-AGPL-3.0.draft.txt` | Official AGPL-3.0 text, fetched from gnu.org (`agpl-3.0.txt`) |
| `README.md` | This file: comparison, headers, switch-on steps, stop-gap question |
| `NOTICE.draft` | Third-party notice skeleton and how to generate the full list |
| `CONTRIBUTING.draft.md` | Contribution rules with DCO (Apache path) and CLA (AGPL path) |
| `TRADEMARK.draft.md` | Name and logo policy |

The two licence texts are copied unchanged; verify them against the sources before the switch
(see "Switch-on steps", step 1).

## 1. The two options in plain words

| Question | Apache-2.0 | AGPL-3.0 |
|---|---|---|
| Kind | Permissive | Strong copyleft with a network clause |
| May others use, change and sell it? | Yes | Yes |
| May others keep their changes secret? | Yes, they only keep notices and mark changed files | Not if they pass the program on (conveying) or let users use a modified version over a network: they must offer those users the full source of the modified version, under AGPL |
| What does it force on a company that embeds Letflow in its own product? | Notices only | The combined work generally has to be AGPL too (how far "combined" reaches is a legal question) |
| Patents | Express patent grant from every contributor; a contributor who sues over the work loses the grant (section 3) | Also an express patent grant (sections 10-11), with a similar retaliation effect |
| "SaaS loophole" (a hoster runs it and gives nothing back) | Open: anyone, including a cloud vendor, may host a modified copy and publish nothing | Closed for modified versions (section 13). Not closed for an unmodified copy: running it unchanged adds no duty |
| Effect on a closed Corporate Edition built by us | None for our own code: we own it and may license it any way. Others' Apache contributions may go into a closed build (keeping notices) without a CLA | Our own code: same. But **outside contributions under AGPL** can go into a closed build only if we hold the right to relicense them, i.e. a CLA or copyright assignment from day one |
| Dual licensing (AGPL for the community, paid commercial licence for those who cannot accept AGPL) | Not needed | Possible, but only for code we own or have the right to relicense |
| Corporate adoption | Usually accepted without discussion | Some companies forbid AGPL by policy; this can reduce adoption (not measured here) |
| Fits when | Aim is adoption and a community; money comes from the corporate edition, hosting and support | A hosting rival is the real fear, or dual licensing is the business model |

Recommendation of T-1521 (unchanged here): **Apache-2.0** for the Community Edition; **AGPL-3.0
with a CLA** is the fallback if the owner answers Q2 with "a hoster copying us is the real fear".
A licence is chosen once per release: code already published under one licence stays under it for
those who received it. So: choose first, publish second.

Both texts are compatible with the direct dependencies seen so far (Apache-2.0, MIT, BSD, ISC);
transitive npm and pub packages are **not yet verified** (see `NOTICE.draft`).

## 2. Proposed file headers (SPDX)

One short header per source file, checked by a lint (a task of its own after the decision):

Apache-2.0 path:

```
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) <year> <copyright holder - owner to name>
```

AGPL path (dual licence):

```
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) <year> <copyright holder - owner to name>
```

Comment style per language: `#` for Elixir, shell and YAML, `//` for TypeScript and Dart,
`<!-- -->` for HTML/Markdown only where a header is wanted. Generated files, lockfiles, fixtures
and the font files carry no header. Package metadata fields move together with the licence:
`mix.exs` (`licenses:` in `package/0`), `web/package.json` (`"license"`), `apps/mobile/pubspec.yaml`
(no licence field: add a `LICENSE` note in the app folder). Closed parts (exam, procurement,
enterprise features, mobile until scanned) get `LicenseRef-Letflow-Proprietary` or are not in the
public tree at all.

Who is the copyright holder, and whether each pilot contract leaves the code with us (Q6) must be
answered before any header is written.

## 3. Switch-on steps (once the owner decides)

Pre-conditions (from T-1521 section 5, not done by this draft): the history secrets audit, the
documents review, the third-party scan, the security posture review and a new squashed public
repository. The steps below only cover the legal files. One commit, in the public repository:

1. Verify the text: compare the chosen draft with the official source (`curl -fsSL
   https://www.apache.org/licenses/LICENSE-2.0.txt | diff - docs/open-source/LICENSE-APACHE-2.0.draft.txt`,
   or `https://www.gnu.org/licenses/agpl-3.0.txt` for AGPL); no difference expected.
2. `git mv docs/open-source/LICENSE-<chosen>.draft.txt LICENSE` (root, no extension; GitHub detects it).
3. Delete the other licence draft.
4. `git mv docs/open-source/NOTICE.draft NOTICE`; fill in the generated third-party list (see
   `NOTICE.draft`). Apache-2.0 requires NOTICE to travel with redistributions.
5. `git mv docs/open-source/CONTRIBUTING.draft.md CONTRIBUTING.md`; keep only the DCO section
   (Apache) or the CLA section (AGPL). Add the DCO check or CLA bot to CI.
6. `git mv docs/open-source/TRADEMARK.draft.md TRADEMARK.md`; fill in the owner's answers (Q5).
7. Add SPDX headers to the source files (script + lint) and set the metadata fields of section 2.
8. Add `SECURITY.md` (private reporting address) and a code of conduct (T-1521 section 3).
9. Move this README to `docs/open-source/README.md` of the public repo only if it should stay public;
   otherwise delete the folder. Remove the words "DRAFT" from the moved files.
10. Add the CI licence check (see `NOTICE.draft`, "CI check proposal").
11. Lawyer review of the final text set **before** the commit is made public.

Rollback before publication is a plain `git revert`; after publication a licence cannot be
withdrawn from those who already received the code.

## 4. Is a STOP-GAP needed until the decision?

Today the repository is public with **no licence**. Legally that means "all rights reserved":
others may read and fork it on GitHub (GitHub's terms allow viewing and forking inside GitHub) but
have no right to use, copy or distribute it elsewhere. Nobody gets an open-source licence by
accident, which is the safe default; this is why no root `LICENSE` is added.

A **stop-gap note** would be a short root-README paragraph such as "Source is visible for reading.
All rights reserved. No licence to use, copy, modify or distribute is granted until a licence is
published." It would:

- make the position explicit for readers (today it is only implicit), and reduce the chance
  someone assumes a free licence;
- add nothing legally that silence does not already do, and it is not a replacement for the lawyer;
- imply a public statement the owner may not want (it says "view only" while the plan is open
  source), and it would have to be removed at switch-on (step 9);
- not solve Q1 (public vs private now): the history has not been audited for secrets, and a note does
  not stop anyone from reading what is already public. Only making the repository private does.

**Not added by this task.** The operator asks the owner: (a) add the note, (b) make the repo private
until clean-up (Q1), or (c) leave as is.

## 5. What this draft does not do

- It is not legal advice and has not been reviewed by a lawyer. Licence, NOTICE, DCO/CLA wording and
  trademark text all need that review (Q8).
- It makes no trademark search and no claim that the repository is free of secrets.
- It does not choose the copyright holder, the contribution policy (Q3) or the trademark policy (Q5).
