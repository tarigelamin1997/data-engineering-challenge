-- Deduplicated view of active users from the silver layer.
-- FINAL ensures ReplacingMergeTree returns only the latest version per user_id.
-- Filtered to exclude soft-deleted users (is_deleted = 1).

SELECT
    user_id,
    full_name,
    email,
    updated_at
FROM {{ source('silver', 'users_silver') }} FINAL
WHERE is_deleted = 0
