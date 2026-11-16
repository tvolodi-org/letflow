#!/usr/bin/env python3
"""qoimeks_gen.py -- deterministic synthetic dataset for the qoimeks-qa rehearsal. T-2047.

Writes locations.csv, items.csv and balances.csv in the format qoimeks_convert.py reads.
All data is entirely fictitious; no real Qoimeks client information is included (D-050).

  python3 -I scripts/pilot/qoimeks_gen.py --out DIR [--seed N]

Sizes (default): 666 SKUs (unit pcs, quantities up to 3 decimal places), 134 rack locations
plus 8 hierarchy nodes (1 warehouse, 7 zones), 600 valid balance rows plus 10 intentionally
bad rows (3 zero-quantity, 3 negative, 4 comma-decimal) to exercise the converter's G4 and G8
drop checks. A few item names embed Cyrillic look-alike letters to test Unicode handling.
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

N_ZERO_ROWS = 3     # G4: quantity_not_positive (qty == 0)
N_NEG_ROWS = 3      # G4: quantity_not_positive (qty < 0)
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
    """Return rows for balances.csv: 600 valid rows plus 10 intentionally bad rows."""
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
    a = ap.parse_args(argv)

    out = check_out(a.out)
    out.mkdir(parents=True, exist_ok=True)

    rng = random.Random(a.seed)

    loc_rows, leaf_codes = gen_locations()
    item_rows = gen_items(rng)
    item_codes = [r["sku"] for r in item_rows]
    bal_rows = gen_balances(item_codes, leaf_codes, rng)

    write_csv(out / "locations.csv", ["loc_code", "loc_name", "loc_parent"], loc_rows)
    write_csv(out / "items.csv", ["sku", "sku_name", "unit"], item_rows)
    write_csv(out / "balances.csv", ["sku", "loc", "qty"], bal_rows)

    n_bad = N_ZERO_ROWS + N_NEG_ROWS + N_COMMA_ROWS
    n_leaf = N_LOCS_ZONE_A + N_LOCS_OTHER * (N_ZONES - 1)
    n_total_locs = 1 + N_ZONES + n_leaf

    print(
        "qoimeks_gen: wrote %d locations (%d leaves), %d items, %d balance rows "
        "(%d valid, %d intentionally bad)" % (
            n_total_locs, n_leaf, len(item_rows), len(bal_rows),
            N_VALID_BALANCES, n_bad
        )
    )


if __name__ == "__main__":
    main()
