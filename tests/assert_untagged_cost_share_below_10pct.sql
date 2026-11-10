-- Cost allocation depends on tags. If more than 10% of cost has no team tag,
-- showback/chargeback numbers are not trustworthy.

with totals as (
    select
        sum(net_cost)                                       as total_cost,
        sum(case when team = 'untagged' then net_cost end)  as untagged_cost
    from {{ ref('fct_daily_cost') }}
)

select total_cost, untagged_cost, untagged_cost / total_cost as untagged_share
from totals
where untagged_cost / total_cost > 0.10
