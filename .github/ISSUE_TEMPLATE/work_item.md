---
name: Work item (REQ or ISS)
about: One unit of work on the board. Filed by the sole filer after the overlap check.
title: "REQ-NNN: <short imperative title>   (or: ISS: <title>)"
---

<!--
Filing rules (docs/agents/protocols/WORK_BOARD.md):
- Only the sole filer runs `gh issue create --template work_item.md` , and only after the
  overlap check (open issues, open PRs' changed files, main).
- The issue number GitHub assigns is the only machine id. REQ-NNN stays a title prefix.
- Labels at filing: one of state:ready | state:blocked, one prio:1..3, one type:*, a stage:S<n>
  when it has one. Never claimed:* -- only the supervisor or the user sets a claim.
- Delete this comment block and any section that does not apply.
-->

## Context

What is wrong or missing, with evidence (file paths, command output, links). One paragraph
is fine; the worker must not need anything outside this issue plus the repo.

## Fix direction

What to change and where. Name the files. Say what is explicitly NOT in scope.

Depends on: #
<!-- One line, issue numbers only, e.g. `Depends on: #2301, #2305`. Leave the number
     empty or delete the line when there are no dependencies. The script gh_work.sh
     reads exactly this line. -->

blocked-on:
<!-- Only when filed as state:blocked: `blocked-on: #N` or one sentence naming what is
     awaited (a decision, an infra request). Delete the line otherwise. -->

## Acceptance criteria

- [ ] Each criterion is testable and names the command or file that proves it
- [ ] Quote real output in the closing comment; no "should work"

## Source

REQ id / ISS history id / original report, if any (history only; the issue number is the id).
