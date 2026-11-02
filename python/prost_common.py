"""
prost_common.py
Shared helpers for the Python port of Duncan MacDonald's PROST v2 Stata pipeline.

The helpers reproduce Stata semantics where pandas/numpy differ:
  - round(): Stata rounds half away from zero; numpy rounds half to even.
  - min()/max(): Stata ignores missing arguments; numpy propagates NaN
    (np.fmin / np.fmax ignore NaN, so they are used here).
  - xtile / gquantiles: Stata's default percentile definition is not the one
    pandas.qcut uses (linear interpolation). stata_xtile() implements Stata's.
  - carryforward: pandas ffill.
  - egen mean/max: pandas groupby.transform (skips NaN like Stata).
"""

from __future__ import annotations

import math
import time
from pathlib import Path

import numpy as np
import pandas as pd


# ---------------------------------------------------------------------------
# Stata function semantics
# ---------------------------------------------------------------------------

def stata_round(x):
    """Stata round(x): nearest integer, halves away from zero. NaN stays NaN."""
    x = np.asarray(x, dtype="float64")
    out = np.sign(x) * np.floor(np.abs(x) + 0.5)
    return out


def stata_min(a, b):
    """Stata min(a, b): ignores missing arguments (np.fmin does the same)."""
    return np.fmin(np.asarray(a, dtype="float64"), np.asarray(b, dtype="float64"))


def stata_max(a, b):
    """Stata max(a, b): ignores missing arguments (np.fmax does the same)."""
    return np.fmax(np.asarray(a, dtype="float64"), np.asarray(b, dtype="float64"))


def stata_pctile_cutoffs(values: np.ndarray, nq: int) -> np.ndarray:
    """
    Quantile cutoffs with Stata's default definition (pctile / xtile / gquantiles
    without altdef). For p = j/nq, with n non-missing sorted values x[1..n]:
      R = n * p;  if R is an integer: q = (x[R] + x[R+1]) / 2
                  else:               q = x[ceil(R)]
    Returns nq-1 cutoffs.
    """
    v = np.sort(values[~np.isnan(values)])
    n = v.size
    cut = np.full(nq - 1, np.nan)
    if n == 0:
        return cut
    for j in range(1, nq):
        R = n * j / nq
        R_int = int(round(R))
        if abs(R - R_int) < 1e-9:
            # integer: average of the R-th and (R+1)-th order statistics (1-indexed)
            lo = v[min(R_int, n) - 1]
            hi = v[min(R_int + 1, n) - 1]
            cut[j - 1] = (lo + hi) / 2
        else:
            cut[j - 1] = v[min(int(math.ceil(R)), n) - 1]
    return cut


def stata_xtile(series: pd.Series, nq: int, by: list[str] | None = None,
                frame: pd.DataFrame | None = None) -> pd.Series:
    """
    Stata xtile(nquantiles=nq) [by(...)]: category j when q_{j-1} < x <= q_j
    (category 1 for x <= q_1, category nq for x > q_{nq-1}). Missing -> missing.
    """
    out = pd.Series(np.nan, index=series.index, dtype="float64")
    vals = series.to_numpy(dtype="float64")
    if by:
        groups = frame.groupby(by, sort=False, dropna=False).indices
        for _, idx in groups.items():
            v = vals[idx]
            cut = stata_pctile_cutoffs(v, nq)
            if np.all(np.isnan(cut)):
                continue
            cat = np.searchsorted(cut, v, side="left") + 1.0   # number of cutoffs < x, plus 1
            cat[np.isnan(v)] = np.nan
            out.iloc[idx] = cat
    else:
        cut = stata_pctile_cutoffs(vals, nq)
        cat = np.searchsorted(cut, vals, side="left") + 1.0
        cat[np.isnan(vals)] = np.nan
        out[:] = cat
    return out


# ---------------------------------------------------------------------------
# Rebasing index from the wage growth file (Section 0 of the 00 scripts)
# ---------------------------------------------------------------------------

def rebasing_indices(wage_growth_csv: Path, country: str, data_year: int,
                     base_year: int) -> tuple[float, float]:
    """
    Cumulative nominal wage index and CPI index between data_year and base_year,
    from a CSV with columns iso3, year, wage_growth, cpi (both in percent).
    Mirrors:  keep if iso3==country & inrange(year, data_year+1, base_year)
              assert _N == base_year - data_year
              wage_index = exp(sum(ln(1 + wage_growth/100)))  (same for cpi)
    """
    wg = pd.read_csv(wage_growth_csv)
    wg.columns = [c.strip().lower() for c in wg.columns]
    sel = wg[(wg["iso3"] == country) & (wg["year"] >= data_year + 1) & (wg["year"] <= base_year)]
    n_expected = base_year - data_year
    if len(sel) != n_expected:
        raise ValueError(
            f"wage growth file: expected {n_expected} rows for {country} in "
            f"{data_year + 1}-{base_year}, found {len(sel)}"
        )
    wage_index = float(np.exp(np.log1p(sel["wage_growth"].to_numpy(dtype='float64') / 100).sum()))
    cpi_index = float(np.exp(np.log1p(sel["cpi"].to_numpy(dtype='float64') / 100).sum()))
    return wage_index, cpi_index


# ---------------------------------------------------------------------------
# Cell sampling: shuffle + sample down, expand up, trim  (Step 4a of 00 scripts)
# ---------------------------------------------------------------------------

def sample_to_target(df: pd.DataFrame, cell_keys: list[str], target_col: str,
                     rng: np.random.Generator) -> pd.DataFrame:
    """
    Reproduces Duncan's three-step cell sampling:
      (1) generate _u = runiform(); sort cell _u; by cell: keep if _n <= target
      (2) _rep = max(ceil(target / cell_n), 1); expand _rep
      (3) sort cell _u; by cell: keep if _n <= target; drop _u
    Within a cell the rows are ordered by a uniform draw; a row's clones are
    adjacent in that order, and the first `target` rows are kept. So when the
    target exceeds the cell size, the rows with the lowest draws get all their
    clones and the rows with the highest draws can get none, exactly as in Stata.
    The random draws themselves are numpy's, not Stata's, so the selected rows
    differ from a Stata run; the cell counts are identical by construction.
    """
    if df.empty:
        return df.copy()
    df = df.copy()
    df["_u"] = rng.random(len(df))
    df = df.sort_values(cell_keys + ["_u"], kind="mergesort").reset_index(drop=True)

    # step 1: keep the first `target` rows of each cell
    pos = df.groupby(cell_keys, sort=False).cumcount()
    tgt = df[target_col].to_numpy(dtype="float64")
    df = df[pos.to_numpy() < tgt].reset_index(drop=True)
    if df.empty:
        return df.drop(columns="_u")

    # step 2: expand so that each cell reaches its target
    cell_n = df.groupby(cell_keys, sort=False)[target_col].transform("size").to_numpy(dtype="float64")
    tgt = df[target_col].to_numpy(dtype="float64")
    rep = np.maximum(np.ceil(tgt / np.maximum(cell_n, 1)), 1).astype("int64")
    df = df.loc[np.repeat(df.index.to_numpy(), rep)].reset_index(drop=True)

    # step 3: trim to exactly `target` rows per cell (rows are still ordered by cell, _u)
    pos = df.groupby(cell_keys, sort=False).cumcount()
    tgt = df[target_col].to_numpy(dtype="float64")
    df = df[pos.to_numpy() < tgt].reset_index(drop=True)
    return df.drop(columns="_u")


# ---------------------------------------------------------------------------
# Nearest-age donors for target cells that have no observations in the pool
# (Section 3b of the 00 scripts)
# ---------------------------------------------------------------------------

def nearest_age_donors(missing_cells: pd.DataFrame, pool_cells: pd.DataFrame,
                       within: list[str], age_col: str = "age") -> pd.DataFrame:
    """
    For each missing target cell, the pool cell with the nearest age among the
    pool cells that share the `within` keys (ties -> the younger donor age, as in
    `bysort target_age ... (_diff age): keep if _n == 1`).
    Returns missing_cells columns plus donor_age. Cells with no donor within the
    `within` keys are returned with donor_age = NaN (the caller handles fallback).
    """
    m = missing_cells.rename(columns={age_col: "target_age"})
    if m.empty:
        m["donor_age"] = np.nan
        return m
    j = m.merge(pool_cells[within + [age_col]].drop_duplicates(), on=within, how="left")
    j["_diff"] = (j["target_age"] - j[age_col]).abs()
    j = j.sort_values(["target_age"] + within + ["_diff", age_col], kind="mergesort")
    j = j.groupby(["target_age"] + within, sort=False, dropna=False).head(1)
    j = j.rename(columns={age_col: "donor_age"}).drop(columns="_diff")
    return j.reset_index(drop=True)


# ---------------------------------------------------------------------------
# I/O
# ---------------------------------------------------------------------------

def read_dta(path: Path) -> pd.DataFrame:
    """Read a Stata file keeping labeled variables numeric (like Stata itself)."""
    return pd.read_stata(path, convert_categoricals=False, preserve_dtypes=True)


def write_dta(df: pd.DataFrame, path: Path, value_labels: dict | None = None,
              variable_labels: dict | None = None) -> None:
    """Write a Stata file (format 118). Object columns are cast to str."""
    out = df.copy()
    for c in out.columns:
        if out[c].dtype == "bool":
            out[c] = out[c].astype("int8")
        elif out[c].dtype == "object" or str(out[c].dtype).startswith("str"):
            out[c] = out[c].astype(str)
    kw = {"write_index": False, "version": 118}
    if value_labels:
        kw["value_labels"] = value_labels
    if variable_labels:
        kw["variable_labels"] = variable_labels
    out.to_stata(path, **kw)


def report(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def pct_diff(a, b):
    a = np.asarray(a, dtype="float64")
    b = np.asarray(b, dtype="float64")
    with np.errstate(divide="ignore", invalid="ignore"):
        return 100.0 * (a - b) / b


def summarize(df: pd.DataFrame, cols: list[str], title: str) -> None:
    """Approximates Stata's `summarize varlist, format` output."""
    print(f"\n=== {title} ===")
    rows = []
    for c in cols:
        s = pd.to_numeric(df[c], errors="coerce")
        s = s[np.isfinite(s)]
        rows.append({"variable": c, "N": int(s.size),
                     "mean": s.mean() if s.size else np.nan,
                     "sd": s.std(ddof=1) if s.size > 1 else np.nan,
                     "min": s.min() if s.size else np.nan,
                     "max": s.max() if s.size else np.nan})
    with pd.option_context("display.float_format", "{:10.4f}".format, "display.width", 140):
        print(pd.DataFrame(rows).to_string(index=False))
