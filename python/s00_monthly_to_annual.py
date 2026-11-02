"""
s00_monthly_to_annual.py
Python port of Duncan MacDonald's
  "00 - Convert synthetic baseyear from monthly to annual.do"

Collapses the monthly synthetic affiliate file to one row per person-year:
  max  of los, loa, iacc, status, spell_length
  sum  of dens  (months contributed in the year, 0-12)
  mean of weight, wage, reference_wage  (wage over the months with a wage)
by year, gender, id, age, yob, pension_class, wage_decile_ref; then rebuilds the
wage decile within year x age x gender from the wage relative to the year mean.

Input:   <outdir>/<annualize.monthly_file>.dta     (output of s00_synthetic_baseyear.py)
Output:  <outdir>/<annualize.monthly_file>_annualized.dta

Usage:  python s00_monthly_to_annual.py --config config_MEX.json
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd

from prost_common import read_dta, report, stata_xtile, write_dta


def main(config_path: str) -> None:
    cfg = json.loads(Path(config_path).read_text(encoding="utf-8"))
    outdir = Path(cfg["paths"]["outdir"])
    name = cfg["annualize"]["monthly_file"]
    nq = int(cfg["annualize"].get("n_quantiles", 10))
    infile = outdir / f"{name}.dta"
    outfile = outdir / f"{name}_annualized.dta"

    report(f"Reading {infile.name}")
    m = read_dta(infile)
    report(f"  {len(m):,} monthly rows")

    # ------------------------------------------------------------------ SECTION 1
    by = ["year", "gender", "id", "age", "yob", "pension_class", "wage_decile_ref"]
    a = (m.groupby(by, as_index=False, dropna=False, sort=True)
         .agg(los=("los", "max"), loa=("loa", "max"), iacc=("iacc", "max"), status=("status", "max"),
              spell_length=("spell_length", "max"), dens=("dens", "sum"),
              weight=("weight", "mean"), wage=("wage", "mean"), reference_wage=("reference_wage", "mean")))
    report(f"  {len(a):,} person-year rows")

    a["wage_decile"] = np.where(a["dens"] > 0, a["wage_decile_ref"], np.nan)

    # relative wage, carried forward (Stata: sort id year; carryforward, replace -- no by(id),
    # so a missing value takes the last non-missing value of the preceding rows in id order)
    mean_wage_yr = a.groupby("year", sort=False)["wage"].transform("mean")
    a["wage_relative_mean"] = a["wage"] / mean_wage_yr
    a = a.sort_values(["id", "year"], kind="mergesort").reset_index(drop=True)
    n_before = int(a["wage_relative_mean"].isna().sum())
    a["wage_relative_mean"] = a["wage_relative_mean"].ffill()
    n_after = int(a["wage_relative_mean"].isna().sum())
    if n_before != n_after:
        report(f"  NOTE: carryforward filled {n_before - n_after:,} missing relative wages from the preceding "
               f"person (Duncan's carryforward has no by(id); reproduced as is)")

    # deciles within year x age x gender, Stata xtile definition
    report("Computing wage deciles within year x age x gender")
    a["wage_decile_age_sex"] = stata_xtile(a["wage_relative_mean"], nq, by=["year", "age", "gender"], frame=a)
    a = a.drop(columns=["wage_relative_mean"])

    cols = ["year", "gender", "id", "age", "yob", "pension_class", "wage_decile_ref", "los", "loa", "iacc",
            "status", "spell_length", "dens", "weight", "wage", "reference_wage", "wage_decile", "wage_decile_age_sex"]
    a = a[cols]
    write_dta(a, outfile, value_labels={"pension_class": {1: "DB", 2: "DC"}})
    report(f"Annual dataset saved to: {outfile}  |  rows {len(a):,}")

    # quick summary
    with pd.option_context("display.float_format", "{:12.2f}".format, "display.width", 160):
        print(a[["dens", "wage", "reference_wage", "iacc", "los", "loa", "wage_decile_age_sex"]].describe().T
              [["count", "mean", "min", "max"]].to_string())
    report("done")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default="config_MEX.json")
    main(ap.parse_args().config)
