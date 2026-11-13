#!/usr/bin/env python3
"""Fail when a Keycloak realm export lacks a realm role every tenant realm must carry.

Usage: python3 -I scripts/check_realm_roles.py [--platform] [realm.json ...]

With no path it checks the committed fixtures docs/runbooks/demo-realm/*.json.
Required in every realm: the tenant roles below (the built-in roles of
lib/letflow/api/authorization.ex @roles that come from the IdP). `--platform` also
requires PLATFORM_ADMIN (platform realm only); a tenant realm must never carry it,
which is a different check (the template drift test). AGENT_RUNNER is optional.
Stdlib only; exit 0 = all present, 1 = something missing, 2 = unreadable input.
"""
import glob
import json
import os
import sys

TENANT_REQUIRED = [
    "TENANT_ADMIN",
    "PROCESS_DESIGNER",
    "PROCESS_OPERATOR",
    "TASK_WORKER",
    "CANDIDATE",
    "TENANT_AUDITOR",
    "STOREKEEPER",
]
OPTIONAL = ["AGENT_RUNNER"]
PLATFORM_ONLY = ["PLATFORM_ADMIN"]


def missing(path, platform):
    try:
        with open(path, encoding="utf-8") as fh:
            realm = json.load(fh)
        names = {r["name"] for r in realm["roles"]["realm"]}
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"{path}: unreadable realm export ({type(exc).__name__})", file=sys.stderr)
        sys.exit(2)
    need = TENANT_REQUIRED + (PLATFORM_ONLY if platform else [])
    return [r for r in need if r not in names]


def main(argv):
    platform = "--platform" in argv
    paths = [a for a in argv if not a.startswith("--")]
    if not paths:
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
        paths = sorted(glob.glob(os.path.join(root, "docs/runbooks/demo-realm/*.json")))
        platform = True  # the demo fixtures are platform-and-tenant demo realms
    if not paths:
        print("no realm export found", file=sys.stderr)
        return 2
    bad = False
    for p in paths:
        gone = missing(p, platform)
        if gone:
            bad = True
            print(f"{p}: missing realm roles: {', '.join(gone)}")
        else:
            print(f"{p}: ok")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
