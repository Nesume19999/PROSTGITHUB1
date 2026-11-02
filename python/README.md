# PROST v2 in Python: step 1, synthetic base-year data

Python port of the three "00" scripts of Duncan MacDonald's Stata pipeline (PROST v2, "ANNUAL DATA VERY LOW" version). Nothing country-specific is written in the code: everything that is Mexico comes from `config_MEX.json`.

## Folder layout

```
PROST-2/
  stata/        Duncan's .do files (reference, not run)
  python/       this folder
  input/        data: baseyear_data_MEX.dta, 001-Data Aggregates.dta, pensioners_MEX.dta, wage_growth_MEX.csv
  output/       written by the scripts
```

Run from the `PROST-2` folder (so that `input/` and `output/` resolve):

```
python python/run_step1.py --config python/config_MEX.json
```

or one step at a time, in this order:

```
python python/s00_synthetic_baseyear.py   --config python/config_MEX.json
python python/s00_synthetic_pensioners.py --config python/config_MEX.json
python python/s00_monthly_to_annual.py    --config python/config_MEX.json
```

Requirements: Python 3.10+, pandas 2.x or 3.x, numpy. Nothing else.

## What each script does

| Script | Duncan's do-file | Output |
|---|---|---|
| `s00_synthetic_baseyear.py` | 00 - Generate synthetic baseyear from aggregates (current, not "Old") | `synthetic_affiliates_<N>pct_sample.dta`, `synthetic_weights_<N>pct_sample.dta`, `verification_affiliates_<N>pct.csv` |
| `s00_synthetic_pensioners.py` | 00 - Generate synthetic pensioners from aggregates | `synthetic_pensioners_<N>pct_sample.dta`, `verification_pensioners_<N>pct.csv` |
| `s00_monthly_to_annual.py` | 00 - Convert synthetic baseyear from monthly to annual | `synthetic_affiliates_<N>pct_sample_annualized.dta` |

Output file names and variable names are Duncan's, so the Stata projector (`1 - PROSTv2 - Build projection database - ANNUAL DATA VERY LOW.do`) can read the Python outputs directly. Each script prints the same verification Duncan prints (synthetic cell statistics vs targets, cells off by more than 1%) and also saves it as CSV.

Note on the sample size: Duncan's 00 scripts write the 10% sample; his projector reads the 1% sample (`synthetic_affiliates_1pct_sample_annualized.dta`). Set `sample_fraction` to 0.01 in the config to produce the file the projector expects, or change the projector's `baseyear_data` parameter.

## Another country

Copy `config_MEX.json` to `config_<ISO3>.json` and edit:

- `country`, `files`: the ISO3 code and the input file names.
- `rebase`: year of the data and base year of the projection; set `enabled` to 0 if the data are already in base-year prices.
- `service_credit_before_records`: Duncan's "pre-1997 credit". Set `enabled` to 0 if the records cover the whole career; otherwise give the first year/month of the records and the age-at-first-affiliation range by gender.
- `iacc_cap`: marked by Duncan as Mexico-specific; set `enabled` to 0 elsewhere.
- `pension_types`: which aggregate columns (num<X>, pen<X>) map to pension_id 1-6.

The input files must have Duncan's variable names (the scripts stop with a clear message if a column is missing): the monthly file needs `id age gender yob year month dens wage iacc los loa spell_length wage_relative_mean wage_decile_ref wage_decile wage_decile_age_sex status`; the aggregates file needs `age gender numA contrA contrT wage iacc numB..numG penB..penG`; the pensioners file needs `age gender pension_id (or type) pension_benefit startyear pension_class pension_type`; the wage growth file needs `iso3 year wage_growth cpi`.

## What matches Stata and what does not

Matches by construction: the number of affiliates, DC contributors, DB contributors and pensioners in every cell; the cell means of wages, account balances and benefits (up to the iacc cap, which Duncan applies after the rescaling too); the DB/DC assignment rule; the rebasing indices; the service-credit formula.

Does not match row by row: which individuals are sampled, cloned or dropped, and the random age at first affiliation. Stata's `runiform()` with `set seed 12345` cannot be reproduced in numpy. The distributions are the same; the individual rows are not. A Stata run and a Python run should be compared on aggregates, not on ids.

Stata semantics reproduced on purpose (in `prost_common.py`): `round()` rounds halves away from zero; `min()` and `max()` ignore missing arguments; `xtile`/`gquantiles` use Stata's percentile definition (not pandas.qcut's interpolation); `joinby` keeps the master values of variables present in both files (this is why `reference_wage`, `ever_contr`, `avg_wage_ind` and `iacc_dec_ind` in the monthly output are the person-level December values); `carryforward` without `by()` fills from the preceding row whatever the person.

## Observations on Duncan's code worth raising with him

1. Persons with no wage history at all (`wage_relative_mean` missing) get `reference_wage` equal to the maximum average wage in the file, because Stata's `min(. , max_wage)` returns `max_wage`. The port reproduces it and prints how many persons are affected. If the number is not negligible, this is probably not intended.
2. In the pensioners script, the opposite-gender fallback (Section 3b, pass 2) keeps `pension_id == donor_gender` and then joins the donors on the target gender, which cannot return rows (that gender is absent). The port implements what the comment says it intends (nearest age in the other gender, same pension type). The branch only runs if a whole gender is missing for a pension type.
3. In the affiliates script the same pass 2 joins on the target gender as well; same remark, same low relevance.
4. In the annualizer, `carryforward wage_relative_mean, replace` runs without `by(id)`. With one year of data the non-contributors come first in id order, so nothing is actually carried across persons; the port prints a note if it ever does.
5. Synthetic non-contributors (contributors re-labelled for cells that have no non-contributors) keep the donor's `wage_decile` in their monthly rows instead of 0, unlike real non-contributors. Reproduced as is.
6. Script 01 creates a variable named `penson_class` (typo); harmless, the 00 script creates `pension_class` itself.

## Next steps (the agreed plan)

2. `01b` (decile wage distributions) and `03 SYNTHETIC DATA` (affiliation rates), the two short pre-processing scripts whose CSVs the projector reads.
3. The models: `04` (two cloglog hazards), `07` and `08` (retirement database and model). Either re-estimate in Python (statsmodels GLM with cluster-robust SEs) or use coefficients exported by Duncan from the `.ster` files (`estimates use`, then `esttab using <name>.csv, plain` or `putexcel` with `e(b)`); `.ster` files cannot be read from Python.
4. The projector, in stages: load inputs and reproduce the base year, then the year-by-year dynamics; the mata root finder becomes numpy/scipy.

Missing from the folder and needed for step 3 and 4: `04 ... ANNUAL DATA VERY LOW PULL.do`, the `05` script that produces `lifecycle_wages_MEX_cage`, and the script that creates `annual_MEX.dta`.
