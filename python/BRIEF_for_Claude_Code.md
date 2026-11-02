# Brief for the Claude Code session (paste as the first message)

I am porting Duncan MacDonald's PROST v2 Stata pipeline (World Bank pension microsimulation, Mexico IMSS as the first country) to Python, and the result must work for any country. This folder is the project:

- `stata/` has Duncan's .do files. They are the reference. The live version is the "ANNUAL DATA VERY LOW" chain: the three `00` scripts, `01b`, `03 ... SYNTHETIC DATA`, `04 ... ANNUAL DATA VERY LOW`, `07`, `08`, `15`, the projector `1 - PROSTv2 - Build projection database - ANNUAL DATA VERY LOW.do` and `1b - PROSTv2 - Output charts.do`. The other variants (LOW, VERY LOW, EXTREMELY LOW, the monthly projector, the `XX` files) are older experiments; do not port them.
- `python/` has the port. Read `python/README.md` first: it explains the folder layout, the config file, what is already done (the three `00` scripts), what matches Stata and what cannot, and the observations on Duncan's code.
- `input/` has the data. The files are confidential administrative data and are large; never copy them elsewhere or print rows of individuals.
- `output/` is written by the scripts.

Rules for this work:

1. Replicate Duncan's logic exactly, including Stata semantics (`round` half away from zero, `min`/`max` ignoring missing, `xtile` definition, `joinby` keeping master values). Where the Stata code looks like a bug, reproduce it, count how often it matters, and list it for Duncan; do not silently fix it. The only exceptions are branches that can never return rows (documented in the README).
2. Every step must end with the same verification Duncan prints (synthetic vs target by cell, or model fit statistics). Numbers are compared on aggregates, not on individual rows, because random draws differ between Stata and numpy.
3. Nothing country-specific goes in the code. It goes in `python/config_<ISO3>.json`. Keep Duncan's file names and variable names for all outputs so his Stata projector can read them.
4. Do not invent inputs. If a file or a parameter is missing, stop and say which one. Known gaps: `04 ... ANNUAL DATA VERY LOW PULL.do`, the `05` script that produces `lifecycle_wages_MEX_cage`, and the script that creates `annual_MEX.dta` are not in `stata/`; `.ster` estimation files cannot be read from Python, so the model coefficients have to be exported from Stata (`esttab ... .csv, plain` or `putexcel` of `e(b)`) or the models re-estimated in Python.
5. Keep each script runnable on its own with `--config`, print progress with timestamps, and write intermediate outputs to `output/`.

Plan, in order:

- Step 1 (done, test it on the real data first): `python python/run_step1.py --config python/config_MEX.json`. Start with `sample_fraction` 0.01 to check memory and time, then 0.10.
- Step 2: port `01b - Pre-processing - Generate decile wage distributions.do` and `03 - Pre-processing - Generate affiliation rates - SYNTHETIC DATA.do`.
- Step 3: port `04`, `07`, `08`: build the estimation samples exactly as the do-files do, then re-estimate the GLM cloglog hazards and the retirement model in statsmodels with cluster-robust standard errors, and compare the coefficients with Duncan's (ask for his `esttab` output).
- Step 4: the projector, in stages: inputs and base year first, then the year-by-year loop, then the reporting and charts.
