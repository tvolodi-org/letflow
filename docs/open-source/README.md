# Open-source licence: DRAFT package (not in force)

> **Status: DRAFT for review by a lawyer. This is not legal advice and nothing here grants
> any right.** No file in this folder is a licence of the repository. There is deliberately
> **no `LICENSE` file at the repository root**, so GitHub does not detect one.
>
> **Decision (owner, portfolio D-116, 2026-11-10): the public Letflow repository is licensed
> under the MIT licence.** The earlier Apache-2.0 and AGPL-3.0 drafts (T-1598) are **not chosen**
> and were removed from this folder; the comparison is kept in section 1 for the record. Whether
> a closed corporate edition exists (T-1521 Q2, `docs/uat/ba-decisions/T-1521.md` section 9) is
> **still open**; section 2 says what MIT means for it.

Files in this folder (all drafts):

| File | What it is |
|---|---|
| `LICENSE-MIT.draft.txt` | MIT text (SPDX `MIT`), year 2026, copyright holder left as a placeholder |
| `README.md` | This file: decision, consequences, headers, switch-on order and steps |
| `NOTICE.draft` | Third-party notice skeleton and how to generate the full list |
| `CONTRIBUTING.draft.md` | Contribution rules with a DCO sign-off |
| `TRADEMARK.draft.md` | Name and logo policy |

## 1. Options considered (for the record)

| Question | MIT (chosen) | Apache-2.0 (not chosen) | AGPL-3.0 (not chosen) |
|---|---|---|---|
| Kind | Permissive, shortest text | Permissive | Strong copyleft with a network clause |
| May others use, change and sell it? | Yes | Yes | Yes |
| May others keep their changes secret? | Yes; they keep the copyright notice and licence text | Yes; notices kept, changed files marked | No, not for conveyed or network-served modified versions |
| Patents | **No express patent grant** | Express grant from every contributor, with retaliation | Express grant, with retaliation |
| "SaaS loophole" (a hoster gives nothing back) | Open | Open | Closed for modified versions only |
| Closed corporate edition | No obstacle; outside contributions under MIT may go into a closed build with the notice kept, no CLA needed | Same | Needs a CLA from day one |
| Corporate adoption | Usually accepted without discussion | Same | Some companies forbid AGPL |

T-1521 had recommended Apache-2.0 (patent grant); the owner chose MIT. A licence is chosen once
per release: code already published under one licence stays under it for those who received it.

## 2. What MIT means for the owner (plain words)

- **No patent grant.** MIT says nothing express about patents. Contributors and the owner give no
  written patent licence, and users get none beyond what the law implies. Apache-2.0 would have
  given one.
- **Anyone may host or sell it.** A cloud vendor or a competitor may run Letflow as a paid service,
  or sell copies, without paying or publishing anything. Nothing stops a hosting rival.
- **No copyleft.** Others may change it and keep their changes closed. They only have to keep the
  copyright notice and the MIT text with the copies they pass on.
- **Corporate modules stay closed.** Code the owner keeps out of the public tree (for example exam,
  procurement, enterprise features, the corporate edition) is not covered by the MIT licence of the
  public repository; MIT does not oblige the owner to publish it. Whether and how a corporate edition
  is sold is **T-1521 Q2, still open**; nothing in this package decides it.
- **Irrevocable in practice.** Everyone who received the code under MIT keeps the right; a later
  licence change applies only to later releases.
- **Name and logo are separate.** MIT licenses code, not the name "Letflow" or the brand files
  (see `TRADEMARK.draft.md`).
- **Warranty and liability** are excluded by the text itself.

## 3. Proposed file headers (SPDX)

One short header per source file, checked by a lint (a task of its own):

```
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 <copyright holder - owner to name>
```

Comment style per language: `#` for Elixir, shell and YAML, `//` for TypeScript and Dart,
`<!-- -->` for HTML/Markdown only where a header is wanted. Generated files, lockfiles, fixtures
and the font files carry no header. Package metadata fields move together with the licence:
`mix.exs` (`licenses: ["MIT"]` in `package/0`), `web/package.json` (`"license": "MIT"`),
`apps/mobile/pubspec.yaml` (no licence field: add a `LICENSE` note in the app folder). Closed parts
get `LicenseRef-Letflow-Proprietary` or are not in the public tree at all.

Who is the copyright holder, and whether each pilot contract leaves the code with us (Q6), must be
answered before any header is written.

## 4. Order: the root LICENSE comes last

**Do not add a root `LICENSE` file yet.** A licence covers everything in the repository **and its
history** that is published with it. So the file goes in only **after** the clean-up and history
step of **T-1599** (secrets audit of the history, documents review, removal of customer names and
closed parts, new squashed public repository, see T-1521 section 5). Adding it earlier would
license material that may still be removed, and, in the current repository, material that has not
been audited.

Order:
1. T-1599: clean-up and history step finished and checked (the public tree and history are what
   will be licensed).
2. Owner names the copyright holder (Q6) and a lawyer reviews the text set (Q8).
3. Switch-on (below), one commit in the public repository.

There is **no stop-gap README note** meanwhile: the owner has not answered the question. Today the
repository has no licence, which legally means "all rights reserved"; that stays until step 3.

## 5. Switch-on steps (after T-1599 and the owner's answers)

1. Verify the text against the official source (https://opensource.org/license/mit; or the SPDX
   template for `MIT`); only the copyright line may differ.
2. Fill in the copyright holder line, then `git mv docs/open-source/LICENSE-MIT.draft.txt LICENSE`
   (root, no extension; GitHub detects it).
3. `git mv docs/open-source/NOTICE.draft NOTICE`; fill in the generated third-party list (see
   `NOTICE.draft`). MIT requires the copyright notice and licence text to be kept in copies.
4. `git mv docs/open-source/CONTRIBUTING.draft.md CONTRIBUTING.md`; add the DCO check to CI.
5. `git mv docs/open-source/TRADEMARK.draft.md TRADEMARK.md`; fill in the owner's answers (Q5).
6. Add SPDX headers to the source files (script + lint) and set the metadata fields of section 3.
7. Add `SECURITY.md` (private reporting address) and a code of conduct (T-1521 section 3).
8. Keep or delete this folder; remove the word "DRAFT" from moved files.
9. Add the CI licence check (see `NOTICE.draft`, "CI check proposal").
10. Lawyer review of the final text set **before** the commit is made public.

Rollback before publication is a plain `git revert`; after publication a licence cannot be
withdrawn from those who already received the code.

## 6. What this draft does not do

- It is not legal advice and has not been reviewed by a lawyer. Licence, NOTICE, DCO and
  trademark text all need that review (Q8).
- It makes no trademark search and no claim that the repository is free of secrets.
- It does not choose the copyright holder, the contribution policy (Q3), the corporate edition (Q2)
  or the trademark policy (Q5).
