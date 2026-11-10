"""Generate SYNTHETIC cloud billing line items (CUR-like) for the dbt project.

Nothing here is real billing data. The goal is a realistic *shape*:
  * daily line items per account / service / usage type / team tag
  * upward trend + weekly seasonality + noise
  * a few injected cost anomalies (ground truth saved to a side file)
  * deliberate data-quality problems so the dbt tests have something to catch:
      - duplicated line items (same line_item_id appears twice)
      - missing `team` tag on some rows
      - credits (negative cost) that are legitimate

Determinism: every day is generated from its own RNG seeded with (seed, day_index),
so `--days 90` followed by `--days 97` yields the same first 90 days plus 7 new
ones. That lets us demonstrate incremental loads in dbt.
"""
from __future__ import annotations

import argparse
from datetime import date, timedelta
from pathlib import Path

import numpy as np
import pandas as pd

ACCOUNTS = {"111111111111": "prod", "222222222222": "staging", "333333333333": "data-platform"}
ENV_FACTOR = {"prod": 1.0, "staging": 0.25, "data-platform": 0.6}
TEAMS = {"platform": 0.40, "ml": 0.25, "analytics": 0.20, "growth": 0.15}

# service -> [(usage_type, base_daily_cost_usd, growth_per_day, weekend_factor), ...]
SERVICES = {
    "AmazonEC2": [("BoxUsage:m5.xlarge", 420.0, 0.0030, 0.85), ("EBS:VolumeUsage.gp3", 60.0, 0.0020, 1.0)],
    "AmazonRDS": [("InstanceUsage:db.r6g.large", 210.0, 0.0010, 1.0)],
    "AmazonS3": [("TimedStorage-ByteHrs", 95.0, 0.0060, 1.0), ("Requests-Tier1", 18.0, 0.0040, 0.9)],
    "AWSLambda": [("Lambda-GB-Second", 35.0, 0.0050, 0.7)],
    "AWSDataTransfer": [("DataTransfer-Out-Bytes", 48.0, 0.0050, 0.9)],
    "AmazonAthena": [("Analysis-TB", 80.0, 0.0070, 0.6)],
}

# Injected anomalies: (day_index, product_code, multiplier) -- applied to prod/platform rows
ANOMALIES = [(23, "AmazonS3", 3.2), (41, "AWSDataTransfer", 4.5), (58, "AmazonEC2", 2.1), (77, "AWSLambda", 5.0)]


def generate_day(day_idx: int, start: date, seed: int) -> list[dict]:
    rng = np.random.default_rng([seed, day_idx])
    d = start + timedelta(days=day_idx)
    weekend = d.weekday() >= 5
    anomalies = {(i, s): m for i, s, m in ANOMALIES}
    rows: list[dict] = []
    for acct, env in ACCOUNTS.items():
        for service, usage_types in SERVICES.items():
            for usage_type, base, growth, wk in usage_types:
                for team, share in TEAMS.items():
                    cost = base * ENV_FACTOR[env] * share * (1 + growth) ** day_idx
                    cost *= wk if weekend else 1.0
                    cost *= rng.lognormal(0.0, 0.06)
                    if env == "prod" and team == "platform":
                        cost *= anomalies.get((day_idx, service), 1.0)
                    usage_amount = cost / rng.uniform(0.02, 0.06)
                    rows.append({
                        "line_item_id": f"{d:%Y%m%d}-{acct}-{service}-{usage_type}-{team}",
                        "usage_date": d.isoformat(),
                        "usage_account_id": acct,
                        "product_code": service,
                        "usage_type": usage_type,
                        "region": "eu-west-1" if rng.random() > 0.2 else "us-east-1",
                        "tag_team": team if rng.random() > 0.04 else None,  # ~4% missing tag
                        "usage_amount": round(usage_amount, 4),
                        "unblended_cost": round(cost, 4),
                        "line_item_type": "Usage",
                    })
        # small recurring credit per account (legitimate negative cost)
        rows.append({
            "line_item_id": f"{d:%Y%m%d}-{acct}-credit",
            "usage_date": d.isoformat(),
            "usage_account_id": acct,
            "product_code": "AmazonEC2",
            "usage_type": "SavingsPlanNegation",
            "region": "eu-west-1",
            "tag_team": "platform",
            "usage_amount": 0.0,
            "unblended_cost": round(-4.0 * ENV_FACTOR[env], 4),
            "line_item_type": "Credit",
        })
    # ~0.5% duplicated line items (export glitch)
    dup_n = max(1, int(len(rows) * 0.005))
    for idx in rng.choice(len(rows), size=dup_n, replace=False):
        rows.append(dict(rows[int(idx)]))
    return rows


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--days", type=int, default=90)
    p.add_argument("--start-date", default="2026-06-01")
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--out", default="data/raw/billing_line_items.csv")
    args = p.parse_args()

    start = date.fromisoformat(args.start_date)
    rows = [r for i in range(args.days) for r in generate_day(i, start, args.seed)]
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    pd.DataFrame(rows).to_csv(out, index=False)

    truth = pd.DataFrame(
        [
            {"usage_date": (start + timedelta(days=i)).isoformat(), "product_code": s, "multiplier": m}
            for i, s, m in ANOMALIES
            if i < args.days
        ]
    )
    truth.to_csv(out.parent / "injected_anomalies.csv", index=False)
    print(f"wrote {len(rows):,} rows ({args.days} days) -> {out}")
    print(f"wrote {len(truth)} injected anomalies -> {out.parent / 'injected_anomalies.csv'}")


if __name__ == "__main__":
    main()
