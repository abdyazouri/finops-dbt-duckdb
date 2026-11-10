{{ config(materialized='view') }}

-- Observability for the source: how many duplicate line items did the export contain per day?
-- Used by a warn-level test so source problems are visible instead of silently "fixed".

select
    cast(usage_date as date) as usage_date,
    count(*)                 as raw_rows,
    count(distinct line_item_id) as distinct_line_items,
    count(*) - count(distinct line_item_id) as duplicate_rows
from {{ source('raw', 'billing_line_items') }}
group by 1
