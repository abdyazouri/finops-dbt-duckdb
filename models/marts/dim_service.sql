{{ config(materialized='table') }}

-- Service dimension: category mapping comes from a seed; anything not mapped
-- falls into 'uncategorized' (and is visible rather than silently dropped).

with products as (

    select distinct product_code
    from {{ ref('stg_billing_line_items') }}

)

select
    p.product_code,
    coalesce(s.service_category, 'uncategorized')  as service_category,
    coalesce(s.is_shared_platform, false)          as is_shared_platform
from products p
left join {{ ref('service_categories') }} s using (product_code)
