# oss_audit: what must not be public

Read-only scanner for the tracked tree and the full git history (T-1597). Python 3 stdlib only;
`gitleaks`, `trufflehog` and `git-filter-repo` are not installed on the team host, so it uses pattern
rules. It never changes the repository: it runs `git log`, `ls-files`, `rev-parse`, `rev-list`,
`for-each-ref` and `cat-file` only.

    scripts/oss_audit/oss_audit.sh --out /path/outside/the/repo/scan.tsv

| Option | Meaning |
|---|---|
| `--tree`, `--history` | scan only one of them (default: both) |
| `--rev-range R` | restrict the history scan (default `--all`); the coverage line then says INCOMPLETE |
| `--budget-seconds N` | wall-clock deadline for the whole run (default 900). At the deadline the git process group is killed, the run prints `PARTIAL` and exits 3. A failed git read, an unreadable tracked file or a history commit count that differs from `rev-list --all --count` prints `INCOMPLETE (...)` and exits 4 |
| `--format tsv\|json`, `--out FILE` | output format and target (default tsv on stdout) |
| `--include-noise` | also run the noise rules S14 (entropy) and I02 (private IPs) |
| `--repo DIR` | repository to scan (default: current directory) |
| `--check-file F` | scan one file with the secret rules only; exit 1 on a hit (used on the report) |

## Output

One row per finding: `scope` (tree or history), `path`, `commit` (12 hex, or `HEAD`), `rule`, `severity`
(C critical/rotate, H, M, L), `hint`, `seen_in`, `in_head`. The hint is the first two and last two characters of a
value of 12 or more characters (`ab..yz`), otherwise `**`; for e-mail it is the domain only, for names the keyword.
The matched text, the line and its context are never printed, and value hashes stay in memory. A `# summary` block
gives counts per rule and path class and a `# coverage` line (`COMPLETE`, `INCOMPLETE (reasons)` or `PARTIAL`).
**Keep the raw output out of the repository**: even masked hints are partial secrets.

## What it covers

History is read in one stream `git log --all -p -U0 -m --no-renames`: merge-resolution lines and renamed-and-edited
files are scanned as additions. Binary files seen in history are read with `git cat-file`; SQLite files (for example
`state/team.db`) are opened in memory and every table and column is scanned (path `file#table.column`); other
binaries get a strings-style pass. Scope of the tree scan: tracked files only, so an ignored local `.env` is not read.
The scanner and its test and the report are excluded from the scan (their text would match their own rules).

## Rules

Ids are stable (`rules.py`): S01-S14 secrets (private keys, AWS/GCP/Azure/Hetzner/Cloudflare/Keycloak/OpenAI/Anthropic/
GitHub/Slack/Stripe tokens, JWT, connection strings with credentials, password-like assignments, entropy),
P01 e-mail, P02 phone, I01/I02 IP addresses, I03 owner hostnames, N01 customer and company names, N02 local user paths.
To add a rule add a record to `RULES`; add a fixture line to `test/scripts/oss_audit_test.exs`.

A hit is a lead, not a verdict: triage is done by opening the file locally. Whether a credential is still live is
not tested (the audit never calls a service); treat an exposed credential as live until it is rotated.
