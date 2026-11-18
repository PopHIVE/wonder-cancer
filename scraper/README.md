# CDC WONDER cancer scraper

Produces every file under `raw/`. CDC WONDER has no API for sub-national
data, so this drives the live query forms with Selenium, one query per
year x geography level x breakdown, and downloads each result CSV.

- `cancer_scraper.py`: the cancer incidence pull. **Every parameter that
  defines the data is a constant in this file** (years, levels, age bands,
  races, extra queries). It hands its command line to the puller.
- `cdc_wonder_puller.py`: the generic puller, copied from
  [PopHIVE/wonder-scraper](https://github.com/PopHIVE/wonder-scraper) and
  extended for the cancer forms (see "Changes from upstream" below).
- `form_config.json`: WONDER's internal variable codes per database. The
  pull uses `uscs_incidence_1999_2022` (D205). The USCS mortality entry
  (`uscs_mortality_2018_2023`, D207) is kept for reference but is not
  pulled: its codes were read and smoke-tested on 2026-11-16 (one full year
  went through end to end).
- `requirements.txt`: pinned dependencies, including the exact commit of the
  govex `cdc_wonder` package.

## Reproducing the pull

```bash
# one-time: a venv with the pinned dependencies (needs Python 3.10+ and Chrome)
python -m venv scraper/.venv
scraper/.venv/bin/python -m pip install -r scraper/requirements.txt
#   Windows: scraper\.venv\Scripts\python -m pip install -r scraper\requirements.txt

# the full pull (fills whatever is missing under raw/)
scraper/.venv/bin/python scraper/cancer_scraper.py

# confirm every expected file is present and is what its name claims
scraper/.venv/bin/python scraper/cancer_scraper.py --check --verify

# build standard/ from raw/
Rscript ingest.R          # or dcf::dcf_process()
```

`--check --verify` exits 1 if anything is missing, unexpected or invalid, so
it can gate `ingest.R`. It reads each file's `Query Parameters:` footer and
checks the year, state filter, group-by dimensions, show-options, and that
the age band or race filter selected the expected number of values. It needs
no browser.

Already-downloaded files are skipped (by path), so a stopped run resumes
where it left off and a re-run only fills gaps. Each download is validated
against its footer before it is kept; a failed validation is kept under
`$TMPDIR/cdc_wonder_rejected/` for inspection and counted as a failure. Each
run ends with an `N downloaded, M skipped, K FAILED` tally.

Narrower runs, all flags passed through to the puller:

```bash
scraper/.venv/bin/python scraper/cancer_scraper.py --years 2022 2022
scraper/.venv/bin/python scraper/cancer_scraper.py --only state_race_white --no-headless
```

**Years.** 2010-2022 only (the database goes back to 1999). Set in `YEARS`
in `cancer_scraper.py`.

**Run time.** The full pull is 234 queries (18 per year x 13 years). Each
query takes ~30-100 s, plus a randomized 20-40 s pause between queries (a
uniform short delay got an earlier scraper blocked), so allow **~4-6
hours**. Keep the machine awake
the whole time: on macOS run under `caffeinate -i -s`; on Windows set
"Sleep" to Never while it runs. A sleeping machine stalls queries for tens
of minutes each.

**What reproducible means here.** The query set is fully determined by
`cancer_scraper.py` + `form_config.json`, and the code by
`requirements.txt`. The *data* are whatever CDC serves on the day: CDC
replaces these databases with each annual USCS release (new URL and
database code, e.g. `cancer-v2022` -> `cancer-v2023`), so the URLs here will
eventually stop working. Each export's footer records its query date and
CDC's suggested citation. Re-pulling the same release gives the same files
apart from that query-date line.

## Files produced

`raw/<database key>/<year>/`, every query grouped by Cancer Sites:

| file | breakdown |
| --- | --- |
| `national_total.csv`, `state_total.csv` | all demographics |
| `{national,state}_age_{0to19,20to49,50plus}.csv` | one age band each |
| `{national,state}_gender.csv` | sex |
| `national_race.csv`, `state_race_{aian,api,black,white}.csv` | race (state: one file per race) |
| `national_ethnicity.csv`, `state_ethnicity_{hispanic,nonhispanic}.csv` | Hispanic / Non-Hispanic (state: one file each) |

## Design decisions and CDC-side constraints

- **No county level.** The USCS databases in WONDER go no finer than State
  (also Census Region/Division and ~110 MSAs). There is no county variable on
  either form.
- **Age bands are 0-19 / 20-49 / 50+, not <18 / 18-49 / 50+.** The only age
  variable is five-year groups (`<1, 1-4, 5-9, 10-14, 15-19, ...`), and 18
  falls inside 15-19. 0-19 is also USCS's own childhood-cancer age range.
  Each band is a separate query with the Age Groups select filtered to the
  band's five-year groups. WONDER then aggregates the band itself, so counts,
  rates, CIs and suppression apply to the band. Summing five-year rows
  afterwards would lose every suppressed cell and CDC's CIs. Edit
  `AGE_BANDS` in `cancer_scraper.py` to change the bands.
- **State x race and state x ethnicity are one query per category.** WONDER
  answers a single State x Cancer Sites x Race query (~27,000 rows) and a
  State x Cancer Sites x Ethnicity query (~16,000 rows) with an invalid HTTP
  response (Chrome shows `ERR_INVALID_RESPONSE`), checked 2026-11-16, while
  State x Cancer Sites x Sex (~10,700 rows) works. So `state_race_<race>.csv`
  and `state_ethnicity_<eth>.csv` are each filtered to one category (~5,400
  rows, like every other state query). Keep any new state query under
  ~10,000 rows.
- **State totals are pulled, not summed.** The drowning ingest derives state
  "Overall" rows by summing the sexes. Here that would be missing for every
  sex-specific site (the other sex is "Not Applicable"), and it would have no
  age-adjusted rate or CI. So `state_total.csv` is a query of its own.
- **Measures.** Count (new cases), Population, Crude Rate + 95% CI + SE,
  Age-Adjusted Rate (2000 US standard) + 95% CI + SE. On these forms the
  rate boxes are opt-in and their CI/SE boxes start *disabled*, which means
  they are not submitted. The puller enables and ticks them
  (`_apply_measures`).
- **Cancer site.** Grouping by Cancer Sites returns every node of the USCS
  site-recode hierarchy (105 nodes on incidence). Parent and child
  sites both appear, so never sum across sites.

## Changes from upstream `cdc_wonder_puller.py`

All additive; the drowning/natality behavior is unchanged.

- `"Cancer Sites"` added to the role vocabulary.
- `agree_xpath` config key: the cancer forms have no "I Agree" data-use page,
  but the govex `wonder_query()` always clicks one. The cancer entries point
  that click at the harmless title box instead.
- `measures` config key + `_apply_measures`: tick (and enable) extra measure
  checkboxes.
- `filter_selectors` config key, `query_filters`, `_apply_filters`: restrict
  a variable to a subset of values for one query. Used via `--age-band
  NAME=v,v` (replaces the Age group-by with one filtered query per band) and
  via `--extra-query NAME=Label,Label|Role=v,v`.
- `--group-by LABEL`: appended to every built-in query (`Cancer Sites` here).
- Footer validation checks each filter's selected-value count.
- `DOWNLOAD_MAX_WAIT` raised from 180 s to 600 s (WONDER's own query
  timeout).

## Finding variable codes for a new WONDER database

Load the form, accept the agreement if it has one, and read each `<select>`'s
id and options and each checkbox's `<label>`. The cancer codes in
`form_config.json` were read that way on 2026-11-16. Smoke-test any new
entry with one state-level query (`--years Y Y --only state_gender
--no-headless`) before a full pull.
