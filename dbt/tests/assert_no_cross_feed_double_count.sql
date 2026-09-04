-- Directly tests the cross-feed dedup in int_bookings_unioned. Profiling
-- found real-world bookings on GDS-native carriers (PK, PA, ED) that also
-- show up in the LCC feed under the same reference - the same booking
-- captured twice by two upstream systems (see ASSUMPTIONS.md). After
-- dedup, no pnr should still appear under more than one source_feed - that
-- would mean the same booking is being double-counted in the mart.

select pnr, count(distinct source_feed) as feed_count
from {{ ref('int_bookings_unioned') }}
group by pnr
having count(distinct source_feed) > 1
