{{ config(materialized='table') }}

-- Run-rate projection of month-end cost per service, as of the latest billing day.
--
--   projected = month-to-date actual + median daily cost of the last 14 days * remaining days
--
-- This is deliberately a transparent BASELINE (median is robust to one-off spikes),
-- not a forecasting model. It is the number a FinOps review can reason about and
-- challenge; a statistical model (e.g. Prophet / ETS in a dbt Python model) can be
-- benchmarked against it.

with bounds as (

    select max(usage_date) as as_of_date from {{ ref('fct_daily_cost') }}

),

daily as (

    select usage_date, product_code, sum(net_cost) as cost
    from {{ ref('fct_daily_cost') }}
    group by 1, 2

),

mtd as (

    select
        d.product_code,
        sum(d.cost) as month_to_date_cost
    from daily d, bounds b
    where date_trunc('month', d.usage_date) = date_trunc('month', b.as_of_date)
    group by 1

),

run_rate as (

    select
        d.product_code,
        quantile_cont(d.cost, 0.5) as median_daily_cost_14d
    from daily d, bounds b
    where d.usage_date > b.as_of_date - interval 14 day
    group by 1

),

calendar as (

    select
        b.as_of_date,
        (date_trunc('month', b.as_of_date) + interval 1 month - interval 1 day)::date as month_end,
        date_diff('day', b.as_of_date,
                  (date_trunc('month', b.as_of_date) + interval 1 month - interval 1 day)::date) as days_remaining
    from bounds b

)

select
    c.as_of_date,
    m.product_code,
    s.service_category,
    round(m.month_to_date_cost, 2)                                         as month_to_date_cost,
    round(r.median_daily_cost_14d, 2)                                      as median_daily_cost_14d,
    c.days_remaining,
    round(m.month_to_date_cost + r.median_daily_cost_14d * c.days_remaining, 2) as projected_month_end_cost
from mtd m
join run_rate r using (product_code)
join {{ ref('dim_service') }} s using (product_code)
cross join calendar c
