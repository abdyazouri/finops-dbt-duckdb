"""Evaluate the anomaly detector against the injected ground truth.

Usage (after `dbt build`):
    python scripts/evaluate_anomalies.py
"""
from __future__ import annotations

import sys

import duckdb

con = duckdb.connect("finops.duckdb", read_only=True)

truth = con.execute(
    "select cast(usage_date as date) as usage_date, product_code "
    "from read_csv('data/raw/injected_anomalies.csv', header=true)"
).fetchall()
flagged = con.execute(
    "select usage_date, product_code, cost, expected_cost, robust_z "
    "from mart_cost_anomalies where is_anomaly order by usage_date"
).fetchall()

truth_set = {(d, p) for d, p in truth}
flagged_set = {(d, p) for d, p, *_ in flagged}
# Only evaluate injected anomalies that the detector could have scored
# (it needs a warm-up window of history).
scorable = con.execute("select min(usage_date), max(usage_date) from mart_cost_anomalies").fetchone()
truth_scorable = {(d, p) for d, p in truth_set if scorable[0] <= d <= scorable[1]}

tp = truth_scorable & flagged_set
fp = flagged_set - truth_set
fn = truth_scorable - flagged_set

precision = len(tp) / len(flagged_set) if flagged_set else float("nan")
recall = len(tp) / len(truth_scorable) if truth_scorable else float("nan")

print(f"scored window            : {scorable[0]} -> {scorable[1]}")
print(f"injected (scorable)      : {len(truth_scorable)}")
print(f"flagged                  : {len(flagged_set)}")
print(f"true positives           : {len(tp)}")
print(f"false positives          : {len(fp)}  {sorted(fp)}")
print(f"false negatives (missed) : {len(fn)}  {sorted(fn)}")
print(f"precision = {precision:.2f}   recall = {recall:.2f}")
sys.exit(0)
