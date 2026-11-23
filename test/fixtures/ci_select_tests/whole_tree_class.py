#!/usr/bin/env python3
"""The whole-tree reader class of T-2691, derived independently of the selector.

The class is the set of test files that read a whole tree of the backend source and pin
it (an allowlist, a ledger or a count). A diff that touches the tree can break such a
pin, so every member is a MANDATORY check of a backend-source diff.

This file is the ORACLE of `test/letflow/ci_select_tests_test.exs`: it derives the class
from the tree on its own, so the selector cannot silently narrow the class. T-2691
rework 2: the selector and the oracle both recognized only a literal `lib/**` in the test
source, so the scan of the role-scope-grants writers - whose wildcard lives in the
scanner it calls - was in neither the class nor the completeness assertion.

A member reads a whole tree in one of two ways:
  * directly: a glob over a backend-source root (`"lib/**"`, `"priv/**/*"`);
  * through a helper: the test calls a module of lib/ (or of test/support/) that walks a
    tree, and the roots that helper scans lie in the backend source.

A scan of a tree outside the backend source (the handoff tree, the web tree) is not a
member: a backend-source diff cannot break its pin.

usage: whole_tree_class.py [root]   -> one test path per line
"""
import os, re, subprocess, sys, glob as globmod

DOMAIN = ("lib/", "priv/", "config/", "scripts/", "test/support/")
ROOT_RE = re.compile(r"^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$")
GLOB_RE = re.compile(r"^([A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*)/\*\*")
PATH_RE = re.compile(r"[A-Za-z0-9_./-]*$")
MARKER_RE = re.compile(r"/\*\*")
ALIAS_RE = re.compile(r"^\s*alias\s+([A-Z][A-Za-z0-9_.]*)(?:\s*,\s*as:\s*([A-Z][A-Za-z0-9_]*))?", re.M)
CALL_RE = re.compile(r"\b([A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)\.([a-z_][A-Za-z0-9_?!]*)\(([^()]*)\)")
MODULE_RE = re.compile(r"^\s*defmodule\s+([A-Z][A-Za-z0-9_.]*)", re.M)
LIST_RE = re.compile(r"\[([^\[\]]*)\]")
ATTR_RE = re.compile(r"@\w+\s+\"([^\"]*)\"")
LIT_RE = re.compile(r'"([^"]*)"')

def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""

def source_root(literal):
    if not ROOT_RE.match(literal):
        return None
    if "." in literal.rsplit("/", 1)[-1]:
        return None
    for prefix in DOMAIN:
        if literal + "/" == prefix or prefix.startswith(literal + "/") or literal.startswith(prefix):
            return literal
    return None

def glob_roots(text):
    roots = set()
    for marker in MARKER_RE.finditer(text):
        tail = PATH_RE.search(text, 0, marker.start())
        if not tail or not tail.group(0):
            continue
        if tail.start() == 0 or text[tail.start() - 1] not in "\"'":
            continue
        root = source_root(tail.group(0))
        if root:
            roots.add(root)
    return roots

def helper_modules(root):
    modules = {}
    for pattern in ("lib/**/*.ex", "test/support/**/*.ex"):
        for path in sorted(globmod.glob(os.path.join(root, pattern), recursive=True)):
            text = read(path)
            if "Path.wildcard" in text and '"**' in text:
                for module in MODULE_RE.findall(text):
                    modules.setdefault(module, text)
    return modules

def helper_roots(helper):
    roots = set()
    candidates = []
    for match in LIST_RE.finditer(helper):
        candidates.extend(LIT_RE.findall(match.group(1)))
    candidates.extend(ATTR_RE.findall(helper))
    for candidate in candidates:
        root = source_root(candidate)
        if root:
            roots.add(root)
    return roots

def attribute_literals(text, name):
    match = re.search(r"@" + re.escape(name) + r"\s*\[", text)
    if not match:
        return []
    depth = 0
    for index in range(match.end() - 1, len(text)):
        if text[index] == "[":
            depth += 1
        elif text[index] == "]":
            depth -= 1
            if depth == 0:
                return LIT_RE.findall(text[match.end():index])
    return []

def indirect_roots(text, modules):
    aliases = {}
    for full, short in ALIAS_RE.findall(text):
        aliases[short or full.rsplit(".", 1)[-1]] = full
    roots = set()
    for module, _function, arguments in CALL_RE.findall(text):
        target = aliases.get(module)
        if target is None and "." in module:
            target = module
        if target is None:
            matches = [full for short, full in aliases.items() if short.rsplit(".", 1)[-1] == module]
            target = matches[0] if matches else None
        if not target or target not in modules:
            continue
        helper = modules[target]
        if "Path.wildcard" not in helper or '"**' not in helper:
            continue
        roots.update(helper_roots(helper))
        argument = arguments.strip()
        candidates = []
        if argument.startswith("["):
            candidates.extend(LIT_RE.findall(argument))
        elif argument.startswith("@"):
            candidates.extend(attribute_literals(text, argument[1:]))
        for candidate in candidates:
            root = source_root(candidate)
            if root:
                roots.add(root)
    return roots

def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    modules = helper_modules(root)
    files = subprocess.run(["git", "ls-files", "-z", "--", "test/"], cwd=root,
                           capture_output=True).stdout.decode("utf-8", "replace")
    members = []
    for path in files.split("\0"):
        if not path.endswith("_test.exs"):
            continue
        text = read(os.path.join(root, path))
        roots = glob_roots(text) | indirect_roots(text, modules)
        if roots:
            members.append(path)
    for path in sorted(set(members)):
        print(path)

main()
