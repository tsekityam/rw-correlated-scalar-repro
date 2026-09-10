-- Secondary observations (not the primary bug).
-- RisingWave's WITH ... AS is reserved for CHANGELOG, so AS MATERIALIZED
-- (Postgres CTE materialization hint) is rejected. UUID is not a supported type.

-- 1) AS MATERIALIZED — expect a parser error mentioning changelog
WITH s AS MATERIALIZED (SELECT 1 AS x) SELECT * FROM s;

-- 2) CAST AS UUID — expect an unsupported-type / cannot-cast error
SELECT CAST('aaaaaaaa-bbbb-4ccc-8ddd-000000000001' AS UUID);
