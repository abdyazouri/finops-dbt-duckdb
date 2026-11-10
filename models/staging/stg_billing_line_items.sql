{{ config(materialized='view') }}

-- Staging: typing, light cleaning and de-duplication. No business logic here.
-- The raw export can contain exact duplicate line items (same line_item_id);
-- keep exactly one per id so that downstream sums are not inflated.

with source as (

    select * from {{ source('raw', 'billing_line_items') }}

),

typed as (

    select
        cast(line_item_id as varchar)                    as line_item_id,
        cast(usage_date as date)                         as usage_date,
        cast(usage_account_id as varchar)                as account_id,
        cast(product_code as varchar)                    as product_code,
        cast(usage_type as varchar)                      as usage_type,
        cast(region as varchar)                          as region,
        coalesce(nullif(trim(lower(tag_team)), ''), 'untagged') as team,
        cast(usage_amount as double)                     as usage_amount,
        cast(unblended_cost as double)                   as unblended_cost,
        cast(line_item_type as varchar)                  as line_item_type
    from source

),

deduped as (

    select
        *,
        row_number() over (partition by line_item_id order by usage_date) as _rn
    from typed

)

select * exclude (_rn)
from deduped
where _rn = 1
