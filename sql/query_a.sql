-- Query A (buggy pattern): outer row comes from a derived table
--   (SELECT user_id FROM … ORDER BY random() LIMIT n)
-- and each sampled user is aggregated with a correlated scalar SUM.
--
-- Observed symptom: scalar_sum systematically disagrees with the
-- pre-aggregated windows MV (often ~0 / all match flags false).
--
-- Substitute :sample_order with `random()` when available, otherwise
-- another non-constant ORDER BY expression.

SELECT
    s.user_id,
    w.lifetime_sum AS expected_sum,
    (
        SELECT SUM(h.amount)
        FROM hourly_facts h
        WHERE h.user_id = s.user_id
    ) AS scalar_sum,
    abs(
        w.lifetime_sum
        - (
            SELECT SUM(h.amount)
            FROM hourly_facts h
            WHERE h.user_id = s.user_id
        )
    ) < 0.000000000001 AS match
FROM (
    SELECT user_id
    FROM windows
    ORDER BY random()
    LIMIT 50
) AS s
JOIN windows w ON w.user_id = s.user_id
ORDER BY s.user_id;
