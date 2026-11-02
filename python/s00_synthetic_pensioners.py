"""
s00_synthetic_pensioners.py
Python port of Duncan MacDonald's
  "00 - Generate synthetic pensioners from aggregates.do"

Samples individuals from the pensioner microdata and rescales benefits so that,
in every age x gender x pension type cell, the synthetic data match the targets:
number of beneficiaries (numB..numG) and average monthly benefit (penB..penG).
  1 = Old-age DB (B)    2 = Disability DB (C)   3 = Survivor DB (D)
  4 = Old-age DC (E)    5 = Disability DC (F)   6 = Survivor DC (G)
Benefits in payment are rebased from the year of the data to the base year with
the CPI index.

Inputs (see config_<ISO3>.json):
  <indir>/<pensioners>      pensioner microdata
  <indir>/<aggregates>      targets by age x gender
  <indir>/<wage_growth>     iso3, year, wage_growth, cpi (percent)
Output:
  <outdir>/synthetic_pensioners_<N>pct_sample.dta

Usage:  python s00_synthetic_pensioners.py --config config_MEX.json
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd

from prost_common import (nearest_age_donors, pct_diff, read_dta, rebasing_indices,
                          report, sample_to_target, stata_max, stata_round, summarize,
                          write_dta)

PENSION_LABELS = {1: "Old-age DB", 2: "Disability DB", 3: "Survivor DB",
                  4: "Old-age DC", 5: "Disability DC", 6: "Survivor DC"}


def main(config_path: str) -> None:
    cfg = json.loads(Path(config_path).read_text(encoding="utf-8"))
    country = cfg["country"]
    indir = Path(cfg["paths"]["indir"])
    outdir = Path(cfg["paths"]["outdir"])
    outdir.mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------------ SECTION 0
    sample_fraction = float(cfg["sample_fraction"])
    sample_name = int(stata_round(100 * sample_fraction))
    rng = np.random.default_rng(int(cfg["seed"]))
    rb = cfg["rebase"]
    type_map = {k: int(v) for k, v in cfg["pension_types"].items() if not k.startswith("_")}
    output_file = outdir / f"synthetic_pensioners_{sample_name}pct_sample.dta"

    wage_index, cpi_index = 1.0, 1.0
    if int(rb["enabled"]) == 1:
        wage_index, cpi_index = rebasing_indices(indir / cfg["files"]["wage_growth"], country,
                                                 int(rb["data_year"]), int(rb["base_year"]))
        report(f"Rebasing {rb['data_year']} to {rb['base_year']}: wage index = {wage_index:.4f} | CPI index = {cpi_index:.4f}")

    # ------------------------------------------------------------------ SECTION 1
    report(f"Reading {cfg['files']['pensioners']}")
    p = read_dta(indir / cfg["files"]["pensioners"])
    if "pension_id" not in p.columns:
        if "type" not in p.columns:
            raise ValueError("pensioners file has neither pension_id nor type")
        p["pension_id"] = p["type"].map(type_map)
    p["id"] = np.arange(1, len(p) + 1)
    cols = ["id", "age", "gender", "pension_id", "pension_benefit", "startyear", "pension_class", "pension_type"]
    absent = [c for c in cols if c not in p.columns]
    if absent:
        raise ValueError(f"pensioners file lacks columns: {absent}")
    pool = p[cols][p["pension_id"].notna()].reset_index(drop=True)
    report(f"  {len(pool):,} pensioners in the pool")

    # ------------------------------------------------------------------ SECTION 2
    cur_agg = (pool.groupby(["age", "gender", "pension_id"], as_index=False)
               .agg(current_num=("id", "size"), current_pen=("pension_benefit", "mean")))

    # ------------------------------------------------------------------ SECTION 3
    report(f"Reading {cfg['files']['aggregates']}")
    agg = read_dta(indir / cfg["files"]["aggregates"])
    frames = []
    for letter, pid in type_map.items():
        frames.append(pd.DataFrame({"age": agg["age"], "gender": agg["gender"], "pension_id": pid,
                                    "target_num": agg[f"num{letter}"], "target_pen": agg[f"pen{letter}"]}))
    targets = pd.concat(frames, ignore_index=True)
    targets["target_pen"] = targets["target_pen"] * cpi_index
    targets = targets[targets["target_num"].notna() & (targets["target_num"] != 0)].reset_index(drop=True)
    if sample_fraction < 1:
        targets["target_num"] = stata_max(1, stata_round(targets["target_num"] * sample_fraction))
    report(f"  {len(targets)} target cells; sample target: {int(targets['target_num'].sum()):,} pensioners")

    # ------------------------------------------------------------------ SECTION 3b
    keys = ["age", "gender", "pension_id"]
    pool_cells = pool[keys].drop_duplicates()
    mc = targets[keys].merge(pool_cells, on=keys, how="left", indicator=True)
    missing_cells = mc[mc["_merge"] == "left_only"][keys]
    if len(missing_cells) > 0:
        donors = nearest_age_donors(missing_cells, pool_cells, within=["gender", "pension_id"])
        unmatched = donors[donors["donor_age"].isna()][["target_age", "gender", "pension_id"]]
        donors = donors[donors["donor_age"].notna()].assign(donor_gender=lambda d: d["gender"])
        if len(unmatched) > 0:
            # Pass 2 (same pension type, nearest age in either gender). Duncan's code keeps
            # `pension_id == donor_gender` and joins on the target gender, which returns no
            # rows; this port does what the comment says it intends.
            allc = pool_cells.rename(columns={"age": "donor_age", "gender": "donor_gender"})
            x = unmatched.merge(allc, on="pension_id", how="inner")
            x["_diff"] = (x["target_age"] - x["donor_age"]).abs()
            x = x.sort_values(["target_age", "gender", "pension_id", "_diff", "donor_age"], kind="mergesort")
            x = x.groupby(["target_age", "gender", "pension_id"], sort=False).head(1).drop(columns="_diff")
            donors = pd.concat([donors, x], ignore_index=True)
        imputed = donors.merge(pool.rename(columns={"age": "donor_age", "gender": "donor_gender"}),
                               on=["donor_age", "donor_gender", "pension_id"], how="inner")
        imputed = imputed.drop(columns=["donor_age", "donor_gender"]).rename(columns={"target_age": "age"})[pool.columns]
        pool = pd.concat([pool, imputed], ignore_index=True)
        report(f"  {len(missing_cells)} target cells absent from the pool; {len(imputed):,} donor rows copied "
               f"({len(unmatched)} cells needed the opposite-gender fallback)")

    # ------------------------------------------------------------------ SECTION 4
    pool = pool.merge(targets, on=keys, how="inner").merge(cur_agg, on=keys, how="left")
    samp = sample_to_target(pool, keys, "target_num", rng)
    samp["new_id"] = np.arange(1, len(samp) + 1)
    samp_pen = samp.groupby(keys, sort=False)["pension_benefit"].transform("mean")
    samp["pension_benefit"] = samp["pension_benefit"] * (samp["target_pen"] / samp_pen)
    report(f"  sampled {len(samp):,} pensioners")

    # ------------------------------------------------------------------ SECTION 5
    samp["id"] = samp["new_id"]
    samp["weight"] = 1.0 / sample_fraction
    out = samp[["age", "gender", "pension_id", "pension_benefit", "id", "startyear", "pension_class",
                "pension_type", "weight"]].sort_values(["pension_id", "age", "gender", "id"], kind="mergesort")
    out = out.reset_index(drop=True)
    write_dta(out, output_file, value_labels={"pension_id": PENSION_LABELS,
                                             "pension_class": {1: "DB", 2: "DC"},
                                             "pension_type": {1: "Old-age", 2: "Disability", 3: "Survivor"}})
    report(f"Synthetic pensioner dataset saved to: {output_file}  |  observations {len(out):,}")

    # ------------------------------------------------------------------ SECTION 6: verification
    syn = (out.groupby(keys, as_index=False)
           .agg(synthetic_num=("id", "size"), synthetic_pen=("pension_benefit", "mean")))
    chk = syn.merge(targets, on=keys, how="left")
    chk["diff_num_pct"] = pct_diff(chk["synthetic_num"], chk["target_num"])
    chk["diff_pen_pct"] = pct_diff(chk["synthetic_pen"], chk["target_pen"])
    print("\n=== VERIFICATION: % deviation from targets, by pension type ===")
    for pid, g in chk.groupby("pension_id"):
        summarize(g, ["diff_num_pct", "diff_pen_pct"], f"pension_id {pid} = {PENSION_LABELS.get(pid, pid)}")
    flag = chk[chk["diff_pen_pct"].abs() > 1]
    print(f"\nCells with benefit deviation above 1%: {len(flag)}")
    if len(flag):
        with pd.option_context("display.float_format", "{:9.2f}".format, "display.width", 160):
            print(flag[["pension_id", "age", "gender", "diff_num_pct", "diff_pen_pct"]].to_string(index=False))
    chk.to_csv(outdir / f"verification_pensioners_{sample_name}pct.csv", index=False)
    report("done")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default="config_MEX.json")
    main(ap.parse_args().config)
