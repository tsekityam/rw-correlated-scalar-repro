-- Query A (buggy pattern): outer row comes from a derived table
--   (SELECT user_id FROM … ORDER BY random() LIMIT n)
-- and each sampled user is aggregated with a correlated scalar SUM.
--
-- Observed symptom: scalar_sum is often NULL versus the windows MV.
--
-- match is computed from the same scalar_sum alias (outer SELECT), not a
-- second independent (SELECT SUM ...). Two identical correlated SUMs in
-- one select-list are decorrelated separately and can disagree.
--
-- This file is a manual example and always uses ORDER BY random().
-- scripts/run-repro.sh runs the same pattern; if random() is missing it
-- falls back to ORDER BY md5(user_id) in the generated SQL, not here.

SELECT
    q.user_id,
    q.expected_sum,
    q.scalar_sum,
    abs(q.expected_sum - q.scalar_sum) < 0.000000000001 AS match
FROM (
    SELECT
        s.user_id,
        w.lifetime_sum AS expected_sum,
        (
            SELECT SUM(h.amount)
            FROM hourly_facts h
            WHERE h.user_id = s.user_id
        ) AS scalar_sum
    FROM (
        SELECT user_id
        FROM windows
        ORDER BY random()
        LIMIT 50
    ) AS s
    JOIN windows w ON w.user_id = s.user_id
) AS q
ORDER BY q.user_id;
