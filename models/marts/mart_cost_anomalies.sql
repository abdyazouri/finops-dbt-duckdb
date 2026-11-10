{{ config(materialized='table') }}

-- Statistical cost-anomaly detection per service.
--
-- Why not a fixed threshold? Cloud cost trends upward and has weekly seasonality,
-- so "cost > X" either fires constantly or never. Instead, for each service and
-- each day-type (weekday / weekend) we:
--   1. fit a trailing log-linear trend on the previous N days (OLS in log space),
--   2. take the residual of today's cost vs that trend,
--   3. scale it by the MAD (median absolute deviation) of previous residuals,
--      giving a robust (modified) z-score,
--   4. flag upward spikes above `anomaly_threshold`.
--
-- Known limitation (documented on purpose): OLS is not robust, so a very large
-- earlier spike inside the window slightly distorts the trend. A Theil-Sen fit
-- or iterative exclusion of flagged days would be the next improvement.

with daily as (

    select
        f.usage_date,
        f.product_code,
        sum(f.net_cost) as cost
    from {{ ref('fct_daily_cost') }} f
    group by 1, 2

),

prepared as (

    select
        d.usage_date,
        d.product_code,
        d.cost,
        dd.is_weekend,
        ln(d.cost)                                       as log_cost,
        date_diff('day', date '1970-01-01', d.usage_date) as day_num
    from daily d
    join {{ ref('dim_date') }} dd on dd.date_day = d.usage_date
    where d.cost > 0

),

fitted as (

    select
        *,
        regr_slope(log_cost, day_num)     over w as trend_slope,
        regr_intercept(log_cost, day_num) over w as trend_intercept,
        count(*)                          over w as n_obs
    from prepared
    window w as (
        partition by product_code, is_weekend
        order by usage_date
        range between interval {{ var('anomaly_window_days') }} days preceding
                  and interval 1 day preceding
    )

),

residuals as (

    select
        *,
        case when n_obs >= 8
             then log_cost - (trend_intercept + trend_slope * day_num)
        end as residual
    from fitted

),

scored as (

    select
        *,
        quantile_cont(abs(residual), 0.5) over (
            partition by product_code, is_weekend
            order by usage_date
            range between interval {{ var('anomaly_window_days') }} days preceding
                      and interval 1 day preceding
        ) as mad
    from residuals

)

select
    usage_date,
    product_code,
    round(cost, 2)                                                    as cost,
    round(exp(trend_intercept + trend_slope * day_num), 2)            as expected_cost,
    round(cost / exp(trend_intercept + trend_slope * day_num) - 1, 4) as pct_over_expected,
    round(0.6745 * residual / greatest(mad, 0.01), 2)                 as robust_z,
    coalesce(
        0.6745 * residual / greatest(mad, 0.01) > {{ var('anomaly_threshold') }}
        and residual > 0,
        false
    )                                                                 as is_anomaly,
    case
        when 0.6745 * residual / greatest(mad, 0.01) > {{ var('anomaly_threshold') }}
         and residual > 0
        then round(cost - exp(trend_intercept + trend_slope * day_num), 2)
    end                                                               as estimated_excess_cost
from scored
where residual is not null
