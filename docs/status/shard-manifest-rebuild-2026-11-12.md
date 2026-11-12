# Shard manifest rebuilt from fresh CI logs (2026-11-12, T-1815)

`test/shard_manifest.txt` was rebuilt with `scripts/test_shard_plan.sh --from-logs --partitions 32`
from the `--slowest-modules` blocks of the 56 shard job logs (8 shards) of the seven full-suite
`main` push runs among the last 30: 43107603767, 43115604009, 43146207194, 43167655448,
43174167504, 43186658496, 43187797623 (run and job ids are in the `# source:` header lines).
The other 23 of the 30 runs could not be used: 16 skipped the shard step (docs-only), and 7 ran a
selective subset (step "Write selective test plan" succeeded), which would skew per-file weights.
Format unchanged; `--append` on the result changes nothing; no test file changed.

## Why

Measured shard job durations (s) over those seven runs, sorted:

| Shard | Durations |
|---|---|
| 1 | 837 936 941 996 1155 1217 1235 |
| 2 | 720 763 896 903 934 1002 1230 |
| 3 | 1020 1205 1229 1334 1616 1648 1651 |
| 4 | 673 692 805 831 860 1065 1104 |
| 5 | 936 987 998 1016 1131 1308 1328 |
| 6 | 726 789 884 942 1210 1215 1266 |
| 7 | 625 658 754 782 802 817 843 |
| 8 | 655 667 691 801 1050 1057 1067 |

Medians: shard 3 1334 s, shard 5 1131 s, shard 1 996 s, shard 6 942 s, shard 2 903 s, shard 4 831 s,
shard 8 801 s, shard 7 782 s. Shard 3 is the long pole, shard 5 the second.

## Before and after (planned, not measured)

Weights are the new manifest's, in seconds per shard (four partitions), i.e. the mean share of each
run's module total scaled to the last run. "Old" is the previous partition assignment scored with
these weights; 216 files (7017 s) were not in the old manifest and ran by path hash, so they are
excluded from the old column.

| Shard | Old assignment | New assignment |
|---|---|---|
| 1 | 2009 | 2967 |
| 2 | 1960 | 2967 |
| 3 | 2754 | 2967 |
| 4 | 1850 | 2967 |
| 5 | 2318 | 2967 |
| 6 | 2047 | 2967 |
| 7 | 1779 | 2967 |
| 8 | 2001 | 2967 |

The new plan is flat by construction (every partition 742 s). The real effect has to be read from
the next full-suite `main` runs (runner speed varies about +-25 % between jobs); compare shard 3's
median with the others then.
