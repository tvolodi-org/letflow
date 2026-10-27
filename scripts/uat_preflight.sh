#!/usr/bin/env bash
# uat_preflight.sh
#
# WF-05 Step 0 preflight: READ-ONLY check of a target environment against the
# PRECONDITIONS manifest derived from the UAT scenario corpus. Prints (1) a manifest
# summary and (2) a scenario x check gap table (OK / GAP / UNKNOWN, with reason and
# remediation owner). See docs/agents/workflows/WF-05_uat_run.md "Step 0".
#
# Usage:
#   scripts/uat_preflight.sh --base-url URL --environment SLUG --credential-source PATH \
#       [--credential-protocol qa-login|qa-uat-env] [--scenarios DIR] [--sha SHA] \
#       [--idp-url URL] [--out FILE]
#
#   --base-url           instance under test, e.g. https://qa.bizdala.com
#   --environment        stable slug (qa | local | staging ...), printed in the report
#   --credential-source  script implementing one of two protocols (see
#                        --credential-protocol) for reaching seeded QA credentials.
#   --credential-protocol
#                        which protocol --credential-source speaks (default "qa-login"):
#                          qa-login   -- ai-dala-infra/scripts/qa-login.sh shape: no-arg
#                                        call lists seeded usernames, one per line, each
#                                        2-space-indented (`^\s{2}([a-z0-9][\w-]*)\s`);
#                                        `<script> <username>` prints a line
#                                        `Password: <pw>` and uat_preflight performs the
#                                        OIDC password grant itself.
#                          qa-uat-env -- ai-dala-infra/scripts/qa-uat-env.sh shape: no
#                                        stable no-arg username listing exists (accounts
#                                        are realm-qualified, provisioned per-tenant, see
#                                        ISS-0894/T-0150), so the seeded-username roster is
#                                        instead taken directly from the scenario corpus's
#                                        own actor ids (valid because this protocol's
#                                        accounts are named exactly `actor-<tenant>-<name>`,
#                                        the scenario id itself); `<script> token
#                                        <actor_id>` prints the access token either as a
#                                        line `Token: <bearer-token>` or as a BARE JWT on a
#                                        line by itself (three dot-separated base64url
#                                        segments starting `eyJ`); other stdout lines
#                                        (warnings, hostnames, banners) are ignored and the
#                                        first line that parses wins. The token is a
#                                        ready-made access token, not a password, and is
#                                        never echoed; uat_preflight verifies it with a
#                                        single read-only `GET /api/v1/me/modules` call
#                                        instead of performing its own OIDC grant.
#                                        See ISS-0909(d), ISS-0936.
#   --scenarios          corpus dir (default test/fixtures/uat/scenarios); _throwaway skipped
#   --env-limitations    sidecar dir (default test/fixtures/uat/scenario-env-limitations). Sidecar
#                        fields: scenario_id, applies_to_environments, classification, reason,
#                        issue_ref, recorded_by, recorded_at, review; optional
#                        applies_to_expected_outcomes (partial scope) and optional
#                        disposition: skipped (REQ-533): the scenario is reported SKIP, listed under
#                        SKIPPED SCENARIOS and not counted toward GAP / ENV_NOT_READY. Valid
#                        classifications for skipped: UNBUILT_FEATURE, COVERED_ELSEWHERE. Not
#                        combinable with applies_to_expected_outcomes (exit 2).
#   --sha                expected deployed build (default: `git rev-parse origin/main`). A deployed
#                        build that differs from it is OK when `git diff --name-only` between the
#                        two has no runtime path (GH #3044; docs/, test/, handoffs/, .github/,
#                        scripts/*uat*, *.md, web test files, mix.exs test_ignore_filters only)
#   --idp-url            Keycloak base (default: derived, https://auth.<host minus first label
#                        if it is 'qa'... i.e. https://auth.qa.bizdala.com for qa.bizdala.com)
#   --out FILE           also write a machine-readable JSON summary (never contains secrets)
#
# Exit codes: 0 = no GAP (env ready; UNKNOWN entries are listed but not fatal)
#             1 = at least one GAP  => the run is ENV_NOT_READY, not a UAT result
#             2 = usage error
#
# Everything is read-only: GET requests, plus the OIDC password grant used only to check
# that a seeded credential is valid. Passwords/tokens are held in process memory, never
# printed, logged, written to a file, or placed in argv.
#
# Dependencies: bash, git, and Python 3 (stdlib only; PyYAML optional -- if absent, a
# tolerant regex reader is used for the scenario files). Interpreter is auto-detected
# (`python3` on Windows is often a Store stub that does not run, so `python` is tried too).
#
# Actor -> credential heuristic (best effort, documented in WF-05 Step 0):
#   actor-platform-admin        -> needs a seeded PLATFORM_ADMIN user (qa-login "admin-user")
#   actor-system-* / actor-any  -> not a login (system/any); not checked
#   actor-<tenant>-<name>       -> exact match first: a seeded username equal to the full
#                                  actor id (e.g. "actor-swiftroute-lena") is tried before
#                                  falling back to the older heuristic (a seeded username
#                                  starting "<name>-", or == "<name>"). The realm(s) tried
#                                  are derived from the actor id itself -- <tenant> first,
#                                  same as the "<tenant>" the actor id names, not from
#                                  whichever OTHER scenario happened to reference this
#                                  actor first -- falling back to the scenario's own
#                                  declared tenant (if different) and finally bpm-default.
#                                  A login failure is cached per (actor_id, realm), never
#                                  per bare actor name, so a BAD_CRED in one realm can
#                                  never poison a check of the same actor name in a
#                                  DIFFERENT realm. See ISS-0894, ISS-0909(a).
#   anything else               -> UNKNOWN
#
# Beyond token validity, two further per-scenario checks (ISS-0894) use the token(s)
# obtained above: `app_roles` (GET /tasks/inbox; /me/modules for candidate-labeled
# actors; /identity/users for actor-platform-admin, see ISS-0909c/ISS-0993 -- 403 there is
# a role-binding gap, see ISS-0886) and `definitions` (GET
# /api/v1/definitions/active/<process_id> for proc-* process ids -- 404 there is a
# definition-resolution gap, see ISS-0893/ISS-0897). When a
# test/fixtures/uat/process-definition-aliases/<process_id>.yaml sidecar exists, its
# definition_name is resolved instead of the raw process_id -- see ISS-0893.
set -uo pipefail

PY=""
for c in python3 python py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if sys.version_info[0]==3 else 1)' >/dev/null 2>&1; then
    PY="$c"; break
  fi
done
if [[ -z "$PY" ]]; then echo "uat_preflight: no working python3 found" >&2; exit 2; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export UAT_PF_REPO_ROOT="$REPO_ROOT"
export UAT_PF_BASH="${BASH:-bash}"   # the bash running us (git-bash), not WSL's System32ash.exe
export UAT_PF_DEFAULT_SHA="$(git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null || true)"

exec "$PY" - "$@" <<'PYEOF'
import sys, os, re, json, glob, subprocess, argparse, urllib.request, urllib.parse, urllib.error

def usage_err(msg):
    sys.stderr.write("uat_preflight: %s\n" % msg)
    sys.stderr.write("usage: uat_preflight.sh --base-url URL --environment SLUG --credential-source PATH "
                     "[--scenarios DIR] [--sha SHA] [--idp-url URL] [--out FILE]\n")
    sys.exit(2)

class P(argparse.ArgumentParser):
    def error(self, m): usage_err(m)

ap = P(add_help=False)
ap.add_argument("--base-url"); ap.add_argument("--environment"); ap.add_argument("--credential-source")
ap.add_argument("--env-limitations"); ap.add_argument("--scenarios"); ap.add_argument("--sha"); ap.add_argument("--idp-url"); ap.add_argument("--out")
ap.add_argument("--credential-protocol", choices=["qa-login", "qa-uat-env"], default="qa-login")
a = ap.parse_args(sys.argv[1:])
for req in ("base_url", "environment", "credential_source"):
    if not getattr(a, req): usage_err("missing --" + req.replace("_", "-"))

def winpath(p):
    """git-bash paths (/c/Users/..) -> C:/Users/.. for native Windows Python."""
    if p and os.name == "nt":
        m = re.match(r"^/([a-zA-Z])/(.*)$", p)
        if m: return "%s:/%s" % (m.group(1).upper(), m.group(2))
    return p

REPO = winpath(os.environ["UAT_PF_REPO_ROOT"])
BASH = os.environ.get("UAT_PF_BASH", "bash")
base = a.base_url.rstrip("/")
scen_dir = winpath(a.scenarios) if a.scenarios else os.path.join(REPO, "test/fixtures/uat/scenarios")
exp_sha = a.sha or os.environ.get("UAT_PF_DEFAULT_SHA", "")
host = urllib.parse.urlparse(base).hostname or ""
idp = (a.idp_url or ("https://auth." + host)).rstrip("/")
CLIENT_ID = os.environ.get("BPM_IDP_CLIENT_ID", "letflow-web")

# ---------------------------------------------------------------- http (read-only)
def http(method, url, headers=None, data=None, timeout=15):
    req = urllib.request.Request(url, method=method, headers=headers or {}, data=data)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:
        return 0, str(type(e).__name__).encode()

def jload(b):
    try: return json.loads(b)
    except Exception: return None

# ---------------------------------------------------------------- scenario manifest
try:
    import yaml
except Exception:
    yaml = None

def parse_scenario(path):
    raw = open(path, encoding="utf-8").read()
    d = {}
    if yaml:
        try:
            docs = [x for x in yaml.safe_load_all(raw) if isinstance(x, dict)]
            d = docs[0] if docs else {}
        except Exception:
            d = {}
    if not d:  # tolerant fallback
        for key in ("id", "company_id", "scope", "process_id", "pipeline_test"):
            m = re.search(r"^%s:\s*(\S+)" % key, raw, re.M)
            if m: d[key] = m.group(1).strip("\"'")
        m = re.search(r"^actors:\s*\n((?:[ \t]+.*\n?)+)", raw, re.M)
        acts = {}
        if m:
            for l in m.group(1).splitlines():
                mm = re.match(r"\s+([\w-]+):\s*(actor-[\w-]+)", l)
                if mm: acts[mm.group(1)] = mm.group(2)
        d["actors"] = acts
    actors = d.get("actors") or {}
    actor_ids = sorted({v for v in actors.values() if isinstance(v, str) and v.startswith("actor-")}) if isinstance(actors, dict) else []
    actor_labels = {}  # aid -> [label, ...]
    if isinstance(actors, dict):
        for label, aid in actors.items():
            if isinstance(aid, str) and aid.startswith("actor-"):
                actor_labels.setdefault(aid, []).append(label)
    tenant = d.get("company_id") or d.get("scope")
    if d.get("scope") and d.get("scope") != "platform": tenant = d["scope"]
    # forward-reference / unbuilt-feature NOTE comments
    notes = " ".join(re.findall(r"^#\s*NOTE \(ISS-\d+.*(?:\n#.*)*", raw, re.M)).lower()
    fwd_spec = bool(re.search(r"spec file does not exist|forward-reference|aspirational|never authored", notes))
    unbuilt = bool(re.search(r"has not built|not built the equivalent", notes))
    return {
        "file": os.path.relpath(path, REPO).replace("\\", "/"),
        "id": str(d.get("id") or os.path.basename(path)),
        "tenant": str(tenant) if tenant else None,
        "process_id": d.get("process_id") if d.get("process_id") not in (None, "n/a") else None,
        "pipeline_test": d.get("pipeline_test"),
        "actor_ids": actor_ids,
        "actor_labels": actor_labels,
        "fwd_spec": fwd_spec, "unbuilt": unbuilt,
    }

files = sorted(f for f in glob.glob(os.path.join(scen_dir, "**", "*.yaml"), recursive=True)
               if "_throwaway" not in f.replace("\\", "/").split("/"))
if not files: usage_err("no scenario files under " + scen_dir)
scenarios = [parse_scenario(f) for f in files]

# ---------------------------------------------------------------- env-limitation sidecars
# test/fixtures/uat/scenario-env-limitations/<scenario_id>.yaml -- NOT scenario files,
# deliberately outside scen_dir's glob. See docs/agents/workflows/WF-05_uat_run.md Step 0
# item 3 ("environment-structural (permanent)") and ISS-0895.
env_limit_dir = a.env_limitations or os.path.join(REPO, "test/fixtures/uat/scenario-env-limitations")
env_limitations = {}  # scenario_id -> dict
def parse_env_limitation(path):
    raw = open(path, encoding="utf-8").read()
    d = {}
    if yaml:
        try:
            d = yaml.safe_load(raw) or {}
        except Exception:
            d = {}
    if not d:  # tolerant fallback
        for key in ("scenario_id", "classification", "issue_ref", "recorded_by", "recorded_at", "disposition"):
            m = re.search(r"^%s:\s*(\S+)" % key, raw, re.M)
            if m: d[key] = m.group(1).strip("\"'")
        m = re.search(r"^applies_to_environments:\s*\[([^\]]*)\]", raw, re.M)
        d["applies_to_environments"] = [x.strip().strip("\"'") for x in m.group(1).split(",")] if m else []
        m = re.search(r"^applies_to_expected_outcomes:[ \t]*(\[[^\]]*\]|\n(?:[ \t]*-.*\n?)+)", raw, re.M)
        if m: d["applies_to_expected_outcomes"] = [x.strip("\"'") for x in re.split(r"[\s,\[\]]+|^\s*-\s*", m.group(1), flags=re.M) if x.strip("\"'")]
        m = re.search(r"^reason:\s*>?\s*\n((?:[ \t]+.*\n?)+)", raw, re.M)
        d["reason"] = " ".join(l.strip() for l in m.group(1).splitlines()).strip() if m else ""
    return d
for f in sorted(glob.glob(os.path.join(env_limit_dir, "*.yaml"))):
    d = parse_env_limitation(f)
    sid = d.get("scenario_id")
    if d.get("disposition") == "skipped" and d.get("applies_to_expected_outcomes"):
        usage_err("%s: disposition skipped cannot be combined with applies_to_expected_outcomes "
                  "(a partly covered scenario must still run its other outcomes)" % f)
    if sid: env_limitations[sid] = d

# ------------------------------------------------------- process-definition-alias sidecars
# test/fixtures/uat/process-definition-aliases/<process_id>.yaml -- NOT scenario files,
# deliberately outside scen_dir's glob. Maps a scenario corpus's synthetic proc-* process_id
# to the deployed definition's real `name` field (process_definitions has no key/slug
# column -- see ISS-0893).
pd_alias_dir = os.path.join(REPO, "test/fixtures/uat/process-definition-aliases")
pd_aliases = {}  # process_id -> definition_name
def parse_pd_alias(path):
    raw = open(path, encoding="utf-8").read()
    d = {}
    if yaml:
        try:
            d = yaml.safe_load(raw) or {}
        except Exception:
            d = {}
    if not d:  # tolerant fallback
        for key in ("process_id", "definition_name", "company_id", "issue_ref", "recorded_by", "recorded_at"):
            m = re.search(r"^%s:\s*(.+)$" % key, raw, re.M)
            if m: d[key] = m.group(1).strip().strip("\"'")
    return d
for f in sorted(glob.glob(os.path.join(pd_alias_dir, "*.yaml"))):
    d = parse_pd_alias(f)
    pid_ = d.get("process_id")
    if pid_ and d.get("definition_name"): pd_aliases[pid_] = d["definition_name"]

# ---------------------------------------------------------------- credentials (in-memory only)
cred_src = winpath(a.credential_source)
cred_protocol = a.credential_protocol
cred_listing = None   # list of usernames, None = source unusable
cred_err = None
def run_cred(args, timeout):
    return subprocess.run([BASH, cred_src] + args, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)

if cred_protocol == "qa-login":
    try:
        if not os.path.isfile(cred_src): raise RuntimeError("credential source not found: " + cred_src)
        r = run_cred([], 30)
        names = []
        for l in r.stdout.splitlines():
            m = re.match(r"^\s{2}([a-z0-9][\w-]*)\s", l)
            if m: names.append(m.group(1))
        if not names: raise RuntimeError("credential source listed no usernames")
        cred_listing = names
    except Exception as e:
        cred_err = str(e)
else:  # qa-uat-env -- see header comment; no stable no-arg listing exists for this
    # protocol, so the seeded-username roster is taken directly from the scenario
    # corpus's own actor ids (valid: this protocol's accounts are named exactly
    # actor-<tenant>-<name>, the scenario actor id itself -- ISS-0894/T-0150).
    try:
        if not os.path.isfile(cred_src): raise RuntimeError("credential source not found: " + cred_src)
        cred_listing = sorted({aid for sc in scenarios for aid in sc["actor_ids"]
                                if not aid.startswith("actor-system-") and aid != "actor-any"})
        if not cred_listing: raise RuntimeError("no login actors declared by the scenario corpus")
        # ISS-0997: actor-platform-admin has no per-actor account under this protocol; the
        # PLATFORM_ADMIN account is the literal "admin-user" (`token admin-user` works), which
        # the admin-token lookup and the actor-platform-admin mapping below both search for.
        # Added only AFTER the empty check so "no login actors declared" semantics are kept.
        cred_listing = sorted(set(cred_listing) | {"admin-user"})
    except Exception as e:
        cred_err = str(e)

_JWT_RE = re.compile(r"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+")
def parse_token_line(line):
    """Pure helper (ISS-0936): returns the bearer token carried by ONE stdout line of a
    qa-uat-env credential source, or None. Accepts `Token: <jwt>` (labelled, trusted, no
    shape check) or a BARE JWT alone on the line (full-line match of three non-empty
    base64url segments starting `eyJ`, total length >= 40). Anything else is noise.
    Never prints or logs the value."""
    s = line.strip()
    if not s: return None
    if s.startswith("Token:"):
        v = s.split(":", 1)[1].strip()
        return v or None
    if len(s) >= 40 and _JWT_RE.fullmatch(s): return s
    return None

# defined before first use: the admin-token login (ISS-0997) calls try_login -> auth()
def auth(tok): return {"Authorization": "Bearer " + tok, "Accept": "application/json"}

def fetch_credential(user):
    """Returns (kind, value) -- kind is "password" (qa-login protocol: a plaintext
    password uat_preflight itself exchanges via an OIDC grant below) or "token"
    (qa-uat-env protocol: an already-issued bearer access token, verified directly
    instead of re-derived) -- or (None, None) if the source has nothing for `user`."""
    try:
        if cred_protocol == "qa-login":
            r = run_cred([user], 60)
            for l in r.stdout.splitlines():
                if l.startswith("Password:"): return ("password", l.split(":", 1)[1].strip())
        else:
            r = run_cred(["token", user], 60)
            for l in r.stdout.splitlines():
                tok = parse_token_line(l)
                if tok: return ("token", tok)
    except Exception:
        pass
    return (None, None)

realm_status = {}   # (actor_id, realm) -> "OK" | "BAD_CRED"  -- ISS-0909(a): never keyed
                     # on the bare actor/username alone, so a failure in one realm can
                     # never poison a later check of the same actor name in another realm.
tokens = {}          # (actor_id, realm) -> access_token, in-memory only
def try_login(aid, user, realms):
    """Attempt realms in order for `aid`/`user`, returning (state, realm) where state is
    OK / BAD_CRED / NO_PASSWORD. Caches per (aid, realm) pair (ISS-0909a) -- never per
    bare `user` -- so a scenario that only ever tries realm X caching a failure there
    does not stop a LATER scenario from correctly trying (and succeeding in) realm Y for
    the same actor."""
    dedup = []
    for r in realms:
        if r not in dedup: dedup.append(r)
    kind, cred = fetch_credential(user)
    if kind is None:
        return ("NO_PASSWORD", None)
    if kind == "token":
        # qa-uat-env protocol: the credential source already performed the grant --
        # verify the token with one read-only call instead of re-deriving it. The
        # realm label is the actor id's own derived realm (dedup[0], see realms_for);
        # we do not decode the JWT to avoid a new dependency.
        realm = dedup[0] if dedup else "bpm-default"
        cached = realm_status.get((aid, realm))
        if cached == "OK": return ("OK", realm)
        if cached in ("BAD_CRED", "NO_APP_ROLE"): return (cached, realm if cached == "NO_APP_ROLE" else None)
        st, _ = http("GET", base + "/api/v1/me/modules", auth(cred))
        if st == 200:
            tokens[(aid, realm)] = cred
            realm_status[(aid, realm)] = "OK"
            return ("OK", realm)
        # 401 = token rejected (credential/realm problem); 403 = token accepted but Letflow
        # resolves no app role for the user (GH #3112) -- different owner, different fix.
        state = "NO_APP_ROLE" if st == 403 else "BAD_CRED"
        realm_status[(aid, realm)] = state
        return (state, realm if state == "NO_APP_ROLE" else None)
    # kind == "password": qa-login protocol, own OIDC grant, one realm at a time.
    for realm in dedup:
        cached = realm_status.get((aid, realm))
        if cached == "OK": return ("OK", realm)
        if cached == "BAD_CRED": continue
        body = urllib.parse.urlencode({"client_id": CLIENT_ID, "username": user, "password": cred,
                                       "grant_type": "password"}).encode()
        st, resp = http("POST", "%s/realms/%s/protocol/openid-connect/token" % (idp, realm),
                        {"Content-Type": "application/x-www-form-urlencoded"}, body)
        j = jload(resp) if st == 200 else None
        if j and j.get("access_token"):
            tokens[(aid, realm)] = j["access_token"]
            realm_status[(aid, realm)] = "OK"
            cred = None
            return ("OK", realm)
        realm_status[(aid, realm)] = "BAD_CRED"
    cred = None
    return ("BAD_CRED", None)

def realms_for(aid, tenant):
    """Realm attempt order for `aid`: the actor's OWN tenant realm, derived from the
    actor id itself (actor-<tenant>-<name> -> <tenant>) FIRST -- never a realm carried
    over from whatever other scenario/tenant happened to reference this actor id
    earlier (ISS-0909a) -- then the current scenario's declared tenant (only if it
    differs), then bpm-default as the final fallback. "platform"/"system" are never
    realms."""
    order = []
    m = re.match(r"^actor-([a-z0-9]+)-", aid)
    if m and m.group(1) not in ("platform", "system"):
        order.append(m.group(1))
    if tenant and tenant != "platform" and tenant not in order:
        order.append(tenant)
    if "bpm-default" not in order:
        order.append("bpm-default")
    return order

# ---------------------------------------------------------------- global checks
g = {}   # name -> (status, reason, owner)
st, _ = http("GET", base + "/health")
g["base_url"] = ("OK", "GET /health -> %s" % st, "") if st == 200 else \
    ("GAP", "GET /health -> %s" % st, "ai-dala-infra")

tenant_slugs_needed = sorted({s["tenant"] for s in scenarios if s["tenant"] and s["tenant"] != "platform"})
realm_state = {}
for slug in sorted(set(tenant_slugs_needed) | {"bpm-default"}):
    st, _ = http("GET", "%s/realms/%s/.well-known/openid-configuration" % (idp, slug))
    realm_state[slug] = st

# admin token: first seeded PLATFORM_ADMIN-ish user that logs in
admin_user = next((u for u in (cred_listing or []) if u in ("admin-user",)), None)
admin_tok = None
if admin_user:
    s_, realm_ = try_login("actor-platform-admin", admin_user, ["bpm-default"])
    if s_ == "OK": admin_tok = tokens[("actor-platform-admin", realm_)]

# deployed SHA. A deployed build that differs from the expected one is still OK when the git
# diff between the two touches no runtime path (GH #3044): docs, tests, handoffs, CI config,
# scripts/*uat* files, markdown, web test files, and a mix.exs change confined to test_ignore_filters.
NON_RUNTIME_PREFIXES = ("docs/", "test/", "handoffs/", ".github/")
WEB_TEST_RE = re.compile(r"^web/(?:.*/)?(?:__tests__|tests?|e2e)/|^web/.*\.(?:test|spec)\.[cm]?[jt]sx?$")

def git_out(*args):
    """stdout of `git -C REPO <args>` as text, or None when git fails."""
    r = subprocess.run(["git", "-C", REPO] + list(args), capture_output=True)
    return r.stdout.decode("utf-8", "replace") if r.returncode == 0 else None

def git_commit(rev):
    """Full SHA of `rev` when the local git knows it as a commit, else None."""
    out = git_out("rev-parse", "--verify", "-q", rev + "^{commit}")
    return out.strip() if out else None

def non_runtime(path):
    """Denylist: everything not matched here is runtime (deploy/, rel/, lib/, priv/, config/,
    mix.lock, web/ outside its test files, ...)."""
    return (path.startswith(NON_RUNTIME_PREFIXES) or re.fullmatch(r"scripts/[^/]*uat[^/]*", path) is not None
            or path.endswith(".md") or WEB_TEST_RE.match(path) is not None)

def mix_exs_without_filters(text):
    """mix.exs text with its `test_ignore_filters: [...]` entry cut out, together with the comment
    lines directly above it and its trailing comma and newline. None when the entry is repeated or
    the brackets do not balance. Bracket matching does not skip brackets inside string literals."""
    found = list(re.finditer(r"test_ignore_filters:\s*\[", text))
    if len(found) > 1: return None
    if not found: return text
    depth = 0
    for i in range(found[0].end() - 1, len(text)):
        if text[i] == "[": depth += 1
        elif text[i] == "]":
            depth -= 1
            if depth == 0: break
    else:
        return None
    start = text.rfind("\n", 0, found[0].start()) + 1
    while start > 0:
        prev = text.rfind("\n", 0, start - 1) + 1
        if not text[prev:start].lstrip().startswith("#"): break
        start = prev
    end = re.match(r",?[ \t]*\n?", text[i + 1:]).end() + i + 1
    return text[:start] + text[end:]

def mix_exs_filters_only(dep, exp):
    """True when mix.exs differs between the two commits only inside test_ignore_filters (the entry
    may be added or removed, with its comment lines)."""
    before = git_out("show", dep + ":mix.exs")
    after = git_out("show", exp + ":mix.exs")
    if before is None or after is None: return False
    b = mix_exs_without_filters(before)
    return b is not None and b == mix_exs_without_filters(after)

def deployed_vs_expected(dep, exp):
    """(status, why, owner) for a deployed SHA that differs from the expected one."""
    dep_full, exp_full = git_commit(dep), git_commit(exp)
    if not (dep_full and exp_full):
        return ("GAP", "deployed %s != expected %s (not both known to local git, runtime diff not checked)"
                % (dep[:12], exp[:12]), "ai-dala-infra (redeploy)")
    changed = git_out("-c", "core.quotepath=off", "diff", "--no-renames", "--name-only", dep_full, exp_full)
    if changed is None:
        return ("GAP", "deployed %s != expected %s (git diff failed, runtime diff not checked)"
                % (dep[:12], exp[:12]), "ai-dala-infra (redeploy)")
    for path in filter(None, changed.splitlines()):
        if path == "mix.exs" and mix_exs_filters_only(dep_full, exp_full): continue
        if non_runtime(path): continue
        return ("GAP", "deployed %s != expected %s: runtime diff, first runtime path %s"
                % (dep[:12], exp[:12], path), "ai-dala-infra (redeploy)")
    return ("OK", "deployed %s, expected %s, no runtime diff" % (dep[:12], exp[:12]), "")

sha_state = ("UNKNOWN","no version endpoint exposes a build SHA (tried /health, /api/v1/version)", "ai-dala-infra (expose build SHA)")
cands = [("/health", None)]
if admin_tok: cands.append(("/api/v1/version", admin_tok))
for path, tok in cands:
    st, body = http("GET", base + path, auth(tok) if tok else None)
    j = jload(body) if st == 200 else None
    if isinstance(j, dict):
        v = next((str(j[k]) for k in ("sha", "git_sha", "commit", "build_sha", "revision", "version") if j.get(k)), None)
        if v:
            if exp_sha and (v.startswith(exp_sha[:7]) or exp_sha.startswith(v[:7])):
                sha_state = ("OK", "deployed %s == origin/main %s" % (v[:12], exp_sha[:12]), "")
            elif exp_sha and re.fullmatch(r"[0-9a-f]{7,40}", v):
                sha_state = deployed_vs_expected(v, exp_sha)
            else:
                sha_state = ("UNKNOWN", "endpoint reports version %s; not comparable to a git SHA" % v[:40], "ai-dala-infra (expose build SHA)")
            break
g["deployed_sha"] = sha_state

# platform_operator (ISS-0993, optional, read-only): /api/v1/admin/services is PLATFORM
# scope, honoured only for a PLATFORM_ADMIN whose tenant is the one named by
# LETFLOW_PLATFORM_TENANT_ID on the server. When a platform-tenant account is configured
# for this run (UAT_PF_PLATFORM_OPERATOR_USER = a username the credential source knows;
# UAT_PF_PLATFORM_OPERATOR_REALM = its realm, default bpm-default), probe that route with
# it. Not configured => OK (skipped): this check never fails a run that has no operator.
op_user = os.environ.get("UAT_PF_PLATFORM_OPERATOR_USER", "").strip()
op_realm = os.environ.get("UAT_PF_PLATFORM_OPERATOR_REALM", "").strip() or "bpm-default"
if not op_user:
    g["platform_operator"] = ("OK", "not configured (optional; set UAT_PF_PLATFORM_OPERATOR_USER to probe)", "")
else:
    op_state, op_realm_used = try_login("platform-operator", op_user, [op_realm])
    if op_state != "OK":
        g["platform_operator"] = ("GAP", "platform operator login failed (%s)" % op_state,
                                  "ai-dala-infra (platform tenant account)")
    else:
        op_st, _ = http("GET", base + "/api/v1/admin/services",
                        auth(tokens[("platform-operator", op_realm_used)]))
        if op_st == 200:
            g["platform_operator"] = ("OK", "GET /admin/services -> 200 with the platform-tenant account", "")
        elif op_st == 403:
            g["platform_operator"] = ("GAP",
                "GET /admin/services -> 403 with the platform-tenant account: its tenant is not the "
                "configured platform tenant (LETFLOW_PLATFORM_TENANT_ID) or PLATFORM_ADMIN is not bound",
                "ai-dala-infra (set LETFLOW_PLATFORM_TENANT_ID) / letflow (ISS-0886 role backfill)")
        else:
            g["platform_operator"] = ("UNKNOWN", "GET /admin/services -> %s" % op_st, "")

# tenants
tenants_found = None
tenants_reason = ""
if admin_tok:
    st, body = http("GET", base + "/api/v1/tenants", auth(admin_tok))
    j = jload(body) if st == 200 else None
    items = j if isinstance(j, list) else (j.get("items") or j.get("data") or j.get("tenants") if isinstance(j, dict) else None)
    if isinstance(items, list):
        tenants_found = set()
        for it in items:
            if isinstance(it, dict):
                for k in ("slug", "name", "realm", "subdomain"):
                    if it.get(k): tenants_found.add(str(it[k]).lower())
    else:
        tenants_reason = "GET /api/v1/tenants -> %s (unparseable or forbidden)" % st
else:
    tenants_reason = "no valid PLATFORM_ADMIN token (credential check failed)"

# ---------------------------------------------------------------- per-scenario checks
CHECKS = ["spec", "local_deps", "feature", "tenant", "realm", "actors", "app_roles", "definitions", "env_limitation"]
rows = []
skipped = {}  # scenario_id -> sidecar with disposition skipped (REQ-533)
def spec_path(s): return os.path.join(REPO, s["pipeline_test"]) if s["pipeline_test"] else None

# ISS-0909(b): local_deps must catch a spec that ACTUALLY invokes local-only tooling
# in executable code, not one that merely mentions it in prose (a header comment
# describing history/rationale, e.g. "verified manually against docker compose ...").
# Naive w.r.t. "//" inside a string literal (e.g. 'http://...') -- acceptable here
# since it can only under-match (miss a real usage hidden after "//" in a string
# literal), never over-match a comment as code.
_JS_BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.S)
_JS_LINE_COMMENT_RE = re.compile(r"//[^\n]*")
def _strip_js_comments(txt):
    return _JS_LINE_COMMENT_RE.sub("", _JS_BLOCK_COMMENT_RE.sub("", txt))

# ISS-0915: local_deps must also not over-match a string literal that merely mentions
# "docker compose"/"psql" as PROSE (e.g. a log message, an assertion string, a test
# title) -- that is not an executable invocation either. BUT (REVIEWER finding on the
# first attempt at this fix, same issue) blanking the contents of EVERY string/template
# literal is unsound: it also blinds the check to a string that IS the command actually
# being executed, e.g. `execSync(\`psql "${dbUrl}" -c "${sql}"\`, ...)` -- a pattern that
# exists for real in web/tests/e2e/env04.e2e.spec.ts (lines ~158-159/190/194), not just a
# hypothetical. The distinction that matters is not "is this text inside a string" but
# "is this string a direct argument to an exec/spawn-style call" -- so only strings that
# are NOT the direct (first, post-"(") argument of a known exec-like call get blanked;
# a string sitting right after one of those call names' opening "(" is left untouched so
# _LOCAL_DEPS_LITERAL_RE can still see (and GAP on) a real command embedded in it. The
# genuine call-expression invocation path (_LOCAL_DEPS_HELPER_RE, matching
# `runSqlAgainstDevPostgres(` syntax itself) is separately unaffected either way, since it
# never looks at string content.
_EXEC_LIKE_CALL_RE = re.compile(
    r"\b(?:execSync|execFileSync|spawnSync|spawn|exec|runSqlAgainstDevPostgres)\s*\(\s*$"
)
_JS_STRING_RE = re.compile(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|`(?:\\.|[^`\\])*`', re.S)
def _strip_js_strings(txt):
    def repl(m):
        # Look at what immediately precedes this string literal (whitespace-insensitive,
        # newlines included): if it's a known exec-like call's opening "(", this string
        # IS (or may be) the command being executed -- keep it verbatim so the literal
        # keyword match below can still see it. Anything else (console.log(, throw new
        # Error(, test(, a bare string, ...) is prose or non-exec data -- blank it.
        if _EXEC_LIKE_CALL_RE.search(txt[: m.start()]):
            return m.group(0)
        return '""'
    return _JS_STRING_RE.sub(repl, txt)

_LOCAL_DEPS_LITERAL_RE = re.compile(r"docker[ -]compose|docker exec|\bpsql\b")
# `runSqlAgainstDevPostgres` (web/tests/e2e/db-exec.ts) is the one exported helper
# that actually shells into `docker compose exec ... psql` at runtime -- a spec that
# CALLS it in its own executable code is genuinely invoking local-only tooling even
# though the literal words "docker"/"psql" never appear in the spec file itself (they
# live inside db-exec.ts, which this check does not otherwise scan).
_LOCAL_DEPS_HELPER_RE = re.compile(r"\brunSqlAgainstDevPostgres\s*\(")

def local_deps_check(sp):
    if not (sp and os.path.isfile(sp)):
        return ("OK", "n/a (no spec file)", "")
    code_txt = _strip_js_comments(open(sp, encoding="utf-8", errors="replace").read())
    m = _LOCAL_DEPS_LITERAL_RE.search(_strip_js_strings(code_txt))
    if m:
        return ("GAP", "spec invokes local-only tooling in executable code (`%s`)" % m.group(0),
                 "letflow (rewrite spec to API/seed; ENV_NOT_SUPPORTED)")
    if _LOCAL_DEPS_HELPER_RE.search(code_txt):
        return ("GAP",
                 "spec calls db-exec.ts's runSqlAgainstDevPostgres(...), which shells into "
                 "`docker compose exec ... psql` at runtime (see web/tests/e2e/db-exec.ts)",
                 "letflow (rewrite spec to API/seed; ENV_NOT_SUPPORTED)")
    return ("OK", "no local-only tooling invoked in executable code (comments excluded)", "")

for s in scenarios:
    c = {}
    sp = spec_path(s)
    if not sp:
        c["spec"] = ("OK", "no pipeline_test declared (API/manual drive)", "")
    elif not os.path.isfile(sp):
        c["spec"] = ("GAP", "pipeline_test %s does not exist" % s["pipeline_test"], "feature-gap (author spec)")
    else:
        c["spec"] = ("OK", "spec file exists", "")
    if s["unbuilt"]:
        c["feature"] = ("GAP", "NOTE (ISS-...) says Letflow has not built the feature this scenario exercises", "feature-gap (UNBUILT_FEATURE)")
    elif s["fwd_spec"] and not (sp and os.path.isfile(sp)):
        c["feature"] = ("GAP", "NOTE (ISS-...) marks the pipeline_test as an unresolved forward-reference", "feature-gap (UNBUILT_FEATURE)")
    elif s["fwd_spec"]:
        c["feature"] = ("UNKNOWN", "NOTE (ISS-...) calls the spec a forward-reference but the file now exists; NOTE may be stale", "letflow (BA/UAT-RUNNER: refresh NOTE)")
    else:
        c["feature"] = ("OK", "no forward-reference NOTE", "")
    c["local_deps"] = local_deps_check(sp)
    t = s["tenant"]
    if not t or t == "platform":
        c["tenant"] = ("OK", "platform scope", "")
    elif tenants_found is None:
        c["tenant"] = ("UNKNOWN", tenants_reason, "letflow (fix credentials first)")
    elif t.lower() in tenants_found:
        c["tenant"] = ("OK", "tenant '%s' present" % t, "")
    else:
        c["tenant"] = ("GAP", "tenant '%s' not in GET /api/v1/tenants" % t, "ai-dala-infra (create tenant)")
    slug = t if t and t != "platform" else "bpm-default"
    rs = realm_state.get(slug)
    c["realm"] = ("OK", "realm '%s' reachable" % slug, "") if rs == 200 else \
        ("GAP", "realm '%s' -> HTTP %s" % (slug, rs), "ai-dala-infra (create realm)")
    # actors
    scenario_ok_tokens = []  # (aid, [label, ...], access_token) -- ISS-0894 Decision 1
    if cred_listing is None:
        c["actors"] = ("UNKNOWN", "credential source unusable: %s" % cred_err, "ai-dala-infra")
    else:
        missing, unknown, bad, norole, need = [], [], [], [], 0
        norole_realms = []
        for aid in s["actor_ids"]:
            if aid.startswith("actor-system-") or aid == "actor-any": continue
            need += 1
            if aid == "actor-platform-admin":
                users = [u for u in cred_listing if u == "admin-user"]
            else:
                # exact-name match first (ai-dala-infra T-0150 realm-qualified accounts,
                # ISS-0894 Decision 2), old prefix heuristic kept as fallback.
                if aid in cred_listing:
                    users = [aid]
                else:
                    m = re.match(r"actor-([a-z0-9]+)-([a-z0-9]+)$", aid)
                    if not m: unknown.append(aid); continue
                    nm = m.group(2)
                    users = [u for u in cred_listing if u != "admin-user" and (u == nm or u.startswith(nm + "-"))]
            if not users: missing.append(aid); continue
            state, realm_used = try_login(aid, users[0], realms_for(aid, t))
            if state == "NO_APP_ROLE": norole.append("%s@%s(%s)" % (aid, realm_used, state)); norole_realms.append(realm_used)
            elif state != "OK": bad.append("%s(%s)" % (aid, state))
            else: scenario_ok_tokens.append((aid, s["actor_labels"].get(aid, []), tokens[(aid, realm_used)]))
        if missing or bad or norole:
            reason, owners = [], []
            if missing: reason.append("no seeded user: " + ", ".join(missing))
            if bad: reason.append("login failed: " + ", ".join(bad))
            if norole: reason.append("authenticated, but Letflow resolves no role for this user in tenant %s; check the tenant's platform-role bindings (RoleBackfill) and the user's group memberships: %s" % (", ".join(sorted(set(norole_realms))), ", ".join(norole)))
            if missing or bad: owners.append("ai-dala-infra (Keycloak users) + letflow-seed (scripts/seed_*_actors.sh)")
            if norole: owners.append("letflow (tenant role bindings: RoleBackfill / group memberships)")
            c["actors"] = ("GAP", "; ".join(reason), "; ".join(owners))
        elif unknown:
            c["actors"] = ("UNKNOWN", "cannot map: " + ", ".join(unknown), "")
        else:
            c["actors"] = ("OK", "%d login actor(s) resolved & token valid" % need if need else "no login actors needed", "")
    # app_roles: beyond token validity, check the app-side role binding actually
    # grants a route (ISS-0886-class gap) -- ISS-0894 Decision 1/"app_roles endpoint choice".
    if not scenario_ok_tokens:
        c["app_roles"] = ("UNKNOWN", "no authenticated actor token available for this tenant to check app-side role binding", "")
    else:
        ok, gap, unk = [], [], []
        for aid, labels, tok in scenario_ok_tokens:
            is_candidate = any("candidate" in (lbl or "").lower() for lbl in labels)
            if aid == "actor-platform-admin":
                # /tasks/inbox is uninformative for a platform admin -- an admin may
                # hold no TASK-oriented role at all regardless of their actual role
                # grant, so a 403/200 there says nothing real about role binding.
                # GET /api/v1/identity/users is a tenant-scope admin-only route
                # (:UsersManage -> :UsersGroupsRolesManage, held by PLATFORM_ADMIN in
                # every tenant), so 200 there is a real, specific role-binding signal
                # for this actor in ITS OWN tenant realm. /admin/services used to be
                # the probe, but ISS-0993 made it PLATFORM scope (:PlatformServicesManage,
                # honoured only for a PLATFORM_ADMIN of the configured platform tenant),
                # which a tenant-realm account can never satisfy; that route is now
                # probed by the separate optional "platform_operator" global check.
                # ISS-0909(c), ISS-0993.
                path = "/api/v1/identity/users"
            elif is_candidate:
                path = "/api/v1/me/modules"
            else:
                path = "/api/v1/tasks/inbox"
            st_, _ = http("GET", base + path, auth(tok))
            if st_ == 200: ok.append("%s(%s)" % (aid, path))
            elif st_ == 403: gap.append("%s(%s@%s)" % (aid, st_, path))
            else: unk.append("%s(%s@%s)" % (aid, st_, path))
        if gap:
            c["app_roles"] = ("GAP", "role not bound: " + ", ".join(gap),
                               "letflow (ISS-0886 role backfill; run mix letflow.backfill_platform_roles)")
        elif unk:
            c["app_roles"] = ("UNKNOWN", "unexpected result: " + ", ".join(unk), "")
        else:
            c["app_roles"] = ("OK", "%d actor(s) app-role bound" % len(ok), "")
    # definitions: process_id resolution -- ISS-0894 Decision 3.
    pid = s["process_id"]
    if not pid or pid == "n/a" or not pid.startswith("proc-"):
        c["definitions"] = ("OK", "no proc-* process_id declared (n/a, or a sys-* platform mechanism label, not a deployable definition)", "")
    elif not scenario_ok_tokens:
        c["definitions"] = ("UNKNOWN", "no authenticated actor token available for this tenant to check definition resolution", "")
    else:
        tok = scenario_ok_tokens[0][2]
        resolved_name = pd_aliases.get(pid, pid)
        st_, _ = http("GET", base + "/api/v1/definitions/active/" + urllib.parse.quote(resolved_name, safe=""), auth(tok))
        if st_ == 200:
            if resolved_name != pid:
                c["definitions"] = ("OK", "GET /definitions/active/%s -> 200 (process_id '%s' resolved via alias)" % (resolved_name, pid), "")
            else:
                c["definitions"] = ("OK", "GET /definitions/active/%s -> 200" % resolved_name, "")
        elif st_ == 404:
            if resolved_name != pid:
                c["definitions"] = ("GAP",
                    "process definition '%s' (alias for process_id '%s') does not resolve via GET /definitions/active/:name (see ISS-0893)" % (resolved_name, pid),
                    "letflow (ISS-0893 key resolution) / ai-dala-infra (ISS-0897 seed meridian/vortex definitions)")
            else:
                c["definitions"] = ("GAP",
                    "process definition '%s' does not resolve via GET /definitions/active/:name "
                    "(see ISS-0893 null-key / ISS-0897 meridian-vortex definitions not yet seeded)" % pid,
                    "letflow (ISS-0893 key resolution) / ai-dala-infra (ISS-0897 seed meridian/vortex definitions)")
        elif st_ == 403:
            c["definitions"] = ("UNKNOWN", "actor token lacks DefinitionsRead; cannot check definition resolution", "")
        else:
            c["definitions"] = ("UNKNOWN", "GET /definitions/active/%s -> %s" % (resolved_name, st_), "")
    # env_limitation: additive, independent of tenant/realm/actors above -- ISS-0895.
    # Status stays OK/GAP (matching every other check's convention, and the
    # counts/ready aggregation below, which only knows OK/GAP/UNKNOWN) -- the sidecar's
    # specific classification (e.g. ENV_NOT_SUPPORTED) is embedded in the reason text,
    # same as local_deps/feature already embed their own specific codes in reason/owner.
    lim = env_limitations.get(s["id"])
    if not lim or a.environment not in (lim.get("applies_to_environments") or []):
        c["env_limitation"] = ("OK", "no known environment limitation", "")
    else:
        eo_scope = lim.get("applies_to_expected_outcomes")
        reason_ = "%s: %s" % (lim.get("classification", "ENV_NOT_SUPPORTED"), lim.get("reason", ""))
        if lim.get("disposition") == "skipped":
            skipped[s["id"]] = lim
            c["env_limitation"] = (
                "SKIP", reason_,
                "skipped scenario (issue_ref=%s) -- not executed, not BLOCKED, no issue filed" % lim.get("issue_ref", "?"))
        else:
            if eo_scope:
                reason_ += " (scope: %s only; other expected outcomes in this scenario are " \
                    "unaffected and must still be verified)" % ", ".join(eo_scope)
            c["env_limitation"] = (
                "GAP",
                reason_,
                "environment-structural (permanent; issue_ref=%s) -- no prep remediation; "
                "re-running preflight will report this same GAP by design" % lim.get("issue_ref", "?"),
            )
    rows.append((s, c))

# ---------------------------------------------------------------- report
out = []
P_ = out.append
P_("UAT PREFLIGHT  environment=%s  base_url=%s  idp=%s" % (a.environment, base, idp))
P_("expected build (origin/main): %s" % (exp_sha or "unknown"))
P_("scenarios: %d   corpus: %s" % (len(scenarios), os.path.relpath(scen_dir, REPO).replace("\\", "/")))
P_("")
P_("== MANIFEST ==")
P_("tenants needed        : %s" % (", ".join(tenant_slugs_needed) or "-"))
P_("keycloak realms needed: %s" % ", ".join(sorted(set(tenant_slugs_needed) | {"bpm-default"})))
P_("actors (login)        : %s" % ", ".join(sorted({x for s in scenarios for x in s["actor_ids"]
                                                    if not x.startswith("actor-system-") and x != "actor-any"})))
P_("process definitions   : %s" % ", ".join(sorted({s["process_id"] for s in scenarios if s["process_id"]})))
P_("pipeline specs        : %d declared" % sum(1 for s in scenarios if s["pipeline_test"]))
P_("seeded usernames      : %s" % (", ".join(cred_listing) if cred_listing else "UNAVAILABLE (%s)" % cred_err))
P_("credential validity   : " + (", ".join("%s@%s=%s" % (aid, realm, state)
                                            for (aid, realm), state in sorted(realm_status.items())) or "none checked"))
P_("")
P_("== GLOBAL CHECKS ==")
for k, (st_, why, own) in g.items():
    P_("%-14s %-8s %s%s" % (k, st_, why, "   [owner: %s]" % own if own and st_ != "OK" else ""))
P_("")
P_("== GAP TABLE (scenario x check) ==")
w = max(len(s["id"]) for s, _ in rows)
P_("%-*s  %s" % (w, "scenario", "  ".join("%-10s" % k for k in CHECKS)))
for s, c in rows:
    P_("%-*s  %s" % (w, s["id"], "  ".join("%-10s" % c[k][0] for k in CHECKS)))
P_("")
P_("== DETAIL (non-OK) ==")
counts = {"OK": 0, "GAP": 0, "UNKNOWN": 0}
bad_scen = set()
for k, (st_, why, own) in g.items():
    counts[st_] += 1
    if st_ != "OK":
        P_("[%s] GLOBAL/%s: %s  -> owner: %s" % (st_, k, why, own or "-"))
        if st_ == "GAP": bad_scen.add("*")
for s, c in rows:
    is_skipped = s["id"] in skipped
    for k in CHECKS:
        st_, why, own = c[k]
        if is_skipped:  # shown, never counted: the scenario will not be driven
            if st_ not in ("OK", "SKIP"):
                P_("[SKIPPED/%s] %s/%s: %s  -> owner: %s  (not counted)" % (st_, s["id"], k, why, own or "-"))
            continue
        counts[st_] += 1
        if st_ != "OK":
            P_("[%s] %s/%s: %s  -> owner: %s" % (st_, s["id"], k, why, own or "-"))
            if st_ == "GAP": bad_scen.add(s["id"])
P_("")
if skipped:
    P_("== SKIPPED SCENARIOS ==")
    for sid in sorted(skipped):
        lim = skipped[sid]
        P_("%s  classification=%s  issue_ref=%s" % (sid, lim.get("classification", "?"), lim.get("issue_ref", "?")))
        P_("  reason: %s" % lim.get("reason", ""))
    P_("")
gap_scen = sorted(x for x in bad_scen if x != "*")
ready = counts["GAP"] == 0
P_("== SUMMARY ==")
P_("checks: OK=%d GAP=%d UNKNOWN=%d" % (counts["OK"], counts["GAP"], counts["UNKNOWN"]))
P_("scenarios with >=1 GAP: %d of %d" % (len(gap_scen), len(scenarios)))
P_("RESULT: %s" % ("ENV_READY" if ready else "ENV_NOT_READY"))
text = "\n".join(out)
print(text)

if a.out:
    summ = {"environment": a.environment, "base_url": base, "expected_sha": exp_sha,
            "result": "ENV_READY" if ready else "ENV_NOT_READY", "counts": counts,
            "skipped": sorted(skipped),
            "global": {k: {"status": v[0], "reason": v[1], "owner": v[2]} for k, v in g.items()},
            "scenarios": {s["id"]: {k: {"status": c[k][0], "reason": c[k][1], "owner": c[k][2]} for k in CHECKS} for s, c in rows}}
    with open(winpath(a.out), "w", encoding="utf-8") as fh: json.dump(summ, fh, indent=2)
sys.exit(0 if ready else 1)
PYEOF
