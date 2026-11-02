"""
run_step1.py
Runs the three "00" steps in order for one country configuration:
  1. s00_synthetic_baseyear.py     monthly synthetic affiliates + weights
  2. s00_synthetic_pensioners.py   synthetic pensioners
  3. s00_monthly_to_annual.py      annual version of the affiliates file

Usage:  python run_step1.py --config config_MEX.json
"""
import argparse
import subprocess
import sys
from pathlib import Path

here = Path(__file__).resolve().parent
ap = argparse.ArgumentParser()
ap.add_argument("--config", default="config_MEX.json")
args = ap.parse_args()

for script in ["s00_synthetic_baseyear.py", "s00_synthetic_pensioners.py", "s00_monthly_to_annual.py"]:
    print(f"\n{'=' * 100}\n{script}\n{'=' * 100}", flush=True)
    r = subprocess.run([sys.executable, str(here / script), "--config", args.config])
    if r.returncode != 0:
        sys.exit(f"{script} failed (exit code {r.returncode})")
print("\nStep 1 complete.")
