-- Daily per-user activity summary.
-- Joins active users with their events and aggregates by (date, user_id).
--
-- Materialization: incremental (append strategy) on ReplacingMergeTree(_updated_at).
-- Re-runs for the same date insert new rows with a newer _updated_at;
-- querying with FINAL returns only the latest version per (date, user_id).

{{
    config(
        materialized='incremental',
        incremental_strategy='append',
        engine='ReplacingMergeTree(_updated_at)',
        order_by='(date, user_id)',
        unique_key='(date, user_id)'
    )
}}

SELECT
    toDate(e.timestamp)      AS date,
    u.user_id                AS user_id,
    anyLast(u.full_name)     AS full_name,
    anyLast(u.email)         AS email,
    count()                  AS total_events,
    max(e.timestamp)         AS last_event_at,
    now()                    AS _updated_at
FROM {{ ref('stg_events') }} AS e
INNER JOIN {{ ref('stg_users') }} AS u
    ON e.user_id = u.user_id
{% if is_incremental() %}
WHERE toDate(e.timestamp) >= (SELECT max(date) FROM {{ this }})
{% endif %}
GROUP BY date, u.user_id
