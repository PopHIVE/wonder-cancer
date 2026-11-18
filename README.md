# pophive_cancer_data

Cancer incidence, 2010-2022, from CDC WONDER's United States Cancer
Statistics (USCS) incidence database: by year, national and state, cancer
site, and age band (0-19 / 20-49 / 50+), sex, race and Hispanic ethnicity.
County data are not available from this database.

This is a dcf data source project, initialized following the pattern of
`dcf::dcf_add_source`, and laid out like
[wonder-scraper-drowning](https://github.com/PopHIVE/wonder-scraper-drowning):

- `scraper/`: reproducible CDC WONDER pull into `raw/` (see
  [scraper/README.md](scraper/README.md))
- `ingest.R`: `raw/` -> `standard/data_state.csv.gz`
- `measure_info.json`: measure and source documentation

```R
dcf_check()
dcf_process()
```

Output columns: `geography` (state FIPS; `00` = national), `time`
(`YYYY-12-31`), `cancer_site`, `cancer_site_code`, `age`, `sex`,
`race`, `ethnicity`, `cancer_incidence_cases`, `cancer_incidence_population`,
`cancer_incidence_crude_rate[_lcl|_ucl]`,
`cancer_incidence_age_adj_rate[_lcl|_ucl]`, `suppressed_flag`,
`missing_denom_flag`. Missing values are `NA`, and the two flags say why. Each
row varies exactly one of age / sex / race / ethnicity, with the others
`Overall`. Race and ethnicity levels overlap (every race includes Hispanic
people), so they are separate columns.
