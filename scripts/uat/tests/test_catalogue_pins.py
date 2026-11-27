"""No UAT scenario pins a name-sorted catalogue by position (T-3139).

A catalogue the scenarios read (`GET /api/v1/platform-functions`, `GET /api/v1/notification-templates/catalogue`) is
sorted by name and grows by insertion, so `$.items[12].name` goes stale when a sibling adds an entry (merge #5169:
BP-PLATFORM-01 and BP-PLATFORM-02). A scenario asserts the entry by NAME through the runner's lookup
(`$.items[?name=x]`, `runner.json_path`, T-3105). This test fails when a scenario pins a catalogue by index, and when a
by-name pin names an entry that the product source does not define (a rename or a typo).

Run: python3 -B -m unittest -v scripts/uat/tests/test_catalogue_pins.py   (from the repository root)
"""

import json
import re
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import runner  # noqa: E402

ROOT = HERE.parents[2]
UAT_TREE = ROOT / "test" / "uat"
CATALOGUES = ("/api/v1/platform-functions", "/api/v1/notification-templates/catalogue")
POSITIONAL = re.compile(r"\$\.items\[\d+\]")
BY_NAME = re.compile(r"\$\.items\[\?(name|template_key)=([^\]&]+)\]")


def catalogue_pins():
    """(file name, step id, path key, expected) of every json expectation of a step that reads a catalogue."""
    for file in sorted(UAT_TREE.rglob("*.json")):
        try:
            doc = json.loads(file.read_text())
        except ValueError:
            continue
        steps = doc.get("steps") if isinstance(doc, dict) else None
        for step in steps if isinstance(steps, list) else []:
            if not isinstance(step, dict):
                continue
            path = (step.get("do") or {}).get("path") or ""
            if path.split("?")[0] not in CATALOGUES:
                continue
            for key, want in (((step.get("expect") or {}).get("json")) or {}).items():
                yield file.name, step.get("id"), key, want


class CataloguePins(unittest.TestCase):
    def test_no_scenario_pins_a_catalogue_by_position(self):
        stale = [f"{f} step {s}: {k}" for f, s, k, _ in catalogue_pins() if POSITIONAL.match(k)]
        self.assertEqual(stale, [], "pin the entry by name: $.items[?name=x]")

    def test_pinned_names_exist_in_the_product(self):
        source = "\n".join(p.read_text() for p in (ROOT / "lib" / "letflow").rglob("*.ex"))
        missing = []
        for f, s, k, _ in catalogue_pins():
            m = BY_NAME.match(k)
            if m:
                value = m.group(2)
                if f'"{value}"' not in source and f":{value}" not in source:
                    missing.append(f"{f} step {s}: {value}")
        self.assertEqual(missing, [])

    def test_the_guard_sees_the_pilot_pins(self):
        names = {(f, s) for f, s, _, _ in catalogue_pins()}
        self.assertIn(("BP-PLATFORM-01-register-tenant.json", "A3a"), names)
        self.assertIn(("BP-PLATFORM-02-tenant-lifecycle-process.json", "A2"), names)

    def test_a_positional_pin_is_caught_and_a_lookup_survives_growth(self):
        self.assertTrue(POSITIONAL.match("$.items[12].name"))
        self.assertFalse(POSITIONAL.match("$.items[?name=tenant.validate]"))
        grown = {"items": [{"name": "a"}, {"name": "new"}, {"name": "tenant.validate"}]}
        self.assertEqual(runner.json_path(grown, "$.items[?name=tenant.validate].name"),
                         (True, "tenant.validate"))


if __name__ == "__main__":
    unittest.main()
