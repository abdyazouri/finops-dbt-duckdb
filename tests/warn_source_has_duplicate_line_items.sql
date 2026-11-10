{{ config(severity='warn') }}

-- Staging silently removes duplicate line items. This test makes that visible:
-- it WARNS (does not fail) whenever the raw export contained duplicates.

select usage_date, raw_rows, distinct_line_items, duplicate_rows
from {{ ref('stg_raw_duplicate_report') }}
where duplicate_rows > 0
