# =============================================================================
# PopHIVE Cancer Incidence Data Ingestion
# Source: CDC WONDER, United States Cancer Statistics (USCS) Incidence,
#         2010-2022 (D205, https://wonder.cdc.gov/cancer-v2022.html; the
#         database covers 1999-2022, only 2010 on is pulled).
#         Pulled by scraper/cancer_scraper.py, one CSV per year x geography
#         level x demographic breakdown, every one grouped by Cancer Sites,
#         under raw/uscs_incidence_1999_2022/.
# Geography: National and state only. USCS has no county level in WONDER.
#            National rows are queried from CDC WONDER directly (never summed
#            up from states) and live in the state table under geography "00".
# Output:    standard/data_state.csv.gz
# SOURCES is a list so a second WONDER cancer database (e.g. USCS mortality,
# whose codes are already in scraper/form_config.json) can be added as one
# more entry writing its own table.
# =============================================================================

library(dplyr)
library(purrr)
library(vroom)

SOURCES <- list(
  incidence = list(
    raw_dir = "raw/uscs_incidence_1999_2022",
    years = 2010:2022, # pulled from 2010 on; the database starts in 1999
    prefix = "cancer_incidence",
    count_name = "cases",
    out = "standard/data_state.csv.gz"
  )
)

# Age bands, one raw file per band (each band is its own WONDER query with the
# five-year Age Groups filtered to the band; see scraper/cancer_scraper.py).
# WONDER only offers five-year groups, so the bands are 0-19 / 20-49 / 50+
# rather than <18 / 18-49 / 50+.
AGE_BANDS <- c("0to19" = "0-19", "20to49" = "20-49", "50plus" = "50+")

# -----------------------------------------------------------------------------
# Missingness markers
# -----------------------------------------------------------------------------
# Same two independent kinds as the drowning pipeline:
#
#   Suppressed     confidentiality suppression: any cell representing fewer
#                  than 16 cases (incidence) / deaths (mortality). Occurs in
#                  the count and the rate columns derived from it, never in
#                  Population.
#
#   Not Applicable no population denominator for this geography/demographic/
#   Not Available  site combination. Occurs in Population and the rates.
#
# One further use of "Not Applicable" is handled by dropping the row instead:
# a sex-specific site crossed with the other sex (Cervix Uteri x Male,
# Prostate x Female, ...) is "Not Applicable" in EVERY cell, count included.
# Those rows are structurally empty, not missing data.
#
# Missing cells are written as NA, never as a placeholder number; the two
# row-level flags say why a cell is missing.
SUPPRESSED_MARKER <- "Suppressed"
MISSING_DENOM_MARKERS <- c("Not Applicable", "Not Available")
NATIONAL_GEOGRAPHY <- "00"

# WONDER's "Invalid Value(s)" site: records with an invalid site code, not a
# cancer site. Dropped.
INVALID_SITE_CODE <- "99999"

# Category values dropped: unknown / not-stated groups with no population
# denominator, matching the drowning pipeline's drop of "Not Stated" and
# race "Not Available".
DROP_RACE <- c("Not Available", "Other Races and Unknown combined")
DROP_ETHNICITY <- c("Unknown or Missing")

to_num <- function(x) {
  suppressWarnings(as.numeric(ifelse(x %in% c(SUPPRESSED_MARKER, MISSING_DENOM_MARKERS), NA, x)))
}
is_suppressed <- function(x) x %in% SUPPRESSED_MARKER
is_missing_denom <- function(x) x %in% MISSING_DENOM_MARKERS
any_cell <- function(df, cols, pred) Reduce(`|`, lapply(df[cols], pred))

# The raw value columns, by the header text WONDER writes. The count column is
# "Count" on incidence and "Deaths" on mortality; it is renamed to "count"
# on read. Standard errors are not published but take part in the flags.
RAW_VALUE_COLS <- c(
  count = "count",
  population = "Population",
  age_adj_rate = "Age-Adjusted Rate",
  age_adj_rate_lcl = "Age-Adjusted Rate Lower 95% Confidence Interval",
  age_adj_rate_ucl = "Age-Adjusted Rate Upper 95% Confidence Interval",
  age_adj_rate_se = "Age-Adjusted Rate Standard Error",
  crude_rate = "Crude Rate",
  crude_rate_lcl = "Crude Rate Lower 95% Confidence Interval",
  crude_rate_ucl = "Crude Rate Upper 95% Confidence Interval",
  crude_rate_se = "Crude Rate Standard Error"
)
PUBLISHED <- c(
  "count", "population", "crude_rate", "crude_rate_lcl", "crude_rate_ucl",
  "age_adj_rate", "age_adj_rate_lcl", "age_adj_rate_ucl"
)

stop_unknown_values <- function(df, path) {
  vals <- unique(unlist(df[unname(RAW_VALUE_COLS)], use.names = FALSE))
  unknown <- vals[
    is.na(vals) |
      (is.na(suppressWarnings(as.numeric(vals))) &
        !(vals %in% c(SUPPRESSED_MARKER, MISSING_DENOM_MARKERS)))
  ]
  if (length(unknown)) {
    stop(
      "Unrecognized value(s) in the numeric cells of ", path, ": ",
      paste(ifelse(is.na(unknown), "<blank>", unknown), collapse = ", "),
      ". They would become unflagged NAs; extend SUPPRESSED_MARKER or ",
      "MISSING_DENOM_MARKERS to classify them.",
      call. = FALSE
    )
  }
}

clean_ethnicity_label <- function(x) {
  case_when(
    x == "Non-Hispanic" ~ "Not Hispanic",
    TRUE ~ x
  )
}

# Reads one raw export and standardizes it to long format for one dimension
# (age, sex, race or ethnicity, the other three "Overall"), keyed by site.
# Race and ethnicity are separate columns because their levels overlap: every
# race includes Hispanic people.
# Columns are located by header name, not position: the layout varies by file
# (national files have no geography columns; total and age-band files have no
# demographic column; mortality says "State"/"Deaths" where incidence says
# "States"/"Count").
#   dim       -- which output column the category goes in
#   cat_col   -- raw header holding the category, or NULL when the whole file
#                is one category (totals, age bands)
#   cat_value -- the category for a NULL cat_col
read_wonder <- function(path, dim, cat_col = NULL, cat_value = "Overall",
                        map_fn = identity, drop_raw = character(0), time_val) {
  df <- vroom::vroom(path, delim = ",", col_types = vroom::cols(.default = "c"),
                     show_col_types = FALSE, progress = FALSE)
  names(df)[names(df) %in% c("Count", "Deaths")] <- "count"

  geo_code_col <- intersect(c("States Code", "State Code"), names(df))
  df$geography <- if (length(geo_code_col)) df[[geo_code_col]] else NATIONAL_GEOGRAPHY

  missing_cols <- setdiff(c("Cancer Sites", "Cancer Sites Code", unname(RAW_VALUE_COLS), cat_col), names(df))
  if (length(missing_cols)) stop(path, " lacks column(s): ", paste(missing_cols, collapse = ", "))

  # Footer lines (Query Parameters, caveats, ...) have no site code.
  df <- df %>% filter(
    !is.na(.data[["Cancer Sites Code"]]), !is.na(geography),
    .data[["Cancer Sites Code"]] != INVALID_SITE_CODE
  )
  df$category <- if (is.null(cat_col)) cat_value else map_fn(df[[cat_col]])
  if (!is.null(cat_col)) df <- df %>% filter(!(.data[[cat_col]] %in% drop_raw))

  # Wrong-sex rows of sex-specific sites: every cell Not Applicable.
  all_na <- Reduce(`&`, lapply(df[unname(RAW_VALUE_COLS)], function(x) x %in% "Not Applicable"))
  df <- df[!all_na, ]

  stop_unknown_values(df, path)

  out <- tibble(
    geography = df$geography,
    time = time_val,
    cancer_site = trimws(df[["Cancer Sites"]]),
    cancer_site_code = df[["Cancer Sites Code"]],
    suppressed_flag = as.integer(any_cell(df, unname(RAW_VALUE_COLS), is_suppressed)),
    missing_denom_flag = as.integer(any_cell(df, unname(RAW_VALUE_COLS), is_missing_denom))
  )
  for (nm in PUBLISHED) out[[nm]] <- to_num(df[[RAW_VALUE_COLS[[nm]]]])
  out[[dim]] <- df$category
  for (other in setdiff(c("age", "sex", "race", "ethnicity"), dim)) out[[other]] <- "Overall"
  out
}

# All files of one source for one year: national + state, total + age bands
# + sex + race + ethnicity. Every fixed-name file must exist -- a gap is an
# error here, not a silently thinner table. The per-race and per-ethnicity
# state files are globbed, so one missing category would not stop this; run
# `scraper/cancer_scraper.py --check --verify` before ingesting, which
# reports every gap against the exact query list.
read_year <- function(src, yr) {
  time_val <- sprintf("%d-12-31", yr)
  year_dir <- file.path(src$raw_dir, yr)
  f <- function(name) {
    p <- file.path(year_dir, name)
    if (!file.exists(p)) stop("Missing raw file ", p, " -- run scraper/cancer_scraper.py to fill it")
    p
  }
  parts <- list()
  for (level in c("national", "state")) {
    parts[[paste0(level, "_total")]] <- read_wonder(f(paste0(level, "_total.csv")), dim = "age", time_val = time_val)
    for (band in names(AGE_BANDS)) {
      parts[[paste0(level, "_age_", band)]] <- read_wonder(
        f(sprintf("%s_age_%s.csv", level, band)),
        dim = "age", cat_value = AGE_BANDS[[band]], time_val = time_val
      )
    }
    parts[[paste0(level, "_gender")]] <- read_wonder(
      f(paste0(level, "_gender.csv")), dim = "sex", cat_col = "Sex", time_val = time_val
    )
    # State x race is pulled as one file per race (state_race_<race>.csv):
    # WONDER fails on the single ~30,000-row query. Same layout per file.
    race_files <- if (level == "national") {
      f("national_race.csv")
    } else {
      list.files(year_dir, pattern = "^state_race_.*\\.csv$", full.names = TRUE)
    }
    if (!length(race_files)) stop("No state_race_*.csv files in ", year_dir)
    parts[[paste0(level, "_race")]] <- map_dfr(
      race_files, read_wonder,
      dim = "race", cat_col = "Race", drop_raw = DROP_RACE, time_val = time_val
    )
    # Same split for state x ethnicity (state_ethnicity_<eth>.csv): the
    # ~16,000-row single query fails on WONDER too.
    eth_files <- if (level == "national") {
      f("national_ethnicity.csv")
    } else {
      list.files(year_dir, pattern = "^state_ethnicity_.*\\.csv$", full.names = TRUE)
    }
    if (!length(eth_files)) stop("No state_ethnicity_*.csv files in ", year_dir)
    parts[[paste0(level, "_ethnicity")]] <- map_dfr(
      eth_files, read_wonder,
      dim = "ethnicity", cat_col = "Ethnicity",
      map_fn = clean_ethnicity_label, drop_raw = DROP_ETHNICITY, time_val = time_val
    )
  }
  bind_rows(parts)
}

build_source <- function(src) {
  df <- map_dfr(src$years, read_year, src = src)
  # Value columns get the source prefix; the count column is named for what
  # it counts (cancer_incidence_cases / cancer_mortality_deaths).
  value_names <- setNames(PUBLISHED, paste0(
    src$prefix, "_", ifelse(PUBLISHED == "count", src$count_name, PUBLISHED)
  ))
  df %>%
    select(
      geography, time, cancer_site, cancer_site_code, age, sex, race, ethnicity,
      all_of(value_names), suppressed_flag, missing_denom_flag
    ) %>%
    arrange(geography, time, cancer_site_code, age, sex, race, ethnicity)
}

# -----------------------------------------------------------------------------
# 1. Initialize process record and check for changes
# -----------------------------------------------------------------------------
process <- if (!file.exists("process.json")) list(raw_state = NULL) else dcf::dcf_process_record()

raw_files <- sort(unlist(lapply(SOURCES, function(s) {
  list.files(s$raw_dir, recursive = TRUE, full.names = TRUE, pattern = "\\.csv$")
})))
raw_state <- list(hash = tools::md5sum(raw_files))

if (!identical(process$raw_state, raw_state)) {
  # ---------------------------------------------------------------------------
  # 2. Build and write the standardized tables
  # ---------------------------------------------------------------------------
  dir.create("standard", showWarnings = FALSE)
  for (src in SOURCES) {
    vroom::vroom_write(build_source(src), src$out, delim = ",")
  }

  # ---------------------------------------------------------------------------
  # 3. Record processed state
  # ---------------------------------------------------------------------------
  process$raw_state <- raw_state
  dcf::dcf_process_record(updated = process)
}
