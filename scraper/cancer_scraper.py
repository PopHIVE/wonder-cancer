"""
CDC WONDER Cancer Incidence Scraper
===================================
Database : United States and Puerto Rico Cancer Statistics, 1999-2022
           Incidence (USCS, D205) -- https://wonder.cdc.gov/cancer-v2022.html
Years    : 2010-2022 (the database itself goes back to 1999)

Geographic resolution : national + state. USCS has NO county level in WONDER
                        (geography stops at State / Region / Division / MSA),
                        so unlike the drowning pull there are no county_*
                        files.
Breakdowns            : every query is grouped by Cancer Sites (the full USCS
                        site hierarchy), then by ONE of: nothing (total), age
                        band, sex, race, Hispanic ethnicity -- queried
                        separately, not cross-tabulated, as in the drowning
                        pipeline.
Age bands             : 0-19, 20-49, 50+. WONDER's cancer forms only offer
                        five-year age groups, so an <18 / 18-49 split is not
                        possible (18 falls inside 15-19); 0-19 is also USCS's
                        own "childhood cancer" definition. Each band is its
                        own query with the Age Groups select narrowed to that
                        band's five-year groups, so WONDER aggregates the band
                        server-side -- counts, crude and age-adjusted rates and
                        CIs are CDC's own, and suppression applies to the band
                        total rather than to each five-year cell.
Measures              : case count, population, crude rate + 95% CI + SE,
                        age-adjusted rate (2000 US std) + 95% CI + SE.

Output -> raw/uscs_incidence_1999_2022/<year>/ in this repo, the tree
ingest.R reads:
    national_{total,age_0to19,age_20to49,age_50plus,gender,race,ethnicity}.csv
    state_{total,age_0to19,age_20to49,age_50plus,gender}.csv
    state_race_<race>.csv, state_ethnicity_<eth>.csv
        (one per category -- see EXTRA_QUERIES for why)

Everything that defines the pull is a constant in this file; the mechanics
live in cdc_wonder_puller.py and the WONDER variable codes in
form_config.json. Re-running this file with no arguments reproduces the full
raw/ tree (already-present files are skipped, so it also resumes a stopped
run). Dependencies are pinned in scraper/requirements.txt.

Run (one-time install, then run; see scraper/README.md):
    python -m venv scraper/.venv
    scraper/.venv/bin/python -m pip install -r scraper/requirements.txt   # Windows: scraper\\.venv\\Scripts\\python
    scraper/.venv/bin/python scraper/cancer_scraper.py

Useful extra flags (passed through to the puller; see
`cdc_wonder_puller.py --help` for the rest):
    --check              list expected-vs-present files, download nothing
    --check --verify     ...and validate every present file's footer
    --years 2022 2022    one year only (overrides YEARS; argparse keeps the last)
    --only state_gender  one query type only
    --no-headless        watch the browser
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import cdc_wonder_puller  # noqa: E402

DATASET_KEY = "uscs_incidence_1999_2022"
YEARS = (2010, 2022)                # inclusive; the database covers 1999-2022
LEVELS = ["national", "state"]
AGE_GROUPING = "five_year"          # the only age variable this form has
GROUP_BY_ALWAYS = ["Cancer Sites"]  # every query is split by site

# Five-year Age Groups option values per band.
# Band names go into filenames: national_age_0to19.csv etc.
AGE_BANDS = {
    "0to19":  ["1", "1-4", "5-9", "10-14", "15-19"],
    "20to49": ["20-24", "25-29", "30-34", "35-39", "40-44", "45-49"],
    "50plus": ["50-54", "55-59", "60-64", "65-69", "70-74", "75-79", "80-84", "85+"],
}

# Race option values, keyed by the slug that goes in the filename. "Other
# Races and Unknown combined" (2131-1) is not pulled: it has no population
# denominator and ingest.R would drop it anyway.
RACES = {"aian": "1002-5", "api": "A-PI", "black": "2054-5", "white": "2106-3"}

# Ethnicity option values, likewise ("Unknown or Missing", UNK, not pulled).
ETHNICITIES = {"hispanic": "2135-2", "nonhispanic": "2186-5"}

# Queries the puller's built-in set does not cover, or covers in a shape
# WONDER cannot serve (--no-race is passed, so race and ethnicity are all
# defined here):
#
# state_total     -- the puller only builds a national_total. State totals
#                    are pulled rather than summed from the sexes as the
#                    drowning ingest does: a sex-specific site is "Not
#                    Applicable" for the other sex, so a sum would be missing
#                    for every such site, and it would have no age-adjusted
#                    rate or CI.
# state_race_<r>,  -- WONDER answers a State x Cancer Sites x Race query
# state_ethnicity_<e>  (~27,000 rows) and a State x Cancer Sites x Ethnicity
#                    query (~16,000 rows) with an invalid HTTP response
#                    (Chrome: ERR_INVALID_RESPONSE), both checked 2026-11-16;
#                    State x Cancer Sites x Sex (~10,700 rows) works. So both
#                    are split into one query per category, each filtered to
#                    that category (~5,400 rows, the size of every other
#                    state query here).
EXTRA_QUERIES = [
    "state_total=State,Cancer Sites",
    "national_race=Cancer Sites,Race",
    "national_ethnicity=Cancer Sites,Hispanic Origin",
] + [f"state_race_{slug}=State,Cancer Sites,Race|Race={code}" for slug, code in RACES.items()] + [
    f"state_ethnicity_{slug}=State,Cancer Sites,Hispanic Origin|Hispanic Origin={code}"
    for slug, code in ETHNICITIES.items()
]

BASE_ARGS = [
    "--dataset", DATASET_KEY,
    "--years", *map(str, YEARS),
    "--levels", *LEVELS,
    "--age", AGE_GROUPING,
    "--no-race",
    *[arg for g in GROUP_BY_ALWAYS for arg in ("--group-by", g)],
    *[arg for name, vals in AGE_BANDS.items() for arg in ("--age-band", f"{name}={','.join(vals)}")],
    *[arg for q in EXTRA_QUERIES for arg in ("--extra-query", q)],
]


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else list(argv)
    return cdc_wonder_puller.main(BASE_ARGS + argv)


if __name__ == "__main__":
    sys.exit(main())
