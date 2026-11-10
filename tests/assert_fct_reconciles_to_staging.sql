-- Reconciliation: for every billing day, total net cost in the fact table must equal
-- the total in staging (within a cent). Catches dropped rows, bad joins and
-- incremental-logic bugs -- the "chase the number until it reconciles" check.

with fct as (
    select usage_date, sum(net_cost) as fct_cost
    from {{ ref('fct_daily_cost') }}
    group by 1
),

stg as (
    select usage_date, sum(unblended_cost) as stg_cost
    from {{ ref('stg_billing_line_items') }}
    group by 1
)

select
    coalesce(f.usage_date, s.usage_date) as usage_date,
    f.fct_cost,
    s.stg_cost,
    abs(coalesce(f.fct_cost, 0) - coalesce(s.stg_cost, 0)) as abs_diff
from fct f
full outer join stg s on f.usage_date = s.usage_date
where abs(coalesce(f.fct_cost, 0) - coalesce(s.stg_cost, 0)) > 0.01
