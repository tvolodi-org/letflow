# Stock lines editor in the browser: measured times at 100, 500 and 1000 lines (T-1533, BA item 7)

Measured in a real Chromium (Chrome for Testing 148.0.7778.96, headless, 1440x900) against the local GATE B stack
(`scripts/e2e/stack_up.sh`: real Keycloak sign-in, real backend, dev-server web build), never QA. Script:
`web/tests/e2e/perf-lines.e2e.spec.ts` (tagged `@manual @perf`, not in CI); data set: `scripts/e2e/perf_lines_seed.sh`.
Three runs per cell, each on a fresh receipt; milliseconds, median / max. The host is shared with other sessions, so read
the numbers as a bound, not as a benchmark.

Environment: Intel Core i7-8700 @ 3.20 GHz, 12 logical CPUs; 62 GB memory (`free -g`); PostgreSQL 16 (docker compose project
`letflow-e2e`); commit f5844aa96 plus this change; 2026-11-09. Same host as `stock-document-volume-2026-11.md` (server only, HTTP).

## How to run

See "Performance run (manual)" in `docs/testing/gate-b-browser-e2e.md`. Writes about 5,000 records per run (9 receipts, up to
1000 lines each, all posted): never against QA without the owner's OK.

## Data set (fixed, no randomness)

- 190 catalog items `PERF-0001..PERF-0190` (no lot tracking), one unit `PERF-PCS`, on top of the 4 GATE B items.
- A receipt of N lines (N = 100, 500, 1000): line i (0-based) has item `PERF-(i mod 190 + 1)`, quantity `1 + (i mod 7)`, no price.
  Every 50th line is invalid on purpose (quantity 0) for the validate step, then the list is pasted again valid.
- Rows enter by ONE multi-row paste of tab-separated text (the owner's workflow: Excel, paper lists).
- The lines repeat 190 items: the post number is for repeated items. Distinct items per line (worst case for the balance keys)
  stay with the server table in `stock-document-volume-2026-11.md`.

## Results

| operation | what is timed | 100 lines | 500 lines | 1000 lines |
|---|---|---|---|---|
| validate | paste of N rows (2% invalid) until the error button shows | 67 / 88 | 127 / 128 | 168 / 221 |
| validate (fix) | paste of the valid list until the error button is gone | 32 / 45 | 74 / 80 | 135 / 167 |
| save | click Save draft until the saved document shows | 1168 / 1458 | 4105 / 5957 | 11731 / 11826 |
| save, longest write request | the slowest non-GET request of the save (server share) | 802 / 811 | 3661 / 5425 | 10911 / 11057 |
| open | `goto` of the saved draft until count and first row show | 2386 / 2414 | 2569 / 2861 | 4892 / 6579 |
| scroll, total | 40 steps top to bottom and back | 1232 / 1363 | 1828 / 1920 | 2826 / 3208 |
| scroll, longest frame gap | worst gap between two frames while scrolling | 83 / 100 | 117 / 117 | 233 / 267 |
| scroll, max mounted rows | rows in the DOM at any step (virtualisation) | 31 / 31 | 31 / 31 | 31 / 31 |
| search | type a code until the filtered count shows | 121 / 193 | 179 / 215 | 144 / 167 |
| issue | click Issue and confirm until state Issued | 926 / 980 | 3009 / 3068 | 7320 / 7384 |
| post | click Complete on the posting task until the document shows Posted (the spec reloads the page in a poll, so this includes up to a few page loads) | 2459 / 2521 | 2432 / 2794 | 5422 / 6552 |

Heap after open at 1000 lines (`performance.memory.usedJSHeapSize`): 72.2 MB (one run, Chromium only).
"open" includes about 2.2 s of app start and session restore (the 100-line value is the floor).

## Limits and verdict

The first two limits come from the BA note (`docs/uat/ba-decisions/T-1518.md`, item 7) and are UAT assumptions still to be
confirmed by the owner; the rest are this task's own assumptions. Verdict at 1000 lines (median):

| limit | source | 1000 lines | verdict |
|---|---|---|---|
| open < 3 s | BA note, assumption | 4.9 s | MISS (100 lines: 2.4 s, so about 2.5 s is the 1000-line cost) |
| post < 10 s | BA note, assumption | Complete to Posted 5.4 s; Issue 7.3 s + Complete to Posted 5.4 s = 12.7 s | pass if "post" is the last step, MISS if issue and post are counted together; ask the BA which was meant |
| scroll, longest frame gap < 100 ms | own assumption | 233 ms (500 lines: 117 ms, 100 lines: 83 ms) | MISS from 500 lines |
| search < 500 ms | own assumption | 144 ms | pass |
| validate < 1 s | own assumption | 168 ms | pass |
| save < 15 s | own assumption | 11.7 s, of which the write request is 10.9 s | pass (server-bound) |
| virtualised rows | design of `useVirtualRows` | 31 rows mounted at 100, 500 and 1000 lines | pass |

## Limits found

- **Item catalog of the editor is one page of 200 items** (`web/src/modules/stock/register/stockPickers.ts`, `page_size: 200`).
  Measured: with 200 perf items plus the 4 GATE B items (204 in the tenant) a paste of PERF codes answered "item code
  PERF-0045 was not found" and "PERF-0058 was not found" (the 4 items outside the page, in no obvious order), the lines
  stayed flagged and Save draft did not complete until the codes were resolved. Any tenant with more than 200 items cannot
  paste codes of the rest. The data set therefore uses 190 perf items.
- The server cap is 1000 lines (`Shape.max_lines`); the editor shows "1000 of 1000" and refuses more (REQ-774). Not re-tested here.

## Findings to queue (no product code was changed: nothing was a clear, small client bug)

1. **Scroll jank grows with the line count although only 31 rows are mounted** (frame gap 83 / 117 / 233 ms at 100 / 500 /
   1000). `useVirtualRows` changes state only when the first or last row changes, but each such change re-renders the whole
   `LFLinesEditor`, so any O(n) work in its render body (view, error map, totals) runs per window change. Needs a profile
   before a fix; suspected, not proven.
2. **Open of a saved 1000-line draft takes 4.9 s** (limit 3 s): about 2.5 s above the 100-line floor; split between the fetch
   and the first render has not been measured.
3. **Item picker page of 200** (see above): raise or page the catalog resolve for pasted codes.
4. **Save of 1000 lines is server-bound** (10.9 s of 11.7 s is the write request) and **issue of 1000 lines takes 7.3 s**;
   server tuning, already listed in `stock-document-volume-2026-11.md`.

Notes on the method: the raw numbers are written to `web/test-results/perf-lines/<run tag>.json`, which Playwright clears at
the start of the next run, so copy the table printed at the end of a run. The tables above are from three runs: sizes 100 and
500 together, then 1000.
