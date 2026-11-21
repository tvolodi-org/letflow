"""The denylist of retired QA tenants (T-2538): test/uat/retired-tenants.json.

Stdlib only. `violations(doc, name, retired)` lists every place a process, chain or fixture document names a retired
tenant (tenant, actors, base urls, also inside its dry_run block); the runner, check_processes.py and dry-run call it
and stop with exit 2 before any request.
"""

from __future__ import annotations

import json
from pathlib import Path

DENYLIST = "test/uat/retired-tenants.json"


class RetiredError(Exception):
    pass


def default_root() -> Path:
    return Path(__file__).resolve().parents[2]


def load_retired(root=None) -> dict:
    """-> {slug: reason}. A missing or unreadable denylist is an error, never an empty list (fail closed)."""
    path = Path(root or default_root()) / DENYLIST
    if not path.is_file():  # a scratch checkout without its own list: the one next to this script
        path = default_root() / DENYLIST
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        retired = data["retired"]
    except (OSError, ValueError, KeyError, TypeError) as err:
        raise RetiredError(f"cannot read the retired-tenants denylist {path}: {err}") from None
    if isinstance(retired, list):
        retired = {str(s): "" for s in retired}
    if not isinstance(retired, dict) or not retired:
        raise RetiredError(f"{path}: 'retired' must be a non-empty object of tenant slugs")
    return {str(k): str(v) for k, v in retired.items()}


def retired_tenant_of(tenant, retired) -> str | None:
    return tenant if isinstance(tenant, str) and tenant in retired else None


def retired_tenant_of_user(user, retired) -> str | None:
    if not isinstance(user, str):
        return None
    for slug in retired:
        if user == slug or user.startswith(slug + "-"):
            return slug
    return None


def retired_tenant_of_url(url, retired) -> str | None:
    if not isinstance(url, str):
        return None
    for slug in retired:
        if f"//{slug}." in url or f"/{slug}/" in url or url.endswith("/" + slug):
            return slug
    return None


def _block_violations(block, where, retired, out):
    if not isinstance(block, dict):
        return
    slug = retired_tenant_of(block.get("tenant"), retired)
    if slug:
        out.append(f"{where}tenant {slug!r} is retired")
    actors = block.get("actors")
    if isinstance(actors, dict):
        for actor, user in actors.items():
            slug = retired_tenant_of_user(user, retired)
            if slug:
                out.append(f"{where}actor {actor!r} names the user {user!r} of the retired tenant {slug!r}")
    for key in ("base_url", "old_base_url"):
        slug = retired_tenant_of_url(block.get(key), retired)
        if slug:
            out.append(f"{where}{key} points at the retired tenant {slug!r}")


def violations(doc, name, retired) -> list:
    """-> lines 'name: ... retired ...' for one process, chain or fixture document."""
    out: list = []
    if not isinstance(doc, dict):
        return out
    _block_violations(doc, f"{name}: ", retired, out)
    _block_violations(doc.get("dry_run"), f"{name}: dry_run ", retired, out)
    return out


def violations_in_file(path, retired) -> list:
    path = Path(path)
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []  # the static check reports unreadable files
    return violations(doc, path.name, retired)


def batch_lines(entries, retired) -> list:
    """entries: [(file name, tenant, actors dict)] -> one line per DISTINCT tenant, with its actors and files."""
    seen: dict = {}
    for fname, tenant, actors in entries:
        slot = seen.setdefault(tenant, {"users": set(), "files": []})
        slot["users"].update(v for v in (actors or {}).values() if isinstance(v, str))
        slot["files"].append(fname)
    lines = []
    for tenant, slot in seen.items():
        flag = "  RETIRED" if retired_tenant_of(tenant, retired) else ""
        lines.append(f"batch tenant {tenant}: actors {', '.join(sorted(slot['users'])) or '-'}; "
                     f"{len(slot['files'])} file(s){flag}")
    return lines
