# finops-dbt-duckdb

A small, runnable **FinOps analytics pipeline** built with **dbt + DuckDB**: cloud billing line items
→ reconciled cost marts → statistical cost-anomaly detection → month-end run-rate projection.

> **The data is synthetic.** `scripts/generate_billing_data.py` produces a CUR-like billing export
> (trend, weekly seasonality, noise, injected spikes, duplicate rows, missing tags). Nothing here
> comes from a real cloud account, and the numbers say nothing about real-world cost levels.
> The point of the repo is the modelling, testing and detection approach.

## What it demonstrates

| Area | Where |
|---|---|
| Layered modelling (staging → dimensions/fact → marts) | `models/` |
| Dimensional model: `fct_daily_cost` + `dim_date` + `dim_service` (category mapping from a seed) | `models/marts/`, `seeds/` |
| Incremental model with a **lookback window** (billing exports get restated) and `delete+insert` on a surrogate key | `models/marts/fct_daily_cost.sql` |
| Data quality: generic, singular and `warn`-level tests, including a **raw → fact reconciliation** | `models/**/_*.yml`, `tests/` |
| De-duplication that stays **visible** (staging dedups; a warn test reports source duplicates per day) | `stg_billing_line_items`, `stg_raw_duplicate_report` |
| Statistical anomaly detection (trend-adjusted robust z-score, not a fixed threshold) | `models/marts/mart_cost_anomalies.sql` |
| Transparent month-end projection baseline | `models/marts/mart_month_end_projection.sql` |
| Evaluating the detector against known ground truth | `scripts/evaluate_anomalies.py` |
| CI that generates data, builds, tests and evaluates | `.github/workflows/ci.yml` |

## Lineage

```
raw CSV (synthetic CUR-like export)
   ├─ stg_billing_line_items  (typed, de-duplicated, 'untagged' fallback)
   │     ├─ dim_date
   │     ├─ dim_service  ◄── seed: service_categories
   │     └─ fct_daily_cost  (incremental; grain: date × account × service × team)
   │            ├─ mart_cost_anomalies
   │            └─ mart_month_end_projection
   └─ stg_raw_duplicate_report  (source observability)
```

## Run it

```bash
python -m venv .venv && source .venv/bin/activate
make setup          # pip install -r requirements.txt
make data           # 90 days of synthetic billing data
make build          # dbt seed + run + test
make eval           # detector precision / recall vs injected anomalies
make extend         # 7 new days arrive -> incremental load
make docs           # dbt docs with lineage graph
```

Everything runs locally; the warehouse is a single `finops.duckdb` file.

## Design decisions

**Incremental with lookback.** `fct_daily_cost` re-processes the last 3 days on every run
(`lookback_days` in `dbt_project.yml`) and replaces them by `cost_key`. "Only new days" would miss
restated line items. After extending the data from 90 to 97 days, the incremental table is
identical (row count and total cost) to a `--full-refresh`.

**Reconciliation test.** `tests/assert_fct_reconciles_to_staging.sql` compares daily totals between
staging and the fact table to the cent, so dropped rows, bad joins or incremental bugs fail the build.

**Duplicates are fixed *and* reported.** Staging keeps one row per `line_item_id`. A separate
model counts duplicates in the raw export and a `warn` test surfaces it on every run — silent
fixes hide upstream problems.

**Anomaly detection.** Cloud cost trends upward and has weekly seasonality, so a fixed threshold
either fires constantly or never. For each service and day type (weekday/weekend) the model:
1. fits a trailing log-linear trend over the previous 28 days,
2. takes today's residual against that trend,
3. scales it by the MAD of previous residuals (modified z-score, `0.6745 * r / MAD`),
4. flags upward spikes above 3.5.

`estimated_excess_cost` gives the dollar impact of each flagged day.

**Projection is a baseline, not a model.** Month-to-date actual + median daily cost of the last
14 days × remaining days. The median keeps one-off spikes out of the run rate. It is meant to be
easy to challenge, and to be the benchmark a real forecasting model has to beat.

## Results (synthetic data, 90 days)

```
injected (scorable) : 4
flagged             : 4
precision = 1.00    recall = 1.00
```

**Read this with care:** the injected spikes are large (2–5× on one slice of one service) and the
noise is well-behaved by construction, so this shows the pipeline and detector work end to end —
it is *not* evidence of accuracy on real billing data, which has promotions, migrations, step
changes and heavier tails.

## Limitations and next steps

- OLS trend fitting is not robust: a large earlier spike inside the window slightly distorts the
  trend. Options: Theil–Sen fit, or iteratively excluding flagged days.
- Only upward spikes are flagged; sustained step changes (e.g. a new always-on cluster) need a
  change-point approach rather than a per-day z-score.
- Real CUR data has far more columns (amortised cost, Savings Plans / RI allocation, tags per
  resource) and much larger volume. DuckDB is used here for local reproducibility; the same models
  would target BigQuery / Snowflake with minimal changes (mainly date functions and the
  incremental strategy).
- A statistical forecast (ETS / Prophet in a dbt Python model) could be benchmarked against the
  run-rate baseline.
- Savings-opportunity tracking (idea → realised dollars) is not modelled here.

## Layout

```
dbt_project.yml  profiles.yml  Makefile  requirements.txt
scripts/   generate_billing_data.py  evaluate_anomalies.py
seeds/     service_categories.csv
models/    staging/  marts/
tests/     generic/is_positive.sql  assert_*.sql  warn_*.sql
```
