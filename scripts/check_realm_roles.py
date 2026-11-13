#!/usr/bin/env python3
"""Fail when a Keycloak realm export lacks one of the nine built-in realm roles.

Usage: python3 -I scripts/check_realm_roles.py [realm.json ...]

A realm cloned from the template carries ALL nine built-in roles of
lib/letflow/api/authorization.ex @roles (PM decision, T-1862). With no path it checks the
committed fixtures: priv/keycloak/realms/bpm-default.json (the template fixture) and
docs/runbooks/demo-realm/*.json. Stdlib only; exit 0 = all present, 1 = something
missing, 2 = unreadable input.
"""
import glob
import json
import os
import sys

REQUIRED = [
    "AGENT_RUNNER",
    "CANDIDATE",
    "PLATFORM_ADMIN",
    "PROCESS_DESIGNER",
    "PROCESS_OPERATOR",
    "STOREKEEPER",
    "TASK_WORKER",
    "TENANT_ADMIN",
    "TENANT_AUDITOR",
]


def missing(path):
    try:
        with open(path, encoding="utf-8") as fh:
            realm = json.load(fh)
        names = {r["name"] for r in realm["roles"]["realm"]}
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"{path}: unreadable realm export ({type(exc).__name__})", file=sys.stderr)
        sys.exit(2)
    return [r for r in REQUIRED if r not in names]


def main(argv):
    paths = [a for a in argv if not a.startswith("--")]
    if not paths:
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
        paths = [os.path.join(root, "priv/keycloak/realms/bpm-default.json")]
        paths += sorted(glob.glob(os.path.join(root, "docs/runbooks/demo-realm/*.json")))
    bad = False
    for p in paths:
        gone = missing(p)
        if gone:
            bad = True
            print(f"{p}: missing realm roles: {', '.join(gone)}")
        else:
            print(f"{p}: ok")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
