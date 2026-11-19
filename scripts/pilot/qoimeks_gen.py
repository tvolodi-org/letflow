#!/usr/bin/env python3
"""qoimeks_gen.py -- deterministic synthetic dataset for the qoimeks-qa rehearsal. T-2047.

Writes locations.csv, items.csv and balances.csv in the format qoimeks_convert.py reads.
All data is entirely fictitious; no real Qoimeks client information is included (D-050).

  python3 -I scripts/pilot/qoimeks_gen.py --out DIR [--seed N] [--with-places] [--voice-demo]

Sizes (default): 666 SKUs (unit pcs, quantities up to 3 decimal places), 134 rack locations
plus 8 hierarchy nodes (1 warehouse, 7 zones), 600 positive balance rows, 3 negative opening rows,
3 zero rows skipped by the converter and 4 comma-decimal rows it drops, to exercise the G4 and G8
rules. A few item names embed Cyrillic look-alike letters to test Unicode handling.

--with-places (off by default; the default output stays byte-identical to the original) adds
home_loc and alt_loc columns to items.csv (a usual and a second place for a share of the items)
and gives a set of items a lettered article code (Latin and Cyrillic letters, as the voice
scenarios spell them). It uses its own random stream, so locations.csv is identical and the
balances differ only in the sku value of the lettered items.

--voice-demo (off by default; the default output stays byte-identical) appends a small fixed
demo catalog for the voice scenarios: 12 items with lettered codes (BLT-M8-40, NUT-M8, CBL-3x2.5,
GLV-L ...) with Russian names and the units kg, m and pair, and 8 places (A-01, A-02, A-03, B-01,
B-02, C-01, RAMP and the zone-coded place LA3 named "Слева A 3") under the warehouse root. C-02 and
D-03 are left out on purpose, so a scenario can name a place that does not exist. The usual places
are PNT-WH-10 -> C-01 and GLV-L -> A-01. items.csv then also carries home_loc/alt_loc (empty for
the generated items). No balances are added. It does not touch the random streams and combines
with --with-places. The data is synthetic; the item list is the Qoimeks demo catalog, no customer data.
"""

import argparse
import csv
import random
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

DEFAULT_SEED = 42
N_SKUS = 666
N_ZONES = 7
N_LOCS_ZONE_A = 20   # first zone: 20 rack locations
N_LOCS_OTHER = 19    # zones B-G: 19 rack locations each — total 20 + 6*19 = 134 leaves
N_VALID_BALANCES = 600
N_DOUBLE_PLACE = 60  # items with 2 balance rows (at 2 different locations)
# single-place items = N_VALID_BALANCES - 2*N_DOUBLE_PLACE = 480
# items with no balance = N_SKUS - 480 - 60 = 126; first 10 provide bad balance rows

N_ZERO_ROWS = 3     # G4: quantity_zero, skipped (qty == 0)
N_NEG_ROWS = 3      # G4: negative opening lines (qty < 0)
N_COMMA_ROWS = 4    # G8: quantity_comma_decimal

ZONE_LETTERS = list("ABCDEFG")

# Cyrillic letters that visually match common Latin letters (Unicode look-alikes)
CYRILLIC_LOOKALIKES = [
    "\u0410",  # А looks like A
    "\u0421",  # С looks like C
    "\u041E",  # О looks like O
    "\u0415",  # Е looks like E
    "\u0420",  # Р looks like P
    "\u0425",  # Х looks like X
]

# --with-places
N_HOME_EVERY = 3      # every 3rd item has a usual place (home_loc)
N_ALT_EVERY = 9       # every 9th item also has a second place (alt_loc)
LETTER_EVERY = 25     # every 25th item gets a lettered article code
LATIN_PREFIXES = ["AB", "KS", "MT", "DR", "PL", "VK"]
CYRILLIC_PREFIXES = ["\u0410\u0411", "\u041a\u0421", "\u041c\u0422", "\u0414\u0420", "\u041f\u041b", "\u0412\u041a"]

# --voice-demo: (sku, name, unit, usual place)
VOICE_ITEMS = [
    ("BLT-M8-40", "Болт М8х40", "шт", ""),
    ("BLT-M10-60", "Болт М10х60", "шт", ""),
    ("NUT-M8", "Гайка М8", "шт", ""),
    ("NUT-M10", "Гайка М10", "шт", ""),
    ("WSH-8", "Шайба плоская 8", "шт", ""),
    ("SCR-4-40", "Саморез 4х40", "кг", ""),
    ("PNT-WH-10", "Краска белая 10", "шт", "C-01"),
    ("PNT-GR-3", "Краска серая 3", "шт", ""),
    ("CBL-3x2.5", "Кабель 3х2.5", "м", ""),
    ("CBL-3x1.5", "Кабель 3х1.5", "м", ""),
    ("GLV-L", "Перчатки L", "пар", "A-01"),
    ("TAPE-48", "Скотч 48", "шт", ""),
]
# C-02 and D-03 are absent on purpose
VOICE_PLACES = [
    ("A-01", "Место A-01"), ("A-02", "Место A-02"), ("A-03", "Место A-03"),
    ("B-01", "Место B-01"), ("B-02", "Место B-02"), ("C-01", "Место C-01"),
    ("RAMP", "Рампа"), ("LA3", "Слева A 3"),
]

ITEM_TYPES = [
    "БОЛТ", "ГАЙКА", "ПРОВОД", "КРАСКА", "КЛЕЙ", "ЛЕНТА", "ТРУБА", "ПЛИТА",
    "ПАНЕЛЬ", "ДИСК", "КАБЕЛЬ", "ШТИФТ", "ШАЙБА", "ПРУЖИНА", "ВТУЛКА",
    "ФЛАНЕЦ", "МУФТА", "КЛАПАН", "РЫЧАГ", "НАСОС",
]


def fail(msg):
    print("qoimeks_gen: " + msg, file=sys.stderr)
    sys.exit(2)


def check_out(out):
    p = Path(out).resolve()
    if p == REPO_ROOT or REPO_ROOT in p.parents:
        fail("--out is inside the repository checkout; choose a directory outside it")
    return p


def gen_locations():
    """Return (all_rows, leaf_codes). Parents always precede children in all_rows."""
    rows = []
    leaf_codes = []

    rows.append({"loc_code": "WH", "loc_name": "Склад", "loc_parent": ""})

    zone_counts = [N_LOCS_ZONE_A] + [N_LOCS_OTHER] * (N_ZONES - 1)
    for letter, count in zip(ZONE_LETTERS, zone_counts):
        zone_code = "Z" + letter
        rows.append({"loc_code": zone_code, "loc_name": "Зона " + letter, "loc_parent": "WH"})

        for n in range(1, count + 1):
            code = "R" + letter + str(n)
            rows.append({
                "loc_code": code,
                "loc_name": "Справа " + letter + " " + str(n),
                "loc_parent": zone_code,
            })
            leaf_codes.append(code)

    return rows, leaf_codes


def gen_items(rng):
    """Return rows for items.csv; every 100th item gets a Cyrillic look-alike in its name."""
    rows = []
    for i in range(1, N_SKUS + 1):
        type_name = ITEM_TYPES[(i - 1) % len(ITEM_TYPES)]
        name = type_name + "-" + str(i).zfill(4)
        # Items 100, 200, ..., 600: append one Cyrillic look-alike character to exercise
        # Unicode handling in downstream systems (the converter passes names through as-is)
        if i % 100 == 0:
            la = CYRILLIC_LOOKALIKES[(i // 100 - 1) % len(CYRILLIC_LOOKALIKES)]
            name = name + la
        rows.append({"sku": str(i).zfill(4), "sku_name": name, "unit": "pcs"})
    return rows


def apply_places(item_rows, leaf_codes, seed):
    """Add home_loc/alt_loc and lettered codes in place. Own rng: other streams are untouched."""
    prng = random.Random("places-%s" % seed)
    n_letter = 0
    for i, row in enumerate(item_rows, start=1):
        home = ""
        alt = ""
        if i % N_HOME_EVERY == 0:
            home = prng.choice(leaf_codes)
            if i % N_ALT_EVERY == 0:
                alt = prng.choice([c for c in leaf_codes if c != home])
        row["home_loc"] = home
        row["alt_loc"] = alt
        if i % LETTER_EVERY == 0:
            # alternate Latin and Cyrillic prefixes; digits keep the code unique
            prefixes = LATIN_PREFIXES if n_letter % 2 == 0 else CYRILLIC_PREFIXES
            row["sku"] = prefixes[(n_letter // 2) % len(prefixes)] + str(i).zfill(4)
            n_letter += 1
    return item_rows


def apply_voice_demo(loc_rows, leaf_codes, item_rows):
    """Append the voice demo places and items in place (parents precede children)."""
    taken = {r["loc_code"] for r in loc_rows}
    for code, name in VOICE_PLACES:
        assert code not in taken, code
        loc_rows.append({"loc_code": code, "loc_name": name, "loc_parent": "WH"})
        leaf_codes.append(code)
    taken = {r["sku"] for r in item_rows}
    for sku, name, unit, home in VOICE_ITEMS:
        assert sku not in taken, sku
        item_rows.append({"sku": sku, "sku_name": name, "unit": unit,
                          "home_loc": home, "alt_loc": ""})


def gen_qty(rng, decimals):
    """Generate a positive quantity string with 0, 1, 2 or 3 decimal places."""
    if decimals == 0:
        return str(rng.randint(1, 999))
    integer_part = rng.randint(1, 200)
    limit = 10 ** decimals
    frac_part = rng.randint(1, limit - 1)
    frac_str = str(frac_part).zfill(decimals).rstrip("0")
    return str(integer_part) + "." + (frac_str or "1")


def gen_balances(item_codes, leaf_codes, rng):
    """Return rows for balances.csv: positive, negative, zero and comma-decimal cases."""
    n_single = N_VALID_BALANCES - 2 * N_DOUBLE_PLACE  # 480

    items_pool = list(item_codes)
    rng.shuffle(items_pool)

    single_items = items_pool[:n_single]                          # 480 items × 1 balance
    double_items = items_pool[n_single:n_single + N_DOUBLE_PLACE] # 60 items × 2 balances
    spare_items  = items_pool[n_single + N_DOUBLE_PLACE:]         # 126 spare items

    used_pairs = set()
    good_rows = []

    # Distribute decimal depths evenly across valid balance rows
    depths = [0, 1, 2, 3] * (N_VALID_BALANCES // 4 + 1)
    rng.shuffle(depths)
    depth_idx = 0

    def pick_loc(sku, exclude=None):
        """Pick a leaf location not yet used for this SKU (and not equal to exclude)."""
        while True:
            loc = rng.choice(leaf_codes)
            if (sku, loc) not in used_pairs and loc != exclude:
                return loc

    for sku in single_items:
        loc = pick_loc(sku)
        used_pairs.add((sku, loc))
        qty = gen_qty(rng, depths[depth_idx % len(depths)])
        depth_idx += 1
        good_rows.append({"sku": sku, "loc": loc, "qty": qty})

    for sku in double_items:
        loc1 = pick_loc(sku)
        used_pairs.add((sku, loc1))
        qty1 = gen_qty(rng, depths[depth_idx % len(depths)])
        depth_idx += 1
        good_rows.append({"sku": sku, "loc": loc1, "qty": qty1})

        loc2 = pick_loc(sku, exclude=loc1)
        used_pairs.add((sku, loc2))
        qty2 = gen_qty(rng, depths[depth_idx % len(depths)])
        depth_idx += 1
        good_rows.append({"sku": sku, "loc": loc2, "qty": qty2})

    rng.shuffle(good_rows)

    # Build 10 bad rows using spare SKUs (valid SKU + valid location, bad quantity only)
    bad_rows = []
    spare_idx = 0

    for _ in range(N_ZERO_ROWS):
        sku = spare_items[spare_idx]; spare_idx += 1
        bad_rows.append({"sku": sku, "loc": rng.choice(leaf_codes), "qty": "0"})

    for _ in range(N_NEG_ROWS):
        sku = spare_items[spare_idx]; spare_idx += 1
        bad_rows.append({"sku": sku, "loc": rng.choice(leaf_codes), "qty": str(-rng.randint(1, 50))})

    for _ in range(N_COMMA_ROWS):
        sku = spare_items[spare_idx]; spare_idx += 1
        a = rng.randint(1, 99)
        b = rng.randint(10, 99)
        bad_rows.append({"sku": sku, "loc": rng.choice(leaf_codes), "qty": str(a) + "," + str(b)})

    # Interleave bad rows at random positions among the good rows
    all_rows = list(good_rows)
    for bad in bad_rows:
        pos = rng.randint(0, len(all_rows))
        all_rows.insert(pos, bad)

    return all_rows


def write_csv(path, fieldnames, rows):
    with Path(path).open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        w.writerows(rows)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", required=True)
    ap.add_argument("--seed", type=int, default=DEFAULT_SEED,
                    help="random seed for reproducibility (default: %(default)s)")
    ap.add_argument("--with-places", action="store_true",
                    help="add home_loc/alt_loc and lettered article codes to items.csv")
    ap.add_argument("--voice-demo", action="store_true",
                    help="append the voice demo items and places (separate dataset)")
    a = ap.parse_args(argv)

    out = check_out(a.out)
    out.mkdir(parents=True, exist_ok=True)

    rng = random.Random(a.seed)

    loc_rows, leaf_codes = gen_locations()
    item_rows = gen_items(rng)
    item_codes = [r["sku"] for r in item_rows]
    bal_rows = gen_balances(item_codes, leaf_codes, rng)
    item_fields = ["sku", "sku_name", "unit"]
    if a.with_places:
        # after balances: balances.csv is built from the plain codes, then lettered codes
        # replace some skus in both files so the files stay consistent
        apply_places(item_rows, leaf_codes, a.seed)
        renamed = {old: r["sku"] for old, r in zip(item_codes, item_rows)}
        for b in bal_rows:
            b["sku"] = renamed[b["sku"]]
        item_fields += ["home_loc", "alt_loc"]
    if a.voice_demo:
        # after balances and places: balances only use the generated leaves and items
        n_gen_items = len(item_rows)
        apply_voice_demo(loc_rows, leaf_codes, item_rows)
        for r in item_rows[:n_gen_items]:
            r.setdefault("home_loc", "")
            r.setdefault("alt_loc", "")
        if "home_loc" not in item_fields:
            item_fields += ["home_loc", "alt_loc"]

    write_csv(out / "locations.csv", ["loc_code", "loc_name", "loc_parent"], loc_rows)
    write_csv(out / "items.csv", item_fields, item_rows)
    write_csv(out / "balances.csv", ["sku", "loc", "qty"], bal_rows)

    n_bad = N_ZERO_ROWS + N_NEG_ROWS + N_COMMA_ROWS
    n_leaf = len(leaf_codes)
    n_total_locs = len(loc_rows)

    print(
        "qoimeks_gen: wrote %d locations (%d leaves), %d items, %d balance rows "
        "(%d valid, %d intentionally bad)" % (
            n_total_locs, n_leaf, len(item_rows), len(bal_rows),
            N_VALID_BALANCES, n_bad
        )
    )


if __name__ == "__main__":
    main()
