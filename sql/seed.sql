-- Synthetic hourly facts with a closed-form lifetime SUM per user.
--
-- user_id  = 'aaaaaaaa-bbbb-4ccc-8ddd-' || lpad(u, 12, '0')   (text, uuid-shaped)
-- hours    = 48 (2024-01-01 00:00 .. 2024-01-02 23:00)
-- amount   = 1000 * u + hour_index
--
-- lifetime_sum(u) = sum_{h=0..47} (1000u + h) = 48000*u + 1128
-- day1_sum(u)     = sum_{h=0..23} (1000u + h) = 24000*u + 276
-- n_hours(u)      = 48

DROP MATERIALIZED VIEW IF EXISTS day1_windows;
DROP MATERIALIZED VIEW IF EXISTS windows;
DROP TABLE IF EXISTS hourly_facts;

CREATE TABLE hourly_facts (
    user_id VARCHAR,
    hour_utc TIMESTAMP,
    amount NUMERIC
);

INSERT INTO hourly_facts
SELECT
    'aaaaaaaa-bbbb-4ccc-8ddd-' || lpad(u.n::varchar, 12, '0') AS user_id,
    TIMESTAMP '2024-01-01 00:00:00' + (h.n * INTERVAL '1 hour') AS hour_utc,
    (u.n * 1000 + h.n)::numeric AS amount
FROM (SELECT generate_series AS n FROM generate_series(1, 80)) AS u
CROSS JOIN (SELECT generate_series AS n FROM generate_series(0, 47)) AS h;

FLUSH;

CREATE MATERIALIZED VIEW windows AS
SELECT
    user_id,
    SUM(amount) AS lifetime_sum,
    COUNT(*) AS n_hours
FROM hourly_facts
GROUP BY user_id;

CREATE MATERIALIZED VIEW day1_windows AS
SELECT
    user_id,
    SUM(amount) AS day1_sum
FROM hourly_facts
WHERE hour_utc < TIMESTAMP '2024-01-02 00:00:00'
GROUP BY user_id;

FLUSH;
