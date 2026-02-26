-- All events from the silver layer (append-only, no deduplication needed).

SELECT
    user_id,
    event_type,
    timestamp,
    metadata
FROM {{ source('silver', 'events_silver') }}
