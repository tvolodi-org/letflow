# Bandit advisories: are they reachable on QA and demo? (2026-11-11)

Task T-1741, queued by the operator after the PM's order of 2026-11-11 (D-117: nothing goes to demo or
production without the owner; the fix goes through QA/CD only). This is a read-only audit of the repository.
Nobody logged into a host and nothing was probed over the network. What the repository cannot show is listed as
questions for infra at the end.

## Short answer

| Advisory | What it hits | Verdict from the repository |
|---|---|---|
| EEF-CVE-2026-108525 (GHSA-c3g7-2pg5-qvwh) | HTTP/2 inbound flow control; memory exhaustion | **Not reachable from the internet** if the reverse proxy is the nginx form kept in `deploy/nginx/`. **Reachable** for anything that can open a TCP connection to the Bandit port directly (a process on the host, a container on the same Docker network). |
| EEF-CVE-2026-105659 (GHSA-69m6-wcv4-rwcf) | HTTP/2 send deadlines that reset; stream processes held open | Same as -108525. |
| EEF-CVE-2026-114216 (GHSA-w5wc-g2hc-g7m2) | HTTP/1.1 chunk extensions; request smuggling past a front proxy | **Not reachable** with the nginx form in the repository, because nginx reads the chunked body itself and sends its own framing upstream. Without a proxy in front, the advisory says Bandit is not affected. |

All three affect the Bandit version we ship. The two HIGH advisories are most likely -108525 and -105659. Both
are HTTP/2 only, both are reachable only by a peer that speaks HTTP/2 to Bandit itself, and the repository shows
no such peer on the public path. The open point is the QA and demo vhosts and anything else on those hosts. Those
files are not in this repository (questions Q1 to Q7).

## 1. What we run

- `mix.lock` resolves `bandit` 1.12.5, `thousand_island` 1.5.0 and `hpax` 1.0.4. `mix.exs` asks for
  `{:bandit, "~> 1.5"}`.
- Affected ranges (OSV records `https://api.osv.dev/v1/vulns/<id>`, sourced from `https://cna.erlef.org/osv/<id>.json`,
  read 2026-11-11):
  - EEF-CVE-2026-114216: from 1.12.4 to before 1.14.0. CWE-444. CVSS 4.0 `AV:N/AC:L/AT:P/PR:N/UI:N/VC:N/VI:L/VA:N/SC:L/SI:L/SA:N`.
  - EEF-CVE-2026-108525: from 0.3.1 to before 1.14.0. CWE-770. CVSS 4.0 `AV:N/AC:L/AT:N/PR:N/UI:N/VC:N/VI:N/VA:H/SC:N/SI:N/SA:N`.
  - EEF-CVE-2026-105659: from 1.4.0 to before 1.13.0. CWE-400. CVSS 4.0 `AV:N/AC:L/AT:N/PR:N/UI:N/VC:N/VI:N/VA:H/SC:N/SI:N/SA:N`.
  - So 1.12.5 is affected by all three, and **1.14.0 fixes all three**.
- The records give CVSS vectors, not a HIGH/MEDIUM label. "The two HIGH" comes from the operator's order. The
  two records with `VA:H` and no attack precondition (`AT:N`) are -108525 and -105659, so this note takes those as
  the HIGH pair. -114216 has `AT:P` (it needs a particular proxy in front) and only low integrity impact.

## 2. Is HTTP/2 enabled on the Bandit listener? Yes.

- Bandit is started in one place only, `Letflow.Supervisor.Http.http_child/0` (`lib/letflow/supervisor/http.ex`):
  `{Bandit, plug: Letflow.Router, port: Application.fetch_env!(:letflow, :http_port)}`. No `http_2_options`,
  `http_1_options`, `thousand_island_options`, `scheme`, `ip`, `certfile` or `keyfile` option is passed.
  `grep -rn -i "bandit\|thousand_island\|http_2\|http2" config/ mix.exs` finds only the `mix.exs` dependency line and a comment about it,
  so nothing in `config/` (including `runtime.exs` and `prod.exs`) changes the listener. `config/runtime.exs`
  sets only `http_port` (from `PORT`, default 4000).
- Bandit 1.12.5 (`deps/bandit/lib/bandit.ex`, `init/1`) does
  `Keyword.pop(http_2_options, :enabled, true)`, so **HTTP/2 is on by default**. HTTP/1 is on too.
- With no TLS (`scheme` defaults to `:http`), there is no ALPN. `Bandit.InitialHandler.handle_connection/2`
  (`deps/bandit/lib/bandit/initial_handler.ex`) then sniffs the first bytes of each connection. If they are the
  HTTP/2 preface `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n` it switches to `Bandit.HTTP2.Handler`; otherwise it serves
  HTTP/1. **A client that sends the HTTP/2 preface straight away (h2c "prior knowledge") gets HTTP/2 on the
  plain-text port.**
- The release image listens on 4000 (`deploy/Dockerfile`: `EXPOSE 4000`, `CMD ["bin/letflow", "start"]`).
  Without an `ip` option Bandit binds every interface inside the container.

## 3. What sits in front (as far as the repository shows)

| Environment | Published Bandit port (from the repo) | Proxy in the repo | Source |
|---|---|---|---|
| QA (`qa.bizdala.com`) | `127.0.0.1:3201:4000` | **Not in the repo.** `deploy/nginx/letflow-test.conf` says "QA's vhost lives outside this repository". `docs/runbooks/qa-tenant-subdomain-host-resolution.md` says the upstream is `127.0.0.1:3201` and DNS/TLS/upstream are infra's. `deploy/redeploy-qa.sh` mentions nginx serving the web dist and a public check "through nginx and TLS". | `deploy/docker-compose.qa.yml` |
| test (`letflow-test.ai-dala.com`) | `127.0.0.1:3113:4000` | `deploy/nginx/letflow-test.conf`: Cloudflare edge, then nginx `listen 443 ssl` (no `http2` on the listener), `proxy_pass http://127.0.0.1:3113;` with `proxy_http_version 1.1;`. | `deploy/docker-compose.test.yml` |
| demo (`demo.letflow.ai-dala.com`) | Not in the repo. `docs/runbooks/demo-operator-inputs.md` (O2) runs the smoke path against `BASE_URL=http://127.0.0.1:3311`, so a loopback port 3311 is likely. | **Not in the repo.** `docs/runbooks/demo-instance.md` ("Who owns what") gives the hosts and the reverse proxy to infra. `demo-operator-inputs.md` mentions "an nginx redirect" and "the nginx address" and asks for `proxy_read_timeout 60s` and `client_max_body_size 5m`, so the proxy is nginx, but its upstream directives are not in the repo. | runbooks only |
| PWA static site | none (static files) | `deploy/nginx/letflow-pwa-web.conf.example` serves files and has no `proxy_pass` | file |

Every compose file publishes the app on `127.0.0.1` only, so the port is not open on public interfaces through
Docker. The Postgres container on the same compose network can reach `app:4000` directly.

## 4. Verdict per advisory

### EEF-CVE-2026-108525: HTTP/2 inbound flow control not enforced (memory exhaustion)

- Needs an HTTP/2 connection to Bandit itself (DATA frames past the receive window).
- **Public path, repository form: not reachable.** nginx's `proxy_pass` (ngx_http_proxy_module) speaks only
  HTTP/1.0 or 1.1 upstream; `letflow-test.conf` sets 1.1. HTTP/2 from browsers (if Cloudflare or nginx accepts it
  from the client) ends at Cloudflare or nginx and is not passed on. HTTP/2 to an upstream would need `grpc_pass`,
  which is not in the repo.
- **Local path: reachable.** Anything that can open TCP to `127.0.0.1:3201` (QA), `127.0.0.1:3113` (test) or the
  demo port on the host, or to `app:4000` on the compose network, can send the h2c preface and get HTTP/2 (section 2).
  That is the host's own users and processes and the co-located containers, not the internet, unless one of
  Q1 to Q5 below says otherwise.
- Workaround from the advisory: `http_2_options: [enabled: false]` (available from 0.7.0). Fix: bandit 1.14.0.

### EEF-CVE-2026-105659: HTTP/2 blocked-send deadlines reset on each WINDOW_UPDATE

- Also HTTP/2 only (connection-level `pending_sends` and stream-level `send_data/3` in Bandit's HTTP/2 stack).
- Same reach as -108525: **not reachable through the nginx form in the repository, reachable on the local port.**
- The advisory names our setup as an alternative mitigation: "terminate HTTP/2 at a reverse proxy that enforces its
  own send timeouts and speaks HTTP/1 to Bandit". The repository form does that on the test host. QA and demo
  must be confirmed (Q1, Q2). Workaround: `http_2_options: [enabled: false]`. Fix: bandit 1.13.0 or later (1.14.0
  covers all three).

### EEF-CVE-2026-114216: bare LF/CR in chunk extensions (request smuggling)

- HTTP/1.1. It works only behind "a front-end proxy that treats a bare LF as a line ending **and forwards chunked
  bodies unchanged**". The advisory: "Deployments without such a proxy in front of Bandit are not affected."
- **Repository form: not reachable.** nginx does not forward the client's chunked bytes. With the default
  `proxy_request_buffering on` it reads and de-chunks the whole body and sends it upstream with a
  `Content-Length`. With buffering off and `proxy_http_version 1.1` it still parses the chunks and sends its own
  chunk framing. In both cases Bandit never sees the attacker's chunk-size line. `letflow-test.conf` sets no
  `proxy_request_buffering` directive, so the default applies there. This is nginx's documented behaviour, not
  something the repository can prove for the QA and demo vhosts (Q3).
- Direct local access without a proxy is, per the advisory, not affected: smuggling needs two parsers that
  disagree, and there is only one.
- Fix: bandit 1.14.0. The advisory's workaround (turn HTTP/1 off) does not fit us, because nginx speaks HTTP/1.1
  to Bandit.

## 5. What the repository cannot tell (questions for infra)

Each answer is needed for QA and for demo, and for test if it still runs.

- **Q1.** Send the live nginx vhost (or other proxy config) for `qa.bizdala.com`, its tenant subdomains
  (`*.letflow.qa.bizdala.com`) and `demo.letflow.ai-dala.com`. For each `location` that reaches Letflow, what are
  `proxy_pass`, `proxy_http_version`, `proxy_request_buffering` and `proxy_buffering`? Is any `grpc_pass` used?
- **Q2.** Is nginx the **only** thing that connects to the Bandit port on each host (127.0.0.1:3201 on QA, the
  demo's port, presumably 127.0.0.1:3311)? In particular: is a `cloudflared` tunnel, Caddy, Traefik, HAProxy or a
  load balancer pointed at that port, and if so, does it speak HTTP/2 to the origin (for example `cloudflared`
  `http2Origin: true`)?
- **Q3.** Which nginx version runs on the QA and demo hosts, and is any third-party module or `stream {}` (TCP
  pass-through) block in front of the Letflow port? A `stream` proxy would pass HTTP/2 and raw chunked bytes
  through unchanged, and both answers in section 4 would then change to "reachable".
- **Q4.** Which demo compose file and port mapping is live? Is the app port published on `127.0.0.1` only, as in
  `deploy/docker-compose.qa.yml`, or on `0.0.0.0`? Is there a host firewall rule for it?
- **Q5.** Does any other container share a Docker network with the Letflow app on QA or demo (other products,
  Keycloak, monitoring)? Each one can reach port 4000 inside the network directly.
- **Q6.** Who has shell or local-process access on the QA and demo hosts (other products' services, CI runners,
  agents)? The two HTTP/2 advisories need only TCP to the loopback port, with no login.
- **Q7.** Is the Cloudflare zone for `ai-dala.com` / `bizdala.com` set to "HTTP/2 to Origin"? That changes only
  the Cloudflare-to-nginx hop, not nginx-to-Bandit, but it should be known for the record.

## 6. What this means for the fix (input for the next task, not a decision)

- Upgrading `bandit` to 1.14.0 or later fixes all three and needs no exposure answer. Per D-117 it goes to QA
  through CD, and to demo only with the owner.
- If the upgrade must wait, adding `http_2_options: [enabled: false]` to the Bandit child in
  `Letflow.Supervisor.Http.http_child/0` closes both HTTP/2 advisories. Nothing in the repository's proxy form
  needs HTTP/2 to Bandit (nginx speaks HTTP/1.1 upstream). It would break any h2c peer found under Q2, so Q2 is
  answered first.
- Neither change is made by this note.

## How this was checked (commands, 2026-11-11, worktree at origin/main 6d4d0ecf7)

```
grep -rn -i "bandit\|thousand_island\|http_2\|http2" config/ mix.exs
grep -n '"bandit"\|"thousand_island"\|"hpax"' mix.lock
grep -rn -i "bandit" lib/ --include=*.ex          # only Letflow.Supervisor.Http starts it
grep -n "version" deps/bandit/mix.exs             # 1.12.5
grep -n "enabled" deps/bandit/lib/bandit.ex       # http_2 enabled defaults to true
grep -n "PRI\|alpn\|sniff" deps/bandit/lib/bandit/initial_handler.ex
cat deploy/docker-compose.qa.yml deploy/docker-compose.test.yml deploy/nginx/letflow-test.conf
grep -n "EXPOSE\|CMD" deploy/Dockerfile
grep -rn -i "nginx\|proxy\|127.0.0.1" docs/runbooks/demo-instance.md docs/runbooks/demo-operator-inputs.md \
  docs/runbooks/qa-tenant-subdomain-host-resolution.md deploy/redeploy-qa.sh
curl -s https://api.osv.dev/v1/vulns/EEF-CVE-2026-114216   # and -108525, -105659 (public advisory text only)
```
