"""European food composition tables for fdc.sqlite.

- Ciqual 2025 (ANSES, France): 3,484 foods. Licence Ouverte / Open Licence 2.0 (Etalab), attribution required.
  https://doi.org/10.57745/RDMHWY
- CoFID 2021 (McCance and Widdowson's Composition of Foods Integrated Dataset, UK): ~2,900 foods.
  Contains public sector information licensed under the Open Government Licence v3.0.
  https://www.gov.uk/government/publications/composition-of-foods-integrated-dataset-cofid

Both report carbohydrate as *available* carbohydrate (fibre not included), like EU food labels.
Neither has household measures (cup, tbsp, piece), so each food borrows the measures of a closely matching
USDA food (see `borrow_portions`).

IDs: Ciqual = 10,000,000 + alim_code; CoFID = 20,000,000 + running number (USDA ids are below 10,000,000).
"""
import io
import json
import re
import urllib.request
import xml.etree.ElementTree as ET

CIQUAL_DATASET_API = ("https://entrepot.recherche.data.gouv.fr/api/datasets/:persistentId/"
                      "?persistentId=doi:10.57745/RDMHWY")
CIQUAL_FILE_URL = "https://entrepot.recherche.data.gouv.fr/api/access/datafile/{id}"
COFID_PAGE = "https://www.gov.uk/government/publications/composition-of-foods-integrated-dataset-cofid"
COFID_FALLBACK = ("https://assets.publishing.service.gov.uk/media/60538b91e90e07527df82ae4/"
                  "McCance_Widdowsons_Composition_of_Foods_Integrated_Dataset_2021..xlsx")

CIQUAL_BASE = 10_000_000
COFID_BASE = 20_000_000

# Ciqual constituent codes
C_KCAL, C_PROTEIN, C_CARBS, C_FAT, C_FIBRE, C_SUGARS = "328", "25000", "31000", "40000", "34100", "32000"
C_WANTED = {C_KCAL, C_PROTEIN, C_CARBS, C_FAT, C_FIBRE, C_SUGARS}

USER_AGENT = "Mozilla/5.0 (RecipeReel food database builder; +https://github.com/theunknownblackhathacker/RecipeReel)"


def _get(url, timeout=600):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def parse_value(text):
    """'12,5' → 12.5, 'traces' → 0, '< 0,5' → 0.25 (half the limit), '-' / '' / 'N' → None."""
    if text is None:
        return None
    t = str(text).strip().lower().replace(",", ".")
    if t in ("", "-", "n", "na", "nd"):
        return None
    if t in ("traces", "tr", "trace"):
        return 0.0
    if t.startswith("<"):
        try:
            return float(t[1:].strip()) / 2
        except ValueError:
            return None
    try:
        return float(t)
    except ValueError:
        return None


def kcal_estimate(protein, fat, carbs, fibre):
    """EU Regulation 1169/2011 factors."""
    if protein is None or fat is None or carbs is None:
        return None
    return 4 * protein + 9 * fat + 4 * carbs + 2 * (fibre or 0)


# MARK: - Ciqual

def load_ciqual(log):
    """Returns (foods, macros, version) where foods = {id: (description, category)} and
    macros = {id: (kcal, kcal_source, protein, fat, carbs, fibre, sugars)}."""
    meta = json.loads(_get(CIQUAL_DATASET_API, timeout=60))["data"]["latestVersion"]
    files = {f["dataFile"]["filename"]: f["dataFile"]["id"] for f in meta["files"]}
    def pick(prefix):
        names = sorted(n for n in files if n.startswith(prefix) and n.endswith(".xml"))
        if not names:
            raise RuntimeError(f"Ciqual: no {prefix}*.xml in {sorted(files)}")
        return names[-1]
    alim_name, compo_name, grp_name = pick("alim_2"), pick("compo_"), pick("alim_grp_")
    log(f"Ciqual files: {alim_name}, {compo_name}, {grp_name}")

    groups = {}
    for el in ET.fromstring(_get(CIQUAL_FILE_URL.format(id=files[grp_name]))):
        code = (el.findtext("alim_ssgrp_code") or el.findtext("alim_grp_code") or "").strip()
        name = (el.findtext("alim_ssgrp_nom_eng") or el.findtext("alim_grp_nom_eng") or "").strip()
        if code:
            groups[code] = name

    foods = {}
    for el in ET.fromstring(_get(CIQUAL_FILE_URL.format(id=files[alim_name]))):
        code = (el.findtext("alim_code") or "").strip()
        name = (el.findtext("alim_nom_eng") or "").strip()
        if not code.isdigit() or not name:
            continue
        group = groups.get((el.findtext("alim_ssgrp_code") or "").strip(), "")
        foods[CIQUAL_BASE + int(code)] = (name, group)

    values = {}
    data = _get(CIQUAL_FILE_URL.format(id=files[compo_name]))
    for _, el in ET.iterparse(io.BytesIO(data)):
        if el.tag != "COMPO":
            continue
        const = (el.findtext("const_code") or "").strip()
        if const in C_WANTED:
            code = (el.findtext("alim_code") or "").strip()
            if code.isdigit():
                values.setdefault(CIQUAL_BASE + int(code), {})[const] = parse_value(el.findtext("teneur"))
        el.clear()

    macros = {}
    for fid, v in values.items():
        if fid not in foods:
            continue
        protein, fat, carbs = v.get(C_PROTEIN), v.get(C_FAT), v.get(C_CARBS)
        fibre, sugars = v.get(C_FIBRE), v.get(C_SUGARS)
        kcal, source = v.get(C_KCAL), "ciqual"
        if kcal is None:
            kcal, source = kcal_estimate(protein, fat, carbs, fibre), "estimated"
        if kcal is None:
            continue
        macros[fid] = (kcal, source, protein, fat, carbs, fibre, sugars)
    foods = {k: v for k, v in foods.items() if k in macros}
    version = re.sub(r"^alim_|\.xml$", "", alim_name)
    log(f"Ciqual {version}: {len(foods)} foods with macros")
    return foods, macros, version


# MARK: - CoFID

def load_cofid(log):
    import openpyxl  # pip install openpyxl (fdc.yml installs it)

    url = COFID_FALLBACK
    try:
        page = _get(COFID_PAGE, timeout=60).decode("utf-8", "replace")
        links = re.findall(r'https://assets\.publishing\.service\.gov\.uk/[^"]*Integrated_Dataset[^"]*\.xlsx', page)
        if links:
            url = sorted(set(links))[-1]
    except Exception as exc:  # noqa: BLE001
        log(f"CoFID page not readable ({exc}); using the known file")
    log(f"CoFID file: {url}")
    wb = openpyxl.load_workbook(io.BytesIO(_get(url)), read_only=True, data_only=True)
    sheet = next(name for name in wb.sheetnames if "Proximates" in name)
    rows = wb[sheet].iter_rows(values_only=True)
    header = list(next(rows))
    codes = list(next(rows))     # INFOODS-style codes: PROT, FAT, CHO, KCALS, AOACFIB, ENGFIB, TOTSUG
    next(rows)                   # long names
    col = {code: i for i, code in enumerate(codes) if code}
    name_col = header.index("Food Name")
    code_col = header.index("Food Code")
    group_col = header.index("Group") if "Group" in header else None

    foods, macros = {}, {}
    for index, row in enumerate(rows, start=1):
        name = (row[name_col] or "").strip() if row[name_col] else ""
        if not name or not row[code_col]:
            continue
        get = lambda key: parse_value(row[col[key]]) if key in col else None  # noqa: E731
        protein, fat, carbs = get("PROT"), get("FAT"), get("CHO")
        fibre = get("AOACFIB")
        if fibre is None:
            fibre = get("ENGFIB")
        sugars = get("TOTSUG")
        kcal, source = get("KCALS"), "cofid"
        if kcal is None:
            kcal, source = kcal_estimate(protein, fat, carbs, fibre), "estimated"
        if kcal is None:
            continue
        fid = COFID_BASE + index
        foods[fid] = (name, str(row[group_col] or "") if group_col is not None else "")
        macros[fid] = (kcal, source, protein, fat, carbs, fibre, sugars)
    log(f"CoFID 2021: {len(foods)} foods with macros")
    return foods, macros, url.rsplit("/", 1)[-1]


# MARK: - Household measures borrowed from USDA

STOP = {"or", "and", "with", "from", "type", "the", "of", "in", "to", "be", "min", "max", "style", "100",
        "prepacked", "home", "made", "homemade", "retail", "average", "mixed", "fat", "fresh"}
# Words that mark a different form of a food; a donor with one of these must share it with the EU food.
FORM_WORDS = {"flour", "powder", "powdered", "dried", "dehydrated", "juice", "punch", "canned", "frozen", "sauce",
              "soup", "chips", "fried", "breaded", "candied", "pickled", "cured", "smoked", "corned", "baby",
              "infant", "dip", "spread", "mix", "drink", "beverage", "concentrate", "paste", "puree", "syrup",
              "jam", "flakes", "crisps", "nectar", "babyfood", "toddler", "formula", "restaurant", "fast",
              "oil", "leaves", "seed", "seeds", "pancakes", "pancake", "pie", "salad", "soup"}
# EU names whose USDA counterpart is worded differently.
DONOR_OVERRIDES = {
    "breadcrumbs": "Bread, crumbs, dry, grated, plain",
    "wheat tortilla wrap": "Tortillas, ready-to-bake or -fry, flour, refrigerated",
    "maize/corn tortilla wrap": "Tortillas, ready-to-bake or -fry, corn",
    "phyllo or filo dough": "Phyllo dough",
    "pastry, filo": "Phyllo dough",
}


def _words(text):
    return [w for w in re.findall(r"[a-z]+", text.lower()) if len(w) >= 3 and w not in STOP]


def borrow_portions(db, eu_ids, log):
    """Copies USDA household measures (cup, tbsp, piece…) to each EU food from the USDA food whose name
    contains every main word of the EU food's name (the part before the first comma), preferring raw
    entries when the EU food is raw. Foods without a confident donor get no measures (weights only)."""
    usda_types = "('foundation_food', 'sr_legacy_food', 'survey_fndds_food')"
    has_portion = {r[0] for r in db.execute("SELECT DISTINCT fdc_id FROM portion")}
    by_description = {r[1].lower(): r[0] for r in db.execute(
        f"SELECT fdc_id, description FROM food WHERE data_type IN {usda_types}")}
    borrowed, rows = 0, []
    examples = []
    for fid in eu_ids:
        name = db.execute("SELECT description FROM food WHERE fdc_id = ?", (fid,)).fetchone()[0]
        lower = name.lower()
        donor = None
        for key, target in DONOR_OVERRIDES.items():
            if lower.startswith(key) and target.lower() in by_description:
                donor = by_description[target.lower()]
                break
        if donor is None:
            head = list(dict.fromkeys(_words(name.split(",")[0])))
            if not head:
                continue
            eu_words = set(_words(name))
            # Whole words (porter-stemmed by the index), no prefixes: "horse" must not find "horseradish".
            match = " AND ".join(f'"{w}"' for w in head[:4])
            hits = db.execute(f"""
                SELECT f.fdc_id, f.description FROM food_fts JOIN food f ON f.fdc_id = food_fts.fdc_id
                WHERE food_fts MATCH ? AND f.data_type IN {usda_types}
                ORDER BY bm25(food_fts) LIMIT 60""", (match,)).fetchall()
            wants_raw = "raw" in eu_words
            best, best_score = None, None
            for rank, (hid, desc) in enumerate(hits):
                if hid not in has_portion:
                    continue
                d_words = set(_words(desc))
                # A different form of the food ("Potato flour" for potatoes) has different measures.
                if (d_words & FORM_WORDS) - eu_words:
                    continue
                score = -rank * 0.05 - 0.3 * len(d_words - eu_words)
                if wants_raw and "raw" in d_words:
                    score += 2
                first = desc.lower().split(",")[0].split()[0].rstrip("s")
                if first == head[0].rstrip("s"):
                    score += 1
                if best_score is None or score > best_score:
                    best, best_score = hid, score
            donor = best
        if donor is None:
            continue
        portions = db.execute("SELECT amount, unit_text, grams FROM portion WHERE fdc_id = ?", (donor,)).fetchall()
        rows += [(fid, a, u, g) for a, u, g in portions]
        borrowed += 1
        if len(examples) < 25 and fid % 23 == 0:
            donor_name = db.execute("SELECT description FROM food WHERE fdc_id = ?", (donor,)).fetchone()[0]
            examples.append(f"{name} ← {donor_name}")
    db.executemany("INSERT INTO portion VALUES (?, ?, ?, ?)", rows)
    log(f"Household measures borrowed from USDA for {borrowed} of {len(eu_ids)} EU foods")
    for example in examples:
        print(f"  measures: {example}")
    return borrowed
