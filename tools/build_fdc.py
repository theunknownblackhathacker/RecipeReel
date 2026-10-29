#!/usr/bin/env python3
"""Builds fdc.sqlite (bundled, read-only) from USDA FoodData Central CSV downloads.

Data: Foundation Foods (latest) + SR Legacy (2018, final). Public domain (CC0), USDA FoodData Central.

Schema:
  food(fdc_id PK, description, data_type, category)
  macro(fdc_id PK, kcal, kcal_source, protein, fat, carbs, fiber, sugar)   -- per 100 g
  portion(fdc_id, amount, unit_text, grams)                                -- grams for `amount` units
  food_fts  FTS5(description, fdc_id UNINDEXED), porter stemming
  meta(key PK, value)

Usage: python3 tools/build_fdc.py --out App/Resources/fdc.sqlite
Prints GitHub "::notice::" lines with stats and sample values so CI results are readable as annotations.
"""
import argparse
import csv
import io
import os
import re
import sqlite3
import sys
import urllib.request
import zipfile
from datetime import datetime, timezone

PAGE_URL = "https://fdc.nal.usda.gov/download-datasets"
BASE_URL = "https://fdc.nal.usda.gov/fdc-datasets/"
# Used only if the download page can't be parsed. Newest first.
FALLBACK_FOUNDATION = [
    "FoodData_Central_foundation_food_csv_2026-10-29.zip",
    "FoodData_Central_foundation_food_csv_2026-04-30.zip",
    "FoodData_Central_foundation_food_csv_2025-12-18.zip",
]
FALLBACK_SR_LEGACY = ["FoodData_Central_sr_legacy_food_csv_2018-04.zip"]
USER_AGENT = "Mozilla/5.0 (RecipeReel fdc builder; +https://github.com/theunknownblackhathacker/RecipeReel)"

# Nutrient IDs (see nutrition-data-notes.md)
ENERGY_KCAL = 1008
ENERGY_ATWATER_SPECIFIC = 2048
ENERGY_ATWATER_GENERAL = 2047
PROTEIN = 1003
FAT = 1004
CARBS_BY_DIFFERENCE = 1005
CARBS_BY_SUMMATION = 1050
FIBER = 1079
SUGARS_TOTAL = 2000
SUGARS_TOTAL_NLEA = 1063
WANTED = {ENERGY_KCAL, ENERGY_ATWATER_SPECIFIC, ENERGY_ATWATER_GENERAL, PROTEIN, FAT,
          CARBS_BY_DIFFERENCE, CARBS_BY_SUMMATION, FIBER, SUGARS_TOTAL, SUGARS_TOTAL_NLEA}
KEEP_TYPES = {"foundation_food", "sr_legacy_food"}


class DatasetError(Exception):
    pass


def warning(msg):
    print(f"::warning title=fdc::{msg}", flush=True)


def notice(msg):
    print(f"::notice title=fdc::{msg}", flush=True)


def fail(msg):
    print(f"::error title=fdc::{msg}", flush=True)
    sys.exit(1)


def http_get(url):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=300) as resp:
        return resp.read()


def find_zip_names():
    """Returns (foundation_zip_name, sr_legacy_zip_name) from the download page, with fallbacks."""
    foundation, sr = [], []
    try:
        html = http_get(PAGE_URL).decode("utf-8", errors="replace")
        names = set(re.findall(r"FoodData_Central_(?:foundation|sr_legacy)_food_csv_[0-9A-Za-z_\-]+\.zip", html))
        foundation = sorted((n for n in names if "_foundation_" in n), reverse=True)
        sr = sorted((n for n in names if "_sr_legacy_" in n), reverse=True)
        print(f"Download page lists: {sorted(names)}")
    except Exception as exc:  # noqa: BLE001
        print(f"Could not read download page ({exc}); using fallback file names")
    return (foundation or FALLBACK_FOUNDATION), (sr or FALLBACK_SR_LEGACY)


def download_first(names, label):
    for name in names:
        url = BASE_URL + name
        try:
            print(f"Downloading {label}: {url}")
            data = http_get(url)
            return name, zipfile.ZipFile(io.BytesIO(data))
        except Exception as exc:  # noqa: BLE001
            print(f"  failed: {exc}")
    fail(f"Could not download any {label} file from {names}")


def read_csv(zf, filename):
    """Reads a CSV from a zip whose members may sit inside a top-level folder. Returns [] if absent."""
    members = [n for n in zf.namelist() if n == filename or n.endswith("/" + filename)]
    if not members:
        return []
    with zf.open(members[0]) as raw:
        text = io.TextIOWrapper(raw, encoding="utf-8-sig", newline="")
        return list(csv.DictReader(text))


def normalize_type(value):
    """'foundation_food', 'Foundation', 'SR Legacy' → canonical names."""
    v = (value or "").strip().lower().replace(" ", "_")
    if v in ("foundation", "foundation_food", "foundation_foods"):
        return "foundation_food"
    if v in ("sr_legacy", "sr_legacy_food", "sr_legacy_foods"):
        return "sr_legacy_food"
    return v


def to_float(value):
    try:
        if value is None or value == "":
            return None
        return float(value)
    except ValueError:
        return None


def load_dataset(zf, label):
    foods = {}
    categories = {row["id"]: row.get("description", "") for row in read_csv(zf, "food_category.csv")}
    food_rows = read_csv(zf, "food.csv")
    type_counts = {}
    for row in food_rows:
        dt = row.get("data_type") or ""
        type_counts[dt] = type_counts.get(dt, 0) + 1
    print(f"{label}: zip members {[n for n in zf.namelist() if n.endswith('.csv')][:40]}")
    print(f"{label}: food.csv data_type counts {type_counts}")
    for row in food_rows:
        if normalize_type(row.get("data_type")) not in KEEP_TYPES:
            continue
        fid = int(row["fdc_id"])
        foods[fid] = {
            "description": (row.get("description") or "").strip(),
            "data_type": normalize_type(row["data_type"]),
            "category": categories.get(row.get("food_category_id") or "", ""),
        }
    if not foods:
        columns = list(food_rows[0].keys()) if food_rows else []
        members = [n for n in zf.namelist()][:30]
        raise DatasetError(f"{label}: no foods kept. food.csv rows={len(food_rows)} columns={columns} "
                           f"data_types={type_counts} zip members={members}")

    nutrients = {}  # fdc_id -> {nutrient_id: amount}
    for row in read_csv(zf, "food_nutrient.csv"):
        try:
            fid = int(row["fdc_id"])
            nid = int(row["nutrient_id"])
        except (KeyError, ValueError):
            continue
        if fid not in foods or nid not in WANTED:
            continue
        amount = to_float(row.get("amount"))
        if amount is None:
            continue
        nutrients.setdefault(fid, {}).setdefault(nid, amount)

    units = {row["id"]: (row.get("name") or "").strip() for row in read_csv(zf, "measure_unit.csv")}
    portions = []
    for row in read_csv(zf, "food_portion.csv"):
        try:
            fid = int(row["fdc_id"])
        except (KeyError, ValueError):
            continue
        if fid not in foods:
            continue
        grams = to_float(row.get("gram_weight"))
        if not grams or grams <= 0:
            continue
        amount = to_float(row.get("amount")) or 1.0
        unit_name = units.get(row.get("measure_unit_id") or "", "")
        if unit_name.lower() == "undetermined":
            unit_name = ""
        parts = [unit_name, (row.get("portion_description") or "").strip(), (row.get("modifier") or "").strip()]
        unit_text = " ".join(p for p in parts if p and p.lower() != "quantity not specified").strip()
        if not unit_text:
            continue
        portions.append((fid, amount, unit_text, grams))

    print(f"{label}: {len(foods)} foods, {len(nutrients)} with nutrients, {len(portions)} portions")
    return foods, nutrients, portions


def macro_row(fid, n):
    protein = n.get(PROTEIN)
    fat = n.get(FAT)
    carbs = n.get(CARBS_BY_DIFFERENCE, n.get(CARBS_BY_SUMMATION))
    if ENERGY_KCAL in n:
        kcal, source = n[ENERGY_KCAL], "1008"
    elif ENERGY_ATWATER_SPECIFIC in n:
        kcal, source = n[ENERGY_ATWATER_SPECIFIC], "2048"
    elif ENERGY_ATWATER_GENERAL in n:
        kcal, source = n[ENERGY_ATWATER_GENERAL], "2047"
    elif protein is not None and fat is not None and carbs is not None:
        kcal, source = 4 * protein + 9 * fat + 4 * carbs, "estimated"
    else:
        kcal, source = None, "missing"
    return (fid, kcal, source, protein, fat, carbs, n.get(FIBER), n.get(SUGARS_TOTAL, n.get(SUGARS_TOTAL_NLEA)))


def build(out_path):
    foundation_names, sr_names = find_zip_names()
    s_name, s_zip = download_first(sr_names, "SR Legacy")

    all_foods, all_nutrients, all_portions = {}, {}, []
    used = []
    try:
        foods, nutrients, portions = load_dataset(s_zip, "SR Legacy")
    except DatasetError as exc:
        fail(str(exc))
    all_foods.update(foods)
    all_nutrients.update(nutrients)
    all_portions.extend(portions)
    used.append(s_name)

    # Newest Foundation release that has the expected files (a release may ship without food.csv).
    f_name = "skipped"
    for candidate in foundation_names[:4]:
        try:
            name, zf = download_first([candidate], "Foundation Foods")
            foods, nutrients, portions = load_dataset(zf, f"Foundation Foods ({candidate})")
        except (DatasetError, SystemExit) as exc:
            warning(f"Skipping {candidate}: {exc}")
            continue
        # SR Legacy and Foundation use different fdc_ids, so both can be kept.
        all_foods.update(foods)
        all_nutrients.update(nutrients)
        all_portions.extend(portions)
        used.append(name)
        f_name = name
        break

    if os.path.exists(out_path):
        os.remove(out_path)
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    db = sqlite3.connect(out_path)
    try:
        db.execute("CREATE VIRTUAL TABLE fts_probe USING fts5(x)")
        db.execute("DROP TABLE fts_probe")
    except sqlite3.OperationalError as exc:
        fail(f"SQLite on this runner lacks FTS5: {exc}")

    db.executescript("""
        PRAGMA journal_mode = OFF;
        CREATE TABLE food (fdc_id INTEGER PRIMARY KEY, description TEXT NOT NULL, data_type TEXT NOT NULL, category TEXT);
        CREATE TABLE macro (fdc_id INTEGER PRIMARY KEY, kcal REAL, kcal_source TEXT, protein REAL, fat REAL,
                            carbs REAL, fiber REAL, sugar REAL);
        CREATE TABLE portion (fdc_id INTEGER NOT NULL, amount REAL NOT NULL, unit_text TEXT NOT NULL, grams REAL NOT NULL);
        CREATE INDEX portion_fdc ON portion(fdc_id);
        CREATE VIRTUAL TABLE food_fts USING fts5(description, fdc_id UNINDEXED, tokenize = 'porter unicode61');
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
    """)
    kept = [fid for fid in all_foods if fid in all_nutrients]
    db.executemany("INSERT INTO food VALUES (?, ?, ?, ?)",
                   [(fid, all_foods[fid]["description"], all_foods[fid]["data_type"], all_foods[fid]["category"])
                    for fid in kept])
    db.executemany("INSERT INTO macro VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                   [macro_row(fid, all_nutrients[fid]) for fid in kept])
    kept_set = set(kept)
    db.executemany("INSERT INTO portion VALUES (?, ?, ?, ?)", [p for p in all_portions if p[0] in kept_set])
    db.execute("INSERT INTO food_fts (description, fdc_id) SELECT description, fdc_id FROM food")
    built = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    db.executemany("INSERT INTO meta VALUES (?, ?)", [
        ("foundation_file", f_name if f_name in used else "skipped"), ("sr_legacy_file", s_name), ("built_at", built),
        ("source", "USDA FoodData Central (public domain, CC0)"), ("schema_version", "1"),
    ])
    db.commit()
    db.execute("INSERT INTO food_fts(food_fts) VALUES ('optimize')")
    db.commit()
    db.execute("VACUUM")
    db.close()
    return f_name, s_name


def report(out_path):
    db = sqlite3.connect(out_path)
    count = db.execute("SELECT COUNT(*) FROM food").fetchone()[0]
    by_type = dict(db.execute("SELECT data_type, COUNT(*) FROM food GROUP BY data_type").fetchall())
    portions = db.execute("SELECT COUNT(*) FROM portion").fetchone()[0]
    est = db.execute("SELECT COUNT(*) FROM macro WHERE kcal_source = 'estimated'").fetchone()[0]
    missing = db.execute("SELECT COUNT(*) FROM macro WHERE kcal IS NULL").fetchone()[0]
    size_mb = os.path.getsize(out_path) / 1_000_000
    notice(f"{count} foods {by_type}, {portions} portions, kcal estimated {est}, missing {missing}, {size_mb:.1f} MB")
    for name in ("Oil, olive, salad or cooking", "Egg, whole, raw, fresh", "Butter, salted"):
        row = db.execute("""SELECT f.fdc_id, f.description, m.kcal, m.protein, m.fat, m.carbs
                            FROM food f JOIN macro m USING (fdc_id) WHERE f.description = ?""", (name,)).fetchone()
        notice(f"sample {row}")
    hits = db.execute("""SELECT f.description FROM food_fts JOIN food f ON f.fdc_id = food_fts.fdc_id
                         WHERE food_fts MATCH '"rolled"* AND "oat"*' ORDER BY bm25(food_fts) LIMIT 3""").fetchall()
    notice(f"search 'rolled oats' -> {[h[0] for h in hits]}")
    db.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="App/Resources/fdc.sqlite")
    args = parser.parse_args()
    f_name, s_name = build(args.out)
    notice(f"Built from {f_name} + {s_name}")
    report(args.out)


if __name__ == "__main__":
    main()
