#!/usr/bin/env python3
"""bp_doc.py -- the business-process map in plain words (D-173).

`docs/bp/<area>.json` is the map of one area: a JSON list of business processes, written in
the user's words (the schema: docs/bp/README.md). This tool renders that map into
`docs/bp/<area>.md` -- a document the owner can read: the processes of the area in a table,
then every process in plain words: what it is, who may do it, the numbered steps with the
screen and the call of each step, what it refuses, the tests, the runner scenario, the
status and the gaps.

The table carries the **Executed by** column (D-175): `direct` (a hard-coded route or
function) or `definition:<process_key>` (the process runs as a BPM definition of the engine).
A missing field means `direct`; the head of the document counts how many processes of the area
are `direct` and how many are `definition:`.

    python3 scripts/bp/bp_doc.py mes             # write docs/bp/mes.md
    python3 scripts/bp/bp_doc.py all             # write every area
    python3 scripts/bp/bp_doc.py --check         # the gate: the committed .md must equal the render
    python3 scripts/bp/bp_doc.py mes --proof DIR # the Machine-proven column, filled from a runner report

THE RENDER IS DETERMINISTIC: the processes are sorted by id, every list is sorted, there is
no timestamp and no model in the output. The same checkout gives the same bytes, so
`--check` is a real gate: a map that changed without its document fails it.

THE MACHINE-PROVEN COLUMN

    the static render   "see report"  -- the proof is in the runner's report, not here
    with --proof DIR    "PASS on <sha> <date>" per process

`--proof DIR` reads the runner's verdict files (the table `| process | build sha | result |
when |`) and fills the column. The proof mode is NEVER committed: it prints to stdout (or
writes to `--out`, outside the checkout), because a proof belongs to one run on one build,
not to the repository.

The CI runs the check: the pinned test `test/scripts/bp_doc_test.exs` runs the tool on the real
checkout in the backend gate, and the unit tests of the tool do the same.

The areas are the `docs/bp/<area>.json` files; the support files of the folder
(`public-routes.json`, `dead-code*.json`) are not areas -- the one list of them lives in
`scripts/uat/check_catalog.py` and is read from there.

Standard library only. `--root DIR` points at another checkout (the tests build small fake
ones).
"""
from __future__ import annotations

import argparse
import difflib
import importlib.util
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_ROOT = HERE.parents[1]

BP_DIR = "docs/bp"
SCENARIO_DIR = "test/uat/processes"
STATUSES = ("implemented", "partial", "planned")


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


# The one list of the support files that are not area catalogs (docs/bp/README.md).
_CATALOG = _load("check_catalog", HERE.parent / "uat" / "check_catalog.py")
NON_AREA_FILES = _CATALOG.NON_AREA_FILES


class BpDocError(Exception):
    """A problem with the map or with the checkout; the message is shown to the user."""


# ---------------------------------------------------------------------------- the sources of the render


def area_files(root: Path) -> list[Path]:
    """The map files of the checkout, sorted by name."""
    directory = root / BP_DIR
    if not directory.is_dir():
        return []
    return sorted(p for p in directory.glob("*.json") if p.name not in NON_AREA_FILES)


def area_names(root: Path) -> list[str]:
    return [p.stem for p in area_files(root)]


def load_map(root: Path, area: str) -> list[dict]:
    """The processes of one area (the JSON list of the map file)."""
    path = root / BP_DIR / f"{area}.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise BpDocError(f"{path}: invalid JSON: {exc}") from exc
    if not isinstance(data, list):
        raise BpDocError(f"{path}: the file must be a JSON list of entries")
    return [e for e in data if isinstance(e, dict)]


def scenario_index(root: Path) -> dict[str, list[tuple[str, str]]]:
    """{bp_entry: [(path of the runner scenario, runner id)]} from test/uat/processes/*.json."""
    index: dict[str, list[tuple[str, str]]] = {}
    directory = root / SCENARIO_DIR
    if not directory.is_dir():
        return index
    for path in sorted(directory.glob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue
        if not isinstance(data, dict):
            continue
        entry = data.get("bp_entry")
        if not isinstance(entry, str) or not entry:
            continue
        runner_id = data.get("id")
        rel = path.relative_to(root).as_posix()
        index.setdefault(entry, []).append((rel, str(runner_id) if runner_id else path.stem))
    return index


def orphan_table(root: Path, area: str) -> tuple[list[str], list[list[str]]]:
    """The header cells and the rows of the Markdown table of docs/bp/orphans-<area>.md."""
    path = root / BP_DIR / f"orphans-{area}.md"
    if not path.is_file():
        return [], []
    header: list[str] = []
    rows: list[list[str]] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if set("".join(cells)) <= set("-: "):
            continue  # the separator row under the header
        if not header:
            header = cells
        else:
            rows.append(cells)
    return header, rows


# ------------------------------------------------------------------------------------- the proof (runner report)

VERDICT_ROW = re.compile(r"^\|(?P<cells>[^|]*\|[^|]*\|[^|]*\|[^|]*)\|\s*$")
DATE_PREFIX = re.compile(r"^(\d{4}-\d{2}-\d{2})")
SECURITY_TITLE = re.compile(r"(?i)(^security\b|\(security\)\s*$)")


def proof_index(directory: Path) -> dict[str, dict]:
    """{runner process id: {sha, result, when, file}} from the verdict files of a runner report.

    The files are read in sorted order and every table row `| process | build sha | result |
    when |` is a proof of that process. The latest proof wins: the `when` column first (the
    runner writes an ISO timestamp), the file order as the tiebreak.
    """
    proofs: dict[str, dict] = {}
    if not directory.is_dir():
        return proofs
    candidates: dict[str, list[tuple[str, str, int, str, str]]] = {}
    for path in sorted(directory.rglob("*.md")):
        rel = path.relative_to(directory).as_posix()
        text = path.read_text(encoding="utf-8", errors="replace")
        for number, line in enumerate(text.splitlines()):
            match = VERDICT_ROW.match(line.strip())
            if not match:
                continue
            cells = [c.strip() for c in match.group("cells").split("|")]
            if len(cells) != 4:
                continue
            pid, sha, result, when = cells
            if not pid or pid.lower() in ("process", "---"):
                continue
            candidates.setdefault(pid, []).append((when, rel, number, sha, result))
    for pid, rows in candidates.items():
        when, rel, _number, sha, result = max(rows)
        proofs[pid] = {"sha": sha, "result": result, "when": when, "file": rel}
    return proofs


# -------------------------------------------------------------------------------------------- the small texts


def flat(text: object) -> str:
    """One line: no newline, no run of spaces."""
    return " ".join(str(text if text is not None else "").split())


def cell(text: object) -> str:
    """A Markdown table cell: one line, the pipe escaped."""
    return flat(text).replace("|", "\\|")


def one_line(text: object, limit: int = 140) -> str:
    """The one line of a description: its first sentence, or its first two when the first
    one is only a lead-in ("Negative process (D-170)."), cut to `limit` characters.

    A sentence ends at a full stop followed by a space, so a version number ("0.1.0") or a
    module name ("Letflow.Plugs.AuthPipeline") does not cut the line.
    """
    sentence = flat(text)
    parts = [p.strip() for p in re.split(r"(?<=[.!?])\s+", sentence) if p.strip()]
    if not parts:
        return ""
    line = parts[0]
    if len(line) < 45 and len(parts) > 1:
        line = f"{line} {parts[1]}"
    if len(line) > limit:
        line = line[: limit - 3].rstrip() + "..."
    return line


def date_of(when: object) -> str:
    """The date of a runner timestamp (the day, not the clock)."""
    text = flat(when)
    match = DATE_PREFIX.match(text)
    return match.group(1) if match else text


def list_of(entry: dict, key: str) -> list[str]:
    value = entry.get(key)
    if isinstance(value, list):
        return [flat(v) for v in value if isinstance(v, (str, int, float))]
    return []


def executed_by_of(entry: dict) -> str:
    """Who runs the process: `direct` (a hard-coded route or function) or `definition:<key>`.

    The field is optional: a missing one means `direct` (D-175 -- the existing entries are
    direct until they are migrated). The value comes from the catalog's own reader, so the
    document and the validator agree on what a missing field means.
    """
    value, _kind, _problem = _CATALOG.parse_executed_by(entry)
    return value if isinstance(value, str) and value else "direct"


def executed_by_counts(entries: list[dict]) -> dict[str, int]:
    """How many processes of the area are `direct` and how many are `definition:`."""
    return _CATALOG.executed_by_counts(entries)


# ------------------------------------------------------------------------------------------- the render


def actors_of(entry: dict) -> list[tuple[str, str]]:
    """The actors of a process with their permission, in the order of the map."""
    out: list[tuple[str, str]] = []
    for actor in entry.get("actors") or []:
        if not isinstance(actor, dict):
            continue
        role = flat(actor.get("role"))
        permission = flat(actor.get("permission"))
        if role and (role, permission) not in out:
            out.append((role, permission))
    return out


def test_paths(entry: dict) -> list[str]:
    """The tests of a process: the `tests`/`existing_tests` lists and the test code_refs."""
    out: set[str] = set()
    for key in ("tests", "existing_tests"):
        for value in list_of(entry, key):
            if value:
                out.add(value.split(":")[0])
    for task in entry.get("tasks") or []:
        if not isinstance(task, dict):
            continue
        for ref in task.get("code_refs") or []:
            if isinstance(ref, str) and ref.startswith("test/"):
                out.add(ref.split(":")[0])
    return sorted(out)


def is_security(entry: dict) -> bool:
    """Is the process a security (negative) process?

    The map says so in three ways and the tool reads all three, because the map does not use
    them everywhere: the `security` field (`true`), the `kind` field (`security`) and the
    wording of the process itself (a title that starts with "Security" or ends with
    "(security)", a description that calls it a "negative process").
    """
    if entry.get("security") is True:
        return True
    if flat(entry.get("kind")) == "security":
        return True
    if SECURITY_TITLE.search(flat(entry.get("title"))):
        return True
    return "negative process" in flat(entry.get("description")).lower()


def step_lines(task: dict) -> list[str]:
    """One step of a process: who, the screen, the call, the functions, the result."""
    if not isinstance(task, dict):
        return []
    who = flat(task.get("actor")) or "?"
    details: list[str] = []
    forms = [flat(f) for f in task.get("forms") or [] if isinstance(f, str)]
    if forms:
        details.append("screen " + ", ".join(f"`{f}`" for f in forms))
    route = task.get("route")
    routes = route if isinstance(route, list) else [route]
    routes = [flat(r) for r in routes if isinstance(r, str) and flat(r)]
    if routes:
        details.append("call " + ", ".join(f"`{r}`" for r in routes))
    functions = [flat(f) for f in task.get("functions") or [] if isinstance(f, str)]
    if functions:
        details.append("function " + ", ".join(f"`{f}`" for f in functions))
    line = f"**{who}**"
    line += (": " + ", ".join(details)) if details else "."
    result = flat(task.get("result"))
    if result:
        line += f"\n   Result: {result}"
    return [line]


def status_lines(entry: dict, has_scenario: bool) -> list[str]:
    """The implementation, UAT, security and automation status of a process."""
    out: list[str] = []
    status = flat(entry.get("status")) or "unknown"
    implementation = f"implementation: `{status}`"
    requirement = flat(entry.get("requirement"))
    if requirement:
        implementation += f" (requirement: {requirement})"
    out.append(implementation)
    uat = flat(entry.get("uat"))
    if uat:
        out.append(f"UAT: {uat}")
    elif has_scenario:
        out.append("UAT: scripted -- the runner scenario above runs this process.")
    else:
        out.append("UAT: planned -- no runner scenario yet.")
    line = f"security: {'yes' if is_security(entry) else 'no'}"
    security_status = flat(entry.get("security_status"))
    if security_status:
        line += f" ({security_status})"
    out.append(line)
    automation = flat(entry.get("automation"))
    if automation:
        out.append(f"automation: {automation}")
    return out


def gap_lines(entry: dict) -> list[str]:
    """What the map says is missing for this process."""
    out: list[str] = []
    gap = flat(entry.get("gap"))
    if gap:
        out.append(gap)
    for case in list_of(entry, "planned_cases"):
        if case:
            out.append(case)
    note = flat(entry.get("note"))
    if note:
        out.append(note)
    planned_scenario = flat(entry.get("planned_scenario"))
    if planned_scenario:
        out.append(f"planned scenario: {planned_scenario}")
    refines = flat(entry.get("refines"))
    if refines:
        out.append(f"refines {refines}")
    code_refs_note = flat(entry.get("code_refs_note"))
    if code_refs_note:
        out.append(code_refs_note)
    return out


def machine_proven(entry: dict, scenarios: list[tuple[str, str]], proofs: dict | None) -> str:
    """The Machine-proven cell: the proof of the runner, or where to look for it."""
    if proofs is None:
        return "see report"
    best: dict | None = None
    for _rel, runner_id in scenarios:
        proof = proofs.get(runner_id)
        if proof is None:
            continue
        if best is None or (proof["when"], proof["file"]) > (best["when"], best["file"]):
            best = proof
    if best is None:
        return "not in report"
    return f"{best['result']} on {best['sha']} {date_of(best['when'])}"


def render_area(
    root: Path,
    area: str,
    entries: list[dict],
    scenarios: dict[str, list[tuple[str, str]]],
    proofs: dict | None = None,
) -> str:
    """The whole document of one area."""
    processes = sorted(entries, key=lambda e: flat(e.get("id")))
    lines: list[str] = []
    lines.append(f"# Business processes: {area}")
    lines.append("")
    lines.append(
        "<!-- Generated by scripts/bp/bp_doc.py from "
        f"{BP_DIR}/{area}.json (D-173). Do not edit this file: run\n"
        f"     `python3 scripts/bp/bp_doc.py {area}` after changing the map.\n"
        "     The gate `python3 scripts/bp/bp_doc.py --check` fails when this file\n"
        "     differs from the render. -->"
    )
    lines.append("")

    counts = {status: 0 for status in STATUSES}
    for entry in processes:
        status = flat(entry.get("status"))
        if status in counts:
            counts[status] += 1
    summary = ", ".join(f"{counts[status]} {status}" for status in STATUSES if counts[status])
    by = executed_by_counts(processes)
    lines.append(
        f"The area `{area}` has {len(processes)} process(es): {summary or 'no status yet'}. "
        f"Executed by: {by['direct']} direct, {by['definition']} definition"
        + (f", {by['n/a']} n/a." if by["n/a"] else ".")
    )
    lines.append("")
    lines.append("## The processes of the area")
    lines.append("")
    lines.append(
        "| id | name | in one line | actors | status | executed by | scenario | security | machine-proven |"
    )
    lines.append("|---|---|---|---|---|---|---|---|---|")
    for entry in processes:
        pid = flat(entry.get("id"))
        scenario_files = scenarios.get(pid, [])
        has_scenario = bool(scenario_files) or bool(flat(entry.get("scenario")))
        actors = ", ".join(dict.fromkeys(role for role, _permission in actors_of(entry)))
        lines.append(
            "| "
            + " | ".join(
                [
                    cell(pid),
                    cell(entry.get("title")),
                    cell(one_line(entry.get("description"))),
                    cell(actors),
                    cell(entry.get("status")),
                    cell(executed_by_of(entry)),
                    "yes" if has_scenario else "no",
                    "yes" if is_security(entry) else "no",
                    cell(machine_proven(entry, scenario_files, proofs)),
                ]
            )
            + " |"
        )
    lines.append("")

    for entry in processes:
        pid = flat(entry.get("id"))
        title = flat(entry.get("title"))
        lines.append(f"## {pid} -- {title}")
        lines.append("")
        description = flat(entry.get("description"))
        if description:
            lines.append(description)
            lines.append("")
        actors = actors_of(entry)
        if actors:
            lines.append("**Actors and their permissions.**")
            lines.append("")
            for role, permission in actors:
                lines.append(f"- `{role}` -- {permission or 'no permission'}")
            lines.append("")
        steps: list[str] = []
        for task in entry.get("tasks") or []:
            steps.extend(step_lines(task))
        if steps:
            lines.append("**Steps.**")
            lines.append("")
            for number, step in enumerate(steps, start=1):
                lines.append(f"{number}. {step}")
            lines.append("")
        refusals = list_of(entry, "refusals")
        if refusals:
            lines.append("**Refusals.**")
            lines.append("")
            for refusal in refusals:
                lines.append(f"- {refusal}")
            lines.append("")
        tests = test_paths(entry)
        if tests:
            lines.append("**Tests.**")
            lines.append("")
            for path in tests:
                lines.append(f"- `{path}`")
            lines.append("")
        scenario_files = scenarios.get(pid, [])
        lines.append("**Runner scenario.**")
        lines.append("")
        if scenario_files:
            for rel, runner_id in scenario_files:
                lines.append(f"- `{rel}` (runner id `{runner_id}`)")
        else:
            lines.append("- none yet")
        named = flat(entry.get("scenario"))
        if named and named not in [rel for rel, _ in scenario_files]:
            lines.append(f"- the map names `{named}`")
        lines.append("")
        lines.append("**Status.**")
        lines.append("")
        for line in status_lines(entry, bool(scenario_files) or bool(named)):
            lines.append(f"- {line}")
        lines.append("")
        gaps = gap_lines(entry)
        if gaps:
            lines.append("**Gaps.**")
            lines.append("")
            for gap in gaps:
                lines.append(f"- {gap}")
            lines.append("")

    header, rows = orphan_table(root, area)
    lines.append(f"## Orphans ({BP_DIR}/orphans-{area}.md)")
    lines.append("")
    if header and rows:
        lines.append("| " + " | ".join(cell(h) for h in header) + " |")
        lines.append("|" + "|".join("---" for _ in header) + "|")
        for row in rows:
            padded = list(row) + [""] * (len(header) - len(row))
            lines.append("| " + " | ".join(cell(c) for c in padded[: len(header)]) + " |")
    elif header:
        lines.append(
            f"The orphan file of the area lists no orphan row (the file itself explains why: "
            f"`{BP_DIR}/orphans-{area}.md`)."
        )
    else:
        lines.append(f"This area has no orphan file (`{BP_DIR}/orphans-{area}.md` does not exist).")
    lines.append("")

    without_scenario = [
        flat(e.get("id"))
        for e in processes
        if not scenarios.get(flat(e.get("id"))) and not flat(e.get("scenario"))
    ]
    not_implemented = [
        flat(e.get("id")) for e in processes if flat(e.get("status")) != "implemented"
    ]
    lines.append("## Gaps of the area")
    lines.append("")
    if without_scenario:
        lines.append(
            f"- {len(without_scenario)} process(es) have no runner scenario: "
            + ", ".join(without_scenario)
        )
    if not_implemented:
        lines.append(
            f"- {len(not_implemented)} process(es) are not implemented: "
            + ", ".join(not_implemented)
        )
    if not without_scenario and not not_implemented:
        lines.append("- none: every process is implemented and has a runner scenario.")
    lines.append("")

    return "\n".join(lines).rstrip("\n") + "\n"


# ----------------------------------------------------------------------------------------------- the command


def select_areas(root: Path, asked: str | None) -> list[str]:
    """The areas to work on: the named one, `all`, or (for --check) every area."""
    names = area_names(root)
    if asked is None:
        return names
    if asked == "all":
        return names
    if asked not in names:
        raise BpDocError(
            f"unknown area {asked}; the areas are: " + (", ".join(names) or "none")
        )
    return [asked]


def write_text(path: Path, text: str) -> None:
    """Write a document with LF endings (the checkout may be CRLF, the document is not)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


def check_areas(root: Path, areas: list[str], scenarios: dict) -> tuple[bool, list[str]]:
    """Compare the committed documents with the render; the differences are the report."""
    ok = True
    report: list[str] = []
    for area in areas:
        entries = load_map(root, area)
        rendered = render_area(root, area, entries, scenarios, None)
        path = root / BP_DIR / f"{area}.md"
        if not path.is_file():
            ok = False
            report.append(f"ERROR {BP_DIR}/{area}.md: missing (the map {BP_DIR}/{area}.json has no document)")
            continue
        committed = path.read_text(encoding="utf-8")
        if committed == rendered:
            continue
        ok = False
        report.append(f"ERROR {BP_DIR}/{area}.md: differs from the render of {BP_DIR}/{area}.json")
        diff = difflib.unified_diff(
            committed.splitlines(),
            rendered.splitlines(),
            fromfile=f"{BP_DIR}/{area}.md (committed)",
            tofile=f"{BP_DIR}/{area}.md (render)",
            lineterm="",
        )
        report.extend(diff)
    return ok, report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("area", nargs="?", help="an area of docs/bp/ or `all`")
    parser.add_argument("--root", default=str(DEFAULT_ROOT), help="the product checkout")
    parser.add_argument("--check", action="store_true", help="fail when a committed .md differs from the render")
    parser.add_argument("--proof", help="a directory of runner verdict files (the proof mode, never committed)")
    parser.add_argument("--out", help="write the proof render here (outside the checkout)")
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()

    if args.check and args.proof:
        print("bp_doc: --check compares the committed document with the static render; "
              "the proof mode is never committed", file=sys.stderr)
        return 2

    try:
        if args.check:
            areas = select_areas(root, args.area)
            if not areas:
                print(f"bp_doc: no map files under {BP_DIR}/", file=sys.stderr)
                return 1
            ok, report = check_areas(root, areas, scenario_index(root))
            for line in report:
                print(line)
            print("bp_doc --check: " + ("PASS" if ok else "FAIL"))
            return 0 if ok else 1

        if args.area is None:
            print("usage: bp_doc.py <area|all> | bp_doc.py --check [area|all]", file=sys.stderr)
            return 2

        areas = select_areas(root, args.area)
        if not areas:
            print(f"bp_doc: no map files under {BP_DIR}/", file=sys.stderr)
            return 1
        scenarios = scenario_index(root)
        proofs = None
        if args.proof:
            proofs = proof_index(Path(args.proof).resolve())

        for area in areas:
            entries = load_map(root, area)
            rendered = render_area(root, area, entries, scenarios, proofs)
            if args.proof:
                if args.out:
                    out = Path(args.out).resolve()
                    if out.is_relative_to(root):
                        print("bp_doc: the proof render is never written into the checkout", file=sys.stderr)
                        return 2
                    write_text(out, rendered)
                    print(f"bp_doc: proof render written to {out}")
                else:
                    sys.stdout.write(rendered)
                continue
            path = root / BP_DIR / f"{area}.md"
            write_text(path, rendered)
            print(f"bp_doc: wrote {BP_DIR}/{area}.md")
        return 0
    except BpDocError as exc:
        print(f"bp_doc: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
