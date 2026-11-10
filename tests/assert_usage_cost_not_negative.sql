-- Only credits may be negative. A negative *usage* line item points to a broken export.

select line_item_id, usage_date, unblended_cost
from {{ ref('stg_billing_line_items') }}
where line_item_type = 'Usage'
  and unblended_cost < 0
