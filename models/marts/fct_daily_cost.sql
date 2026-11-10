{{
    config(
        materialized='incremental',
        unique_key='cost_key',
        incremental_strategy='delete+insert'
    )
}}

-- Grain: one row per usage_date x account x product_code x team.
--
-- Incremental logic: on every run we re-process the last `lookback_days` days
-- (delete + insert on cost_key). Billing exports are restated after the fact,
-- so "only new days" would silently miss corrections.

with src as (

    select *
    from {{ ref('stg_billing_line_items') }}

    {% if is_incremental() %}
    where usage_date >= (
        select max(usage_date) - interval {{ var('lookback_days') }} day
        from {{ this }}
    )
    {% endif %}

),

agg as (

    select
        usage_date,
        account_id,
        product_code,
        team,
        sum(case when line_item_type = 'Usage'  then unblended_cost else 0 end) as usage_cost,
        sum(case when line_item_type = 'Credit' then unblended_cost else 0 end) as credit_amount,
        sum(unblended_cost)                                                     as net_cost,
        count(*)                                                                as line_item_count
    from src
    group by 1, 2, 3, 4

)

select
    md5(concat_ws('|', usage_date, account_id, product_code, team)) as cost_key,
    *
from agg
