{{ config(materialized='table') }}

-- Date dimension spanning the billing history.

with bounds as (

    select
        min(usage_date) as first_day,
        max(usage_date) as last_day
    from {{ ref('stg_billing_line_items') }}

),

spine as (

    select cast(d as date) as date_day
    from bounds,
         generate_series(bounds.first_day, bounds.last_day, interval 1 day) as t(d)

)

select
    date_day,
    extract(year  from date_day)                     as year,
    extract(month from date_day)                     as month,
    date_trunc('month', date_day)::date              as month_start,
    (date_trunc('month', date_day) + interval 1 month - interval 1 day)::date as month_end,
    dayname(date_day)                                as day_name,
    isodow(date_day) in (6, 7)                       as is_weekend
from spine
