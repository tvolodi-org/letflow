"""Rule table for the OSS audit scanner (T-1597).

Pure data plus small helpers; stdlib only. A rule never returns the matched text to the
caller of the scanner's output layer: `scanner.py` turns a match into a masked hint.

Rule record fields:
  id        stable id (S = secret, P = personal data, I = infra, N = wording)
  sev       C critical (rotate), H high, M medium, L low/info
  cls       secret | pii | infra | name
  rx        compiled regex; the named group `v` is the sensitive value (whole match if absent)
  needles   lowercase substrings; the regex runs only if one is in the lowercased line
  exts      None, or a set of file classes the rule applies to (see scanner.file_kind)
  noise     True: only emitted with --include-noise
  mode      how a hit becomes a hint: 'mask' (2+2 of the value), 'domain', 'keyword', 'fixed'
"""

import re

# Values that are placeholders, not secrets.
_PLACEHOLDER_PARTS = (
    "changeme", "change-me", "change_me", "example", "placeholder", "your-", "your_", "yourpass",
    "xxx", "dummy", "fake", "todo", "redacted", "not-a-real", "notreal", "sample", "<", ">", "${",
    "$(", "{{", "%{", "#{", "System.", "Application.", "process.env", "os.environ", "get_env",
    "env(", "secret-key", "...", "***",
)
_PLACEHOLDER_EXACT = {
    "", "dev", "development", "password", "passwd", "secret", "admin", "postgres", "letflow",
    "keycloak", "token", "null", "nil", "none", "true", "false", "undefined", "empty", "string",
    "bearer", "root", "user", "username", "key", "value", "foo", "bar", "123456", "12345678",
}
# A bare identifier / field reference (`params.password`, `Foo::Bar`, `some_field`) has a separator;
# a separator-free run of letters can be a real password, so it is NOT treated as a placeholder.
_IDENT = re.compile(r"^(?=[A-Za-z_.:/]*[_.:/])[A-Za-z_][A-Za-z_.:/]*$")


def is_placeholder(value: str) -> bool:
    """True if `value` is obviously not a real secret (stop list, variable reference, bare identifier)."""
    v = value.strip().strip("'\"`,;)")
    if v.lower() in _PLACEHOLDER_EXACT:
        return True
    low = v.lower()
    if v.startswith(("$", "@", "[", "(", "&", "*", ":")):
        return True
    if any(p.lower() in low for p in _PLACEHOLDER_PARTS):
        return True
    if len(v) < 8:
        return True
    if _IDENT.match(v):  # a bare identifier / field name, not a credential
        # snake_case with random capitals (Ab_cdEf) is more likely a password than a name
        if re.search(r"[.:/]", v) or not (re.search(r"[a-z]", v) and re.search(r"[A-Z]", v)):
            return True
    return False


def _c(pattern, flags=0):
    return re.compile(pattern, flags)


# file kinds for `exts`: 'config' = env/yaml/sh/compose/exs/json/toml/ini/Dockerfile/service files.
RULES = [
    dict(id="S01", sev="C", cls="secret", mode="fixed", needles=("private key",),
         rx=_c(r"-----BEGIN (?:[A-Z0-9]{2,12} ){0,3}PRIVATE KEY(?: BLOCK)?-----")),
    dict(id="S02", sev="C", cls="secret", mode="mask", needles=("akia", "asia", "aws_secret", "aws-secret"),
         rx=_c(r"(?:\b(?P<v>(?-i:(?:AKIA|ASIA)[0-9A-Z]{16}))\b|aws_?secret_?(?:access_?)?key\W{1,4}(?P<v2>[A-Za-z0-9/+=]{40})(?![A-Za-z0-9/+=]))",
               re.I)),
    dict(id="S03", sev="C", cls="secret", mode="mask", needles=("aiza", "private_key"),
         rx=_c(r"(?:\b(?P<v>AIza[0-9A-Za-z_\-]{35})\b|\"private_key\"\s*:\s*\"-----BEGIN)")),
    dict(id="S04", sev="C", cls="secret", mode="mask", needles=("accountkey=", "sharedaccesssignature", "sig="),
         rx=_c(r"(?:AccountKey=(?P<v>[A-Za-z0-9+/=]{20,})|SharedAccessSignature=(?P<v2>[A-Za-z0-9%+/=&;-]{20,})|[?&]sig=(?P<v3>[A-Za-z0-9%+/=]{30,}))")),
    dict(id="S05", sev="C", cls="secret", mode="mask", needles=("hcloud", "hetzner"), exts={"config", "doc"},
         rx=_c(r"\b(?:HCLOUD_TOKEN|HETZNER\w*(?:TOKEN|KEY|SECRET|PASSWORD))\b[\"']?\s*[:=]\s*[\"']?(?P<v>[^\s\"'#,;]+)"),
         check_value=True),
    dict(id="S06", sev="C", cls="secret", mode="mask", needles=("cloudflare", "cf_api"), exts={"config", "doc"},
         rx=_c(r"\b(?:CF_API_\w+|CLOUDFLARE_\w*(?:TOKEN|KEY|SECRET))\b[\"']?\s*[:=]\s*[\"']?(?P<v>[^\s\"'#,;]+)"),
         check_value=True),
    dict(id="S07", sev="C", cls="secret", mode="mask", needles=("keycloak", "kc_", "client_secret"),
         exts={"config", "doc"},
         rx=_c(r"\b(?:KEYCLOAK\w*(?:SECRET|PASSWORD)|KC_\w*PASSWORD|client_secret)\w*[\"']?\s*[:=]\s*[\"']?(?P<v>[^\s\"'#,;]+)", re.I),
         check_value=True),
    dict(id="S08", sev="C", cls="secret", mode="mask", needles=("sk-",),
         rx=_c(r"\b(?P<v>sk-ant-[A-Za-z0-9_\-]{20,}|sk-(?:proj-)?[A-Za-z0-9_\-]{32,})")),
    dict(id="S09", sev="C", cls="secret", mode="mask", needles=("ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_"),
         rx=_c(r"\b(?P<v>gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})")),
    dict(id="S10", sev="C", cls="secret", mode="mask", needles=("xox", "_live_", "sg.", "bearer "),
         rx=_c(r"(?:\b(?P<v>xox[abprs]-[A-Za-z0-9-]{10,}|[sr]k_live_[A-Za-z0-9]{16,}|SG\.[A-Za-z0-9_\-]{16,}\.[A-Za-z0-9_\-]{16,})|\bBearer\s+(?P<v2>[A-Za-z0-9._\-]{40,}))")),
    dict(id="S11", sev="H", cls="secret", mode="mask", needles=("eyj",),
         rx=_c(r"\b(?P<v>eyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]*)")),
    dict(id="S12", sev="H", cls="secret", mode="mask", needles=("://",),
         rx=_c(r"\b(?:postgres(?:ql)?|mysql|amqp|redis|mongodb(?:\+srv)?)://(?P<u>[^\s:/@'\"`<>]{1,64}):(?P<v>[^\s@'\"`/<>]{3,128})@(?P<h>[^\s:/'\"`<>]{1,128})"),
         check_value=True, conn=True),
    dict(id="S13", sev="H", cls="secret", mode="mask",
         needles=("password", "secret", "token", "api_key", "private_key", "master_key", "salt"),
         exts={"config"},
         rx=_c(r"\b[A-Za-z0-9_]{0,40}(?:PASSWORD|SECRET|TOKEN|API_KEY|PRIVATE_KEY|MASTER_KEY|SALT)[A-Za-z0-9_]{0,20}[\"']?\s*[:=]\s*[\"']?(?P<v>[^\s\"'#,;)]{8,200})", re.I),
         check_value=True),
    dict(id="S14", sev="M", cls="secret", mode="mask", needles=("=", ":"), noise=True, entropy=True,
         exts={"config"},
         rx=_c(r"[:=]\s*[\"']?(?P<v>[A-Za-z0-9+/=_\-]{24,128})(?![A-Za-z0-9+/=_\-])")),
    dict(id="P01", sev="M", cls="pii", mode="domain", needles=("@",),
         rx=_c(r"(?<![\w.%+\-/])(?P<l>[A-Za-z0-9][A-Za-z0-9._%+\-]{0,63})@(?P<d>[A-Za-z0-9][A-Za-z0-9.\-]{0,200}\.[A-Za-z]{2,24})\b")),
    dict(id="P02", sev="M", cls="pii", mode="fixed", needles=("+7", "+38", "+1", "8 ("),
         rx=_c(r"(?:(?<![\w.])\+(?:7|380|1)[\s\-]?\(?\d{2,3}\)?[\s\-]?\d{3}[\s\-]?\d{2}[\s\-]?\d{2}(?!\d)|(?<![\w.])8 \(7\d\d\) ?\d{3}[\s\-]?\d{2}[\s\-]?\d{2}(?!\d))")),
    dict(id="I01", sev="M", cls="infra", mode="fixed", needles=(".",), ip=True,
         rx=_c(r"(?<![\w.\-])(?P<v>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(?![\w])(?!\.\d)")),
    dict(id="I02", sev="L", cls="infra", mode="fixed", needles=(".",), ip=True, noise=True,
         rx=_c(r"(?<![\w.\-])(?P<v>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(?![\w])(?!\.\d)")),
    dict(id="I03", sev="M", cls="infra", mode="host", needles=("ai-dala.com",),
         rx=_c(r"(?P<v>(?:[A-Za-z0-9\-]+\.){1,6}ai-dala\.com)\b", re.I)),
    dict(id="N01", sev="L", cls="name", mode="keyword",
         needles=("qoimeks", "bilimbaga", "bilim baga", "r-co", "ai-dala", "meridian", "swiftroute", "vortex"),
         rx=_c(r"(?<![\w])(?P<v>Qoimeks|BilimBaga|Bilim\s?Baga|R-Co|ai-dala|Meridian|SwiftRoute|Vortex)(?![\w])", re.I)),
    dict(id="N02", sev="L", cls="name", mode="fixed", needles=("users\\", "/home/", "/users/"),
         rx=_c(r"(?:\b[A-Za-z]:[\\/]+Users[\\/]+(?!Public\b|Default\b|runneradmin\b)[A-Za-z0-9_.\-]+|(?<![\w.])/home/(?!runner\b|user\b|app\b|node\b|elixir\b|letflow\b|postgres\b|deploy\b|ubuntu\b|vscode\b|\$|<|\.\.)[a-z][a-z0-9_\-]{1,31}/|(?<![\w.])/Users/(?!Shared\b|runner\b|\$)[A-Za-z][A-Za-z0-9_\-]{1,31}/)")),
]

RULE_IDS = [r["id"] for r in RULES]
SECRET_RULE_IDS = {r["id"] for r in RULES if r["cls"] == "secret" and not r.get("noise")}

PII_RESERVED_DOMAINS = (
    "example.", ".test", "localhost", ".invalid", ".internal", ".local", ".example", "noreply",
    "users.noreply.github.com", "@types",
)
PII_FILE_TLDS = {
    "js", "ts", "tsx", "jsx", "ex", "exs", "json", "md", "png", "jpg", "jpeg", "gif", "svg", "css",
    "yml", "yaml", "html", "map", "txt", "sh", "py", "dart", "lock", "toml", "webp", "ico", "woff",
    "woff2", "eex", "heex", "leex", "sql", "xml", "csv", "log", "mjs", "cjs",
}

STOP_NAMES_RESERVED = {"@types"}
