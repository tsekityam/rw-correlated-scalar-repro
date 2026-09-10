-- Query B (known-good workaround): the same user_ids via a fixed VALUES
-- list, filtered with WHERE user_id IN (...), aggregated with GROUP BY,
-- then JOINed back. This path is expected to match the windows MV.

WITH ids(user_id) AS (
    VALUES
        ('aaaaaaaa-bbbb-4ccc-8ddd-000000000001'),
        ('aaaaaaaa-bbbb-4ccc-8ddd-000000000002')
        -- Replace this VALUES list with user_ids from Query A when
        -- comparing the same sample. scripts/run-repro.sh builds Query B
        -- inline from the sampled ids and does not edit this file.
)
SELECT
    i.user_id,
    w.lifetime_sum AS expected_sum,
    a.agg_sum,
    abs(w.lifetime_sum - a.agg_sum) < 0.000000000001 AS match
FROM ids i
JOIN windows w ON w.user_id = i.user_id
JOIN (
    SELECT user_id, SUM(amount) AS agg_sum
    FROM hourly_facts
    WHERE user_id IN (SELECT user_id FROM ids)
    GROUP BY user_id
) a ON a.user_id = i.user_id
ORDER BY i.user_id;
