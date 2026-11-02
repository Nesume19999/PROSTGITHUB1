"""
s00_synthetic_baseyear.py
Python port of Duncan MacDonald's
  "00 - Generate synthetic baseyear from aggregates.do"  (current version, not "Old")

Samples individuals from the base-year monthly microdata and rescales wages and
individual account balances so that, in every age x gender cell, the synthetic
data match the target aggregates: number of affiliates (numA), DC contributors
(contrA), DB contributors (contrT), average monthly wage (wage) and average
individual account balance (iacc). Targets are rebased from the year of the data
to the base year of the projection.

Inputs (see config_<ISO3>.json):
  <indir>/<baseyear_data>   monthly microdata, 12 rows per person
  <indir>/<aggregates>      targets by age x gender
  <indir>/<wage_growth>     iso3, year, wage_growth, cpi (percent)
Outputs:
  <outdir>/synthetic_affiliates_<N>pct_sample.dta
  <outdir>/synthetic_weights_<N>pct_sample.dta

Usage:  python s00_synthetic_baseyear.py --config config_MEX.json

Section numbers in the comments refer to Duncan's do-file. Stata semantics that
differ from numpy are reproduced through prost_common (round, min/max with
missing values, joinby keeping the master values of common variables).
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd

from prost_common import (nearest_age_donors, pct_diff, read_dta, rebasing_indices,
                          report, sample_to_target, stata_max, stata_min,
                          stata_round, summarize, write_dta)


def main(config_path: str) -> None:
    cfg = json.loads(Path(config_path).read_text(encoding="utf-8"))
    country = cfg["country"]
    indir = Path(cfg["paths"]["indir"])
    outdir = Path(cfg["paths"]["outdir"])
    outdir.mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------------ SECTION 0
    sample_fraction = float(cfg["sample_fraction"])
    sample_name = int(stata_round(100 * sample_fraction))
    seed = int(cfg["seed"])
    rng = np.random.default_rng(seed)

    rb = cfg["rebase"]
    data_year = int(rb["data_year"])
    pre = cfg["service_credit_before_records"]
    male = cfg["gender_codes"]["male"]

    output_file = outdir / f"synthetic_affiliates_{sample_name}pct_sample.dta"
    weight_file = outdir / f"synthetic_weights_{sample_name}pct_sample.dta"

    wage_index, cpi_index = 1.0, 1.0
    if int(rb["enabled"]) == 1:
        wage_index, cpi_index = rebasing_indices(indir / cfg["files"]["wage_growth"], country,
                                                 data_year, int(rb["base_year"]))
        report(f"Rebasing {data_year} to {rb['base_year']}: wage index = {wage_index:.4f} | CPI index = {cpi_index:.4f}")

    # ------------------------------------------------------------------ SECTION 1
    # Individual-level pool from the monthly base-year file
    report(f"Reading {cfg['files']['baseyear_data']}")
    m = read_dta(indir / cfg["files"]["baseyear_data"])
    needed = ["id", "age", "gender", "month", "dens", "wage", "iacc", "los", "loa", "wage_relative_mean"]
    missing_cols = [c for c in needed if c not in m.columns]
    if missing_cols:
        raise ValueError(f"baseyear file lacks columns: {missing_cols}")
    report(f"  {len(m):,} rows, {m['id'].nunique():,} persons")

    # data checks the Stata code assumes silently
    n_wage_nowork = int(((m["dens"] == 0) & m["wage"].notna()).sum())
    if n_wage_nowork:
        report(f"  NOTE: {n_wage_nowork:,} rows have dens == 0 and a non-missing wage; "
               f"Stata's mean(wage) includes them, and so does this port")

    g = m.groupby("id", sort=False)
    m["ever_contr"] = g["dens"].transform("max")                                   # 1 if contributed any month
    m["avg_wage_ind"] = g["wage"].transform("mean")                                # mean wage while contributing
    m["_iacc_dec"] = m["iacc"] * (m["month"] == 12)
    m["iacc_dec_ind"] = m.groupby("id", sort=False)["_iacc_dec"].transform("max")  # December balance
    m = m.drop(columns="_iacc_dec")

    # Reference wage: relative wage x average wage, bounded by the observed min and max of avg_wage_ind.
    # Stata's min()/max() ignore missing arguments: a person with no wage history at all
    # (wage_relative_mean missing) gets reference_wage = max_wage. Reproduced here (np.fmin/np.fmax)
    # and counted below so it can be raised with Duncan.
    s = m["avg_wage_ind"]
    avg_wage, min_wage, max_wage = float(s.mean()), float(s.min()), float(s.max())
    m["reference_wage"] = stata_max(stata_min(m["wage_relative_mean"] * avg_wage, max_wage), min_wage)
    m["reference_wage"] = np.where(m["wage"].notna(), m["wage"], m["reference_wage"])
    n_nohist = int(m.loc[m["month"] == 12, "wage_relative_mean"].isna().sum())
    if n_nohist:
        report(f"  NOTE: {n_nohist:,} persons have no wage history (wage_relative_mean missing); "
               f"as in Stata their reference_wage is set to the maximum average wage ({max_wage:,.2f})")

    # monthly_full: the monthly rows without age and gender (they come back from the sampled individuals)
    monthly_full = m.drop(columns=["age", "gender"]).sort_values(["id", "month"], kind="mergesort")

    # one row per person (December), with affiliation and service at the end of the data year
    pool = m[m["month"] == 12].rename(columns={"loa": "loa_dec", "los": "los_dec"})
    pool = pool[["id", "age", "gender", "ever_contr", "avg_wage_ind", "iacc_dec_ind",
                 "reference_wage", "loa_dec", "los_dec"]].reset_index(drop=True)
    n_no_dec = m["id"].nunique() - len(pool)
    if n_no_dec:
        report(f"  NOTE: {n_no_dec:,} persons have no December row and are not in the pool (as in Stata)")

    # ------------------------------------------------------------------ SECTION 2
    cur_agg = (pool.groupby(["age", "gender"], as_index=False)
               .agg(current_affiliates=("id", "size"), current_contributors=("ever_contr", "sum"),
                    current_wage=("avg_wage_ind", "mean"), current_iacc=("iacc_dec_ind", "mean")))

    # ------------------------------------------------------------------ SECTION 3
    report(f"Reading {cfg['files']['aggregates']}")
    agg = read_dta(indir / cfg["files"]["aggregates"])
    t = agg[["age", "gender", "numA", "contrA", "contrT", "wage", "iacc"]].rename(columns={
        "numA": "target_affiliates", "contrA": "target_contrA", "contrT": "target_contrT",
        "wage": "target_wage", "iacc": "target_iacc"}).copy()
    t = t[t["target_affiliates"].notna() & (t["target_affiliates"] != 0)].reset_index(drop=True)

    if sample_fraction < 1:
        # Stata's max()/min() ignore missing arguments: a missing contrA/contrT target becomes 0
        t["target_affiliates"] = stata_max(1, stata_round(t["target_affiliates"] * sample_fraction))
        t["target_contrA"] = stata_max(0, stata_round(t["target_contrA"] * sample_fraction))
        t["target_contrT"] = stata_max(0, stata_round(t["target_contrT"] * sample_fraction))
        t["target_contrA"] = stata_min(t["target_contrA"], t["target_affiliates"])
        t["target_contrT"] = stata_min(t["target_contrT"], t["target_affiliates"] - t["target_contrA"])

    t["target_wage"] = t["target_wage"] * wage_index
    t["target_iacc"] = t["target_iacc"] * wage_index
    t["target_contributors"] = t["target_contrA"] + t["target_contrT"]
    targets = t
    report(f"  {len(targets)} target cells; sample targets: affiliates {int(targets['target_affiliates'].sum()):,}, "
           f"contributors {int(targets['target_contributors'].sum()):,}")

    # ------------------------------------------------------------------ SECTION 3b
    # Target cells with no observations in the pool: copy the nearest-age cell of the same gender
    pool_cells = pool[["age", "gender"]].drop_duplicates()
    missing_cells = targets[["age", "gender"]].merge(pool_cells, on=["age", "gender"], how="left", indicator=True)
    missing_cells = missing_cells[missing_cells["_merge"] == "left_only"][["age", "gender"]]
    n_missing = len(missing_cells)
    if n_missing > 0:
        donors = nearest_age_donors(missing_cells, pool_cells, within=["gender"])
        unmatched = donors[donors["donor_age"].isna()][["target_age", "gender"]]
        donors = donors[donors["donor_age"].notna()]
        if len(unmatched) > 0:
            # Pass 2: a whole gender is absent from the pool -> nearest age across both genders
            allc = pool_cells.rename(columns={"age": "donor_age", "gender": "donor_gender"})
            x = unmatched.merge(allc, how="cross")
            x["_diff"] = (x["target_age"] - x["donor_age"]).abs()
            x = x.sort_values(["target_age", "gender", "_diff", "donor_age"], kind="mergesort")
            x = x.groupby(["target_age", "gender"], sort=False).head(1).drop(columns="_diff")
            # the donor rows are pulled by donor_age and donor_gender below
            donors = pd.concat([donors.assign(donor_gender=donors["gender"]), x], ignore_index=True)
        else:
            donors = donors.assign(donor_gender=donors["gender"])
        imputed = donors.merge(pool.rename(columns={"age": "donor_age", "gender": "donor_gender"}),
                               on=["donor_age", "donor_gender"], how="inner")
        imputed = imputed.drop(columns=["donor_age", "donor_gender"]).rename(columns={"target_age": "age"})
        imputed = imputed[pool.columns]
        pool = pd.concat([pool, imputed], ignore_index=True)
        report(f"  {n_missing} target cells absent from the pool; {len(imputed):,} donor rows copied "
               f"({len(unmatched)} cells needed the opposite-gender fallback)")

    # ------------------------------------------------------------------ SECTION 4
    pool = pool.merge(targets, on=["age", "gender"], how="inner")
    pool = pool.merge(cur_agg, on=["age", "gender"], how="left")
    pool["target_noncontr"] = pool["target_affiliates"] - pool["target_contributors"]

    # Step 4a: contributors and non-contributors are sampled separately
    contr = pool[pool["ever_contr"] == 1]
    sampled_contr = sample_to_target(contr, ["age", "gender"], "target_contributors", rng)

    has_noncontr = (pool["ever_contr"] == 0).astype("int8").groupby([pool["age"], pool["gender"]]).transform("max")
    need_synthetic = (pool["target_noncontr"] > 0) & (has_noncontr == 0) & (pool["ever_contr"] == 1)
    synthetic_noncontr = pool[need_synthetic].copy()
    synthetic_noncontr["ever_contr"] = 0
    synthetic_noncontr["avg_wage_ind"] = np.nan
    synthetic_noncontr["iacc_dec_ind"] = 0.0

    noncontr = pool[(pool["ever_contr"] == 0) & (pool["target_noncontr"] > 0)]
    noncontr = pd.concat([noncontr, synthetic_noncontr], ignore_index=True)
    sampled_noncontr = sample_to_target(noncontr, ["age", "gender"], "target_noncontr", rng)
    report(f"  sampled {len(sampled_contr):,} contributors and {len(sampled_noncontr):,} non-contributors "
           f"({len(synthetic_noncontr):,} contributor rows re-labelled for cells without non-contributors)")

    samp = pd.concat([sampled_noncontr, sampled_contr], ignore_index=True)   # same order as Stata's append
    samp["new_id"] = np.arange(1, len(samp) + 1)

    # Step 4b: one multiplier per cell so the cell mean equals the target
    gc = samp.groupby(["age", "gender"], sort=False)
    samp_wage = gc["avg_wage_ind"].transform("mean")                              # contributor mean (NaN for others)
    samp["_iacc_contr"] = np.where(samp["ever_contr"] == 1, samp["iacc_dec_ind"], np.nan)
    samp_iacc = samp.groupby(["age", "gender"], sort=False)["_iacc_contr"].transform("mean")
    samp = samp.drop(columns="_iacc_contr")
    samp["_scale_wage"] = (samp["target_wage"] / samp_wage).fillna(1.0)
    samp["_scale_iacc"] = (samp["target_iacc"] / samp_iacc).fillna(1.0)
    is_c = samp["ever_contr"] == 1
    samp.loc[is_c, "avg_wage_ind"] = samp.loc[is_c, "avg_wage_ind"] * samp.loc[is_c, "_scale_wage"]
    samp.loc[~is_c, "reference_wage"] = samp.loc[~is_c, "reference_wage"] * samp.loc[~is_c, "_scale_wage"]
    samp["iacc_dec_ind"] = samp["iacc_dec_ind"] * samp["_scale_iacc"]

    # Step 4c: DB/DC class. With the credit on, DB goes to the longest observed affiliation.
    samp["_u2"] = rng.random(len(samp))
    samp["_score"] = (-samp["loa_dec"]).fillna(0.0) if int(pre["enabled"]) == 1 else 0.0
    samp = samp.sort_values(["age", "gender", "ever_contr", "_score", "_u2"], kind="mergesort").reset_index(drop=True)
    grp = samp.groupby(["age", "gender", "ever_contr"], sort=False)
    samp["_rank"] = grp.cumcount() + 1
    samp["_ncell"] = grp["new_id"].transform("size")
    cA = stata_round(samp["target_contrA"])
    cT = stata_round(samp["target_contrT"])
    samp["pension_class"] = np.nan
    c1 = (samp["ever_contr"] == 1) & (samp["_rank"] <= cT)
    c2 = (samp["ever_contr"] == 1) & (samp["_rank"] > cT) & (samp["_rank"] <= cT + cA)
    samp.loc[c1, "pension_class"] = 1   # DB
    samp.loc[c2, "pension_class"] = 2   # DC
    db_share = (samp["target_contrT"] / samp["target_contributors"]).fillna(0.0)
    n_db_nc = stata_round(samp["_ncell"] * db_share)
    n1 = (samp["ever_contr"] == 0) & (samp["_rank"] <= n_db_nc)
    n2 = (samp["ever_contr"] == 0) & (samp["_rank"] > n_db_nc)
    samp.loc[n1, "pension_class"] = 1
    samp.loc[n2, "pension_class"] = 2
    samp = samp.drop(columns=["_u2", "_score", "_rank", "_ncell", "target_noncontr"])

    # Step 4c-bis: affiliation and service before the start of the records (DB class only)
    samp["los_pre97"] = 0.0
    samp["loa_pre97"] = 0.0
    if int(pre["enabled"]) == 1:
        age_at_start = samp["age"] - (data_year - int(pre["records_start_year"])) - float(pre["records_start_fraction_of_year"])
        u = rng.random(len(samp))
        start_m = pre["start_min_m"] + (pre["start_max_m"] - pre["start_min_m"]) * u
        start_f = pre["start_min_f"] + (pre["start_max_f"] - pre["start_min_f"]) * u
        start = np.where(samp["gender"] == male, start_m, start_f)
        dens_obs = np.where(samp["loa_dec"] > 0, stata_min(samp["los_dec"] / samp["loa_dec"], 1.0), 0.0)
        dens_obs = np.nan_to_num(dens_obs, nan=0.0)
        is_db = (samp["pension_class"] == 1).to_numpy()
        loa_pre = stata_round(12 * np.maximum(age_at_start - start, 0))
        samp.loc[is_db, "loa_pre97"] = loa_pre[is_db]
        los_pre = stata_round(samp["loa_pre97"] * np.minimum(1.0, dens_obs * float(pre["density_mult"])))
        samp.loc[is_db, "los_pre97"] = los_pre[is_db]
    samp = samp.drop(columns=["loa_dec", "los_dec"])

    # Step 4d
    keep_cols = ["new_id", "id", "age", "gender", "pension_class", "ever_contr",
                 "avg_wage_ind", "iacc_dec_ind", "reference_wage",
                 "_scale_wage", "_scale_iacc", "target_wage", "target_iacc", "los_pre97", "loa_pre97",
                 "current_affiliates", "current_contributors", "current_wage", "current_iacc",
                 "target_affiliates", "target_contrA", "target_contrT", "target_contributors"]
    sampled_indiv = samp[keep_cols]

    # ------------------------------------------------------------------ SECTION 5
    # joinby id: each sampled person (clones included) gets the 12 monthly rows of the original id.
    # Stata's joinby keeps the MASTER values of variables present in both files, so
    # ever_contr, avg_wage_ind, iacc_dec_ind and reference_wage come from the sampled person
    # (rescaled, person-level December values), not from the monthly rows.
    common = [c for c in monthly_full.columns if c in sampled_indiv.columns and c != "id"]
    mon = sampled_indiv.merge(monthly_full.drop(columns=common), on="id", how="inner")
    report(f"  monthly synthetic file: {len(mon):,} rows")

    is_work = mon["dens"] == 1
    mon.loc[is_work, "wage"] = mon.loc[is_work, "wage"] * mon.loc[is_work, "_scale_wage"]
    is_c = mon["ever_contr"] == 1
    mon.loc[is_c, "reference_wage"] = mon.loc[is_c, "reference_wage"] * mon.loc[is_c, "_scale_wage"]

    # cap: reference wages above the average wage of working people of the same age, for old ages
    avg_wage_age = mon.groupby("age", sort=False)["wage"].transform("mean")
    cap = (mon["reference_wage"] > avg_wage_age) & (mon["age"] > int(cfg["reference_wage_cap"]["max_age"]))
    mon.loc[cap, "reference_wage"] = avg_wage_age[cap]

    mon.loc[mon["ever_contr"] == 0, "dens"] = 0
    mon.loc[mon["dens"] == 0, "wage"] = np.nan
    mon["iacc"] = mon["iacc"] * mon["_scale_iacc"]
    mon = mon.drop(columns=["_scale_wage", "_scale_iacc"])

    # weights: number of synthetic persons derived from each original id
    w = mon[mon["month"] == 12].groupby("id", as_index=False).agg(weight=("new_id", "count"))
    write_dta(w, weight_file)
    report(f"  weights written: {weight_file.name} ({len(w):,} original ids)")

    mon["id"] = mon["new_id"]
    mon = mon.drop(columns="new_id")

    # ------------------------------------------------------------------ SECTION 7
    mon = mon.drop(columns=[c for c in mon.columns if c.startswith("target_") or c.startswith("current_")])
    mon["weight"] = 1.0 / sample_fraction

    if int(cfg["iacc_cap"]["enabled"]) == 1:
        mon["iacc"] = stata_min(mon["iacc"], mon["los"] * mon["reference_wage"] * float(cfg["iacc_cap"]["share"]))

    mon["los"] = mon["los"] + mon["los_pre97"]
    mon["loa"] = mon["loa"] + mon["loa_pre97"]

    final_cols = ["age", "gender", "id", "pension_class", "yob", "wage", "dens", "year", "month", "loa", "los", "iacc",
                  "spell_length", "wage_decile_ref", "wage_decile", "wage_decile_age_sex",
                  "status", "weight", "reference_wage", "los_pre97", "loa_pre97"]
    absent = [c for c in final_cols if c not in mon.columns]
    if absent:
        raise ValueError(f"columns expected in the output are missing from the input data: {absent}")
    mon = mon[final_cols].sort_values(["id", "month"], kind="mergesort").reset_index(drop=True)
    n_noclass = int(mon["pension_class"].isna().sum())
    if n_noclass:
        raise RuntimeError(f"{n_noclass:,} rows have no pension_class (a cell whose contributors exceed "
                           f"target_contrA + target_contrT); check the aggregates file")
    mon["pension_class"] = mon["pension_class"].astype("int8")
    write_dta(mon, output_file, value_labels={"pension_class": {1: "DB", 2: "DC"}})
    report(f"Synthetic dataset saved to: {output_file}  |  rows {len(mon):,}  persons {len(mon) / 12:,.0f}")

    # ------------------------------------------------------------------ SECTION 8: verification
    v = mon.copy()
    gv = v.groupby("id", sort=False)
    v["_ever"] = gv["dens"].transform("max")
    v["_cA"] = (v["dens"] * (v["pension_class"] == 2)).groupby(v["id"]).transform("max")
    v["_cT"] = (v["dens"] * (v["pension_class"] == 1)).groupby(v["id"]).transform("max")
    v["_wc"] = np.where(v["dens"] == 1, v["wage"], np.nan)
    v["_avg_wage"] = v.groupby("id", sort=False)["_wc"].transform("mean")
    v["_iacc_dec"] = (v["iacc"] * (v["month"] == 12)).groupby(v["id"]).transform("max")
    v.loc[v["_ever"] == 0, "_iacc_dec"] = np.nan
    v = v[v["month"] == 12]

    if int(pre["enabled"]) == 1:
        bad = v[(v["pension_class"] == 2) & ((v["los_pre97"] != 0) | (v["loa_pre97"] != 0))]
        assert len(bad) == 0, "DC persons must have no service credit before the records"
        db = v[v["pension_class"] == 1].copy()
        bins = [-np.inf, 29, 39, 49, 54, 59, 64, np.inf]
        db["agegrp"] = pd.cut(db["age"], bins=bins, labels=["<=29", "30-39", "40-49", "50-54", "55-59", "60-64", "65+"])
        db["credit_yrs"] = db["los_pre97"] / 12
        db["loa_pre_yrs"] = db["loa_pre97"] / 12
        print("\n=== SERVICE CREDIT BEFORE THE RECORDS (years), DB-class persons by age group ===")
        tab = db.groupby("agegrp", observed=True).agg(n=("credit_yrs", "size"),
                                                      credit_mean=("credit_yrs", "mean"), credit_p50=("credit_yrs", "median"),
                                                      credit_p90=("credit_yrs", lambda s: s.quantile(0.9)),
                                                      loa_mean=("loa_pre_yrs", "mean"), loa_p50=("loa_pre_yrs", "median"),
                                                      loa_p90=("loa_pre_yrs", lambda s: s.quantile(0.9)))
        with pd.option_context("display.float_format", "{:8.2f}".format, "display.width", 140):
            print(tab.to_string())

    syn = (v.groupby(["age", "gender"], as_index=False)
           .agg(synthetic_affiliates=("id", "size"), synthetic_contrA=("_cA", "sum"), synthetic_contrT=("_cT", "sum"),
                synthetic_wage=("_avg_wage", "mean"), synthetic_iacc=("_iacc_dec", "mean")))
    chk = syn.merge(targets, on=["age", "gender"], how="left")
    chk["diff_aff_pct"] = pct_diff(chk["synthetic_affiliates"], chk["target_affiliates"])
    chk["diff_contrA_pct"] = pct_diff(chk["synthetic_contrA"], chk["target_contrA"])
    chk["diff_contrT_pct"] = pct_diff(chk["synthetic_contrT"], chk["target_contrT"])
    chk["diff_wage_pct"] = pct_diff(chk["synthetic_wage"], chk["target_wage"])
    chk["diff_iacc_pct"] = pct_diff(chk["synthetic_iacc"], chk["target_iacc"])
    summarize(chk, ["diff_aff_pct", "diff_contrA_pct", "diff_contrT_pct", "diff_wage_pct", "diff_iacc_pct"],
              "VERIFICATION: % deviation of synthetic cell statistics from targets")
    flag = chk[(chk["diff_wage_pct"].abs() > 1) | (chk["diff_iacc_pct"].abs() > 1)]
    print(f"\nCells with wage or iacc deviation above 1%: {len(flag)}")
    if len(flag):
        with pd.option_context("display.float_format", "{:9.2f}".format, "display.width", 160):
            print(flag[["age", "gender", "diff_aff_pct", "diff_contrA_pct", "diff_contrT_pct",
                        "diff_wage_pct", "diff_iacc_pct"]].to_string(index=False))
    chk.to_csv(outdir / f"verification_affiliates_{sample_name}pct.csv", index=False)
    report("done")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default="config_MEX.json")
    main(ap.parse_args().config)
