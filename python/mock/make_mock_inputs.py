"""
make_mock_inputs.py
Builds small fake input files with the structure the three "00" scripts expect,
so the Python ports can be tested without the real (confidential) IMSS data.

Files written to <outdir>:
  baseyear_data_MEX.dta      monthly microdata, 12 rows per person, year 2020
  001-Data Aggregates.dta    targets by age x gender (affiliates + pensioners)
  pensioners_MEX.dta         pensioner microdata
  wage_growth_MEX.csv        iso3, year, wage_growth, cpi (percent)

The numbers are invented. They only serve to exercise every branch of the code
(cells with target above and below the pool, target cells absent from the pool,
cells without non-contributors, etc.).
"""
import sys
from pathlib import Path

import numpy as np
import pandas as pd

outdir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("input")
outdir.mkdir(parents=True, exist_ok=True)
rng = np.random.default_rng(7)

YEAR = 2020
N = 4000

# ---------------------------------------------------------------- baseyear (monthly)
age = rng.integers(16, 66, N)                      # pool covers 16-65 only (targets go to 75)
gender = rng.choice([1, 2], N, p=[0.6, 0.4])
yob = YEAR - age
# contribution pattern: a persistent monthly 0/1 series
p_work = np.clip(rng.beta(2, 1.2, N), 0, 1)
never = rng.random(N) < 0.12                        # 12% never contribute in the base year
rows = []
for i in range(N):
    dens = (rng.random(12) < p_work[i]).astype(int)
    if never[i]:
        dens[:] = 0
    rows.append(dens)
dens = np.vstack(rows)                              # N x 12

base_wage = np.exp(rng.normal(np.log(9000), 0.6, N)) * (1 + 0.01 * (age - 16))
wage = np.where(dens == 1, base_wage[:, None] * rng.lognormal(0, 0.05, (N, 12)), np.nan)

# length of service (months) and affiliation (months): cumulative, loa >= los
loa0 = np.maximum((age - rng.integers(16, 28, N)) * 12 * rng.uniform(0.5, 1.0, N), 0).round()
los0 = (loa0 * rng.uniform(0.3, 1.0, N)).round()
loa = loa0[:, None] + np.arange(1, 13)[None, :]
los = los0[:, None] + np.cumsum(dens, axis=1)
# individual account balance: grows with contributions
iacc = (los0[:, None] * base_wage[:, None] * 0.065) + np.cumsum(dens * np.nan_to_num(wage) * 0.065, axis=1)
iacc = np.where(never[:, None], 0, iacc)

# spell length: length of the run of equal dens the month belongs to (within the year, as a proxy)
spell = np.zeros((N, 12), dtype=int)
for i in range(N):
    d = dens[i]
    j = 0
    while j < 12:
        k = j
        while k + 1 < 12 and d[k + 1] == d[j]:
            k += 1
        spell[i, j:k + 1] = k - j + 1
        j = k + 1

# relative wage, carried forward; people who never had a wage in their history: missing
mean_wage = np.nanmean(wage)
wrm = wage / mean_wage
wrm = pd.DataFrame(wrm).ffill(axis=1).to_numpy()
hist_rel = np.exp(rng.normal(0, 0.5, N))           # last known relative wage before 2020
wrm = np.where(np.isnan(wrm), hist_rel[:, None], wrm)
no_history = never & (rng.random(N) < 0.3)          # some never-contributors have no wage history at all
wrm = np.where(no_history[:, None], np.nan, wrm)

dec_ref = pd.qcut(np.where(np.isnan(wrm[:, 11]), np.nan, wrm[:, 11]), 10, labels=False) + 1
dec_ref = np.where(np.isnan(dec_ref), np.nan, dec_ref)

df = pd.DataFrame({
    "id": np.repeat(np.arange(1, N + 1), 12),
    "year": YEAR,
    "month": np.tile(np.arange(1, 13), N),
    "yob": np.repeat(yob, 12),
    "age": np.repeat(age, 12),
    "gender": np.repeat(gender, 12),
    "dens": dens.ravel(),
    "wage": wage.ravel(),
    "iacc": iacc.ravel(),
    "los": los.ravel().astype(float),
    "loa": loa.ravel().astype(float),
    "spell_length": spell.ravel(),
    "wage_relative_mean": wrm.ravel(),
    "wage_decile_ref": np.repeat(dec_ref, 12),
})
df["wage_decile"] = np.where(df["dens"] == 0, 0, df["wage_decile_ref"])
# decile within year x age x gender (any definition is fine for a mock)
df["wage_decile_age_sex"] = df.groupby(["year", "age", "gender"])["wage_relative_mean"].transform(
    lambda s: pd.qcut(s.rank(method="first"), 10, labels=False, duplicates="drop") + 1 if s.notna().sum() >= 10 else np.nan)
df["status"] = 1
df["penson_class"] = 2        # the typo is in Duncan's 01 script; kept so the port sees the same columns
df = df.sort_values(["id", "month"]).reset_index(drop=True)
df.to_stata(outdir / "baseyear_data_MEX.dta", write_index=False, version=118)

# ---------------------------------------------------------------- aggregates
ever = dens.max(axis=1)
pool = pd.DataFrame({"age": age, "gender": gender, "ever": ever,
                     "w": np.nanmean(wage, axis=1), "iacc": iacc[:, 11]})
cell = pool.groupby(["age", "gender"]).agg(n=("ever", "size"), contr=("ever", "sum"),
                                           w=("w", "mean"), iacc=("iacc", "mean")).reset_index()
ages = np.arange(16, 76)
agg = pd.MultiIndex.from_product([ages, [1, 2]], names=["age", "gender"]).to_frame(index=False)
agg = agg.merge(cell, on=["age", "gender"], how="left")
# targets: full-population counts (the 10% sample of them is sometimes above, sometimes below the pool)
scale = rng.uniform(4, 16, len(agg))
agg["numA"] = (agg["n"].fillna(30) * scale).round()
share_contr = (agg["contr"] / agg["n"]).fillna(0.6).clip(0.05, 0.98)
contributors = (agg["numA"] * share_contr).round()
db_share = np.clip(0.05 + 0.012 * (agg["age"] - 16), 0, 0.95)       # DB share rises with age
agg["contrT"] = (contributors * db_share).round()
agg["contrA"] = contributors - agg["contrT"]
agg["wage"] = (agg["w"].fillna(agg["w"].mean()) * rng.uniform(0.9, 1.15, len(agg))).round(2)
agg["iacc"] = (agg["iacc"].fillna(agg["iacc"].mean()) * rng.uniform(0.8, 1.3, len(agg))).round(2)
# a few cells with no non-contributors in the pool but a non-contributor target are created naturally;
# also make one cell with numA = 0 and one with contributors = numA
agg.loc[(agg["age"] == 16) & (agg["gender"] == 2), ["numA", "contrA", "contrT"]] = 0
# pensioner targets by age x gender for types B..G
for t, lo, pen in [("B", 60, 6000), ("C", 25, 4500), ("D", 20, 3500), ("E", 60, 5000), ("F", 25, 4000), ("G", 20, 3000)]:
    on = (agg["age"] >= lo)
    agg[f"num{t}"] = np.where(on, (rng.uniform(50, 400, len(agg)) * (1 + 0.05 * (agg["age"] - lo))).round(), 0)
    agg[f"pen{t}"] = np.where(on, (pen * rng.uniform(0.8, 1.3, len(agg))).round(2), np.nan)
agg = agg.drop(columns=["n", "contr", "w"])
agg["age"] = agg["age"].astype(int)
agg.to_stata(outdir / "001-Data Aggregates.dta", write_index=False, version=118)

# ---------------------------------------------------------------- pensioners microdata
M = 6000
p_age = rng.integers(20, 92, M)
p_gender = rng.choice([1, 2], M)
p_type = rng.choice([1, 2, 3, 4, 5, 6], M, p=[0.35, 0.1, 0.15, 0.2, 0.1, 0.1])
old_age = np.isin(p_type, [1, 4])
p_age = np.where(old_age, np.maximum(p_age, 60), p_age)
# leave type-G women out entirely to exercise the opposite-gender fallback (same pension type)
drop = (p_type == 6) & (p_gender == 2)
p_age, p_gender, p_type = p_age[~drop], p_gender[~drop], p_type[~drop]
M = len(p_age)
benefit = np.exp(rng.normal(np.log(5000), 0.5, M))
pens = pd.DataFrame({
    "age": p_age, "gender": p_gender, "pension_id": p_type,
    "pension_class": np.where(p_type <= 3, 1, 2),
    "pension_type": np.where(np.isin(p_type, [1, 4]), 1, np.where(np.isin(p_type, [2, 5]), 2, 3)),
    "pension_benefit": benefit.round(2),
    "startyear": YEAR - rng.integers(0, 25, M),
})
pens.to_stata(outdir / "pensioners_MEX.dta", write_index=False, version=118)

# ---------------------------------------------------------------- wage growth
years = np.arange(2019, 2101)
wg = pd.DataFrame({"iso3": "MEX", "year": years,
                   "wage_growth": np.where(years <= 2024, [6.0, 4.5, 7.0, 9.5, 8.0, 6.5][:len(years)] + [0] * max(0, len(years) - 6), 5.5)[:len(years)],
                   "cpi": np.where(years <= 2024, [2.8, 3.2, 5.7, 7.9, 5.5, 4.7][:len(years)] + [0] * max(0, len(years) - 6), 3.5)[:len(years)]})
wg.loc[wg["year"] > 2024, "wage_growth"] = 5.5
wg.loc[wg["year"] > 2024, "cpi"] = 3.5
wg["anchor"] = 0.0
wg.to_csv(outdir / "wage_growth_MEX.csv", index=False)

print("mock inputs written to", outdir.resolve())
print(df.shape, agg.shape, pens.shape, wg.shape)
