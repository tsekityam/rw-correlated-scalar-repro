# RisingWave correlated scalar SUM repro

Minimal, self-contained reproduction of systematically **wrong results** from RisingWave for correlated scalar subqueries of the form:

```sql
SELECT
  s.user_id,
  (SELECT SUM(h.amount) FROM hourly_facts h WHERE h.user_id = s.user_id) AS scalar_sum
FROM (
  SELECT user_id FROM windows ORDER BY random() LIMIT 50
) AS s;
```

when the outer row `s` comes from a **derived table** (`ORDER BY random() LIMIT n`, or another `LIMIT` sample). The same aggregates are **correct** when computed as a fixed `VALUES` list of `user_id`s + `WHERE user_id IN (...)` + `GROUP BY` + `JOIN`.

A single-user probe (`FROM windows w WHERE user_id = 'literal'` + the same correlated `SUM`) may still match. The failure is the sample / derived-table path.

This repository is synthetic. It does not use any proprietary schema.

## What is in the box

| Path | Role |
| --- | --- |
| [`docker-compose.yml`](docker-compose.yml) | Official playground-style RisingWave (`single_node --in-memory`), `psql` on `localhost:4566` |
| [`.devcontainer/`](.devcontainer/) | VS Code / Cursor / `devcontainers/ci` environment on the same compose stack |
| [`sql/seed.sql`](sql/seed.sql) | `hourly_facts` + `windows` / `day1_windows` MVs with known per-user totals |
| [`scripts/run-repro.sh`](scripts/run-repro.sh) | Wait → seed → Query A variants → Query B → verdict |
| [`.github/workflows/repro.yml`](.github/workflows/repro.yml) | `docker compose up` + the same test on `push` / `pull_request` to `main` |
| [`VERSION`](VERSION) | Pinned image tag and how to bump it |

Pinned image: **`risingwavelabs/risingwave:v3.0.3`** (latest stable as of 2026-08-17). Connect with:

```bash
psql -h localhost -p 4566 -d dev -U root
```

### Bumping RisingWave

1. Pick a newer stable tag from [releases](https://github.com/risingwavelabs/risingwave/releases) / [Docker Hub](https://hub.docker.com/r/risingwavelabs/risingwave/tags).
2. Set `RW_IMAGE=risingwavelabs/risingwave:vX.Y.Z` in [`VERSION`](VERSION) and as the default in [`docker-compose.yml`](docker-compose.yml).
3. Keep `command: ["single_node", "--in-memory"]` (same as the official quickstart / playground standalone).

```bash
RW_IMAGE=risingwavelabs/risingwave:vX.Y.Z docker compose up -d --wait risingwave
```

## Data

`hourly_facts(user_id text, hour_utc timestamp, amount numeric)`:

- 80 users, uuid-shaped **text** keys (`aaaaaaaa-bbbb-4ccc-8ddd-000000000001` …). No `UUID` type.
- 48 hourly rows each (2024-01-01 00:00 through 2024-01-02 23:00).
- `amount = 1000 * u + hour_index`, so totals are known a priori:
  - lifetime `SUM` = `48000*u + 1128` (user 1 → `49128`)
  - first-day `SUM` = `24000*u + 276`
- `windows` MV: `GROUP BY user_id` lifetime sum + row count.
- `day1_windows` MV: first calendar day only.

## Queries

**Query A** (suspected buggy path) — several variants, first matching production:

1. Sample `FROM (SELECT user_id FROM windows ORDER BY random() LIMIT 50)` + correlated scalar `SUM`.
2. Same sample with several scalars at once (`SUM` lifetime, `SUM` day-1, `COUNT(*)`).
3. `LATERAL` form of the same `SUM`.
4. Derived `LIMIT 50` without `ORDER BY`.
5. `BOOL_AND(abs(delta) < 1e-12)` over the sample.

If `random()` is missing on a build, the script falls back to `ORDER BY md5(user_id) LIMIT n` (still a derived table + `LIMIT`).

**Query B** (known-good workaround) — the sampled ids as `VALUES`, `WHERE user_id IN (...)`, `GROUP BY user_id`, `JOIN` back to `windows`. This must match.

**Control** — `WHERE user_id = '<literal>'` + the same correlated `SUM` (often correct even when A is not).

**Secondary** (logged, not the primary fail):

- `WITH s AS MATERIALIZED (...)` — parser rejects this; RisingWave expects `AS CHANGELOG`.
- `CAST(x AS UUID)` / UUID type — unsupported. Keys stay `VARCHAR`.

## How to run locally

### Dev container (VS Code / Cursor)

1. Clone this repo and reopen in the container (Dev Containers).
2. Compose starts RisingWave; `postStartCommand` waits for `psql`.
3. In the container terminal:

```bash
bash scripts/run-repro.sh
```

`PGHOST=risingwave` is already set. Dashboard: port `5691`.

### Docker Compose on the host

```bash
docker compose up -d --wait risingwave
# psql client on the host:
sudo apt-get install -y postgresql-client   # or equivalent
export PGHOST=127.0.0.1 PGPORT=4566 PGDATABASE=dev PGUSER=root
bash scripts/wait-for-rw.sh
bash scripts/run-repro.sh
```

One-shot runner (no host `psql`):

```bash
docker compose up -d --wait risingwave
docker compose --profile test run --rm tester
```

## CI

[`.github/workflows/repro.yml`](.github/workflows/repro.yml) on `push` and `pull_request` to `main`:

1. `docker compose up -d --wait risingwave`
2. Install `postgresql-client`
3. `bash scripts/run-repro.sh` against `localhost:4566`

### Exit codes (the signal)

| Code | Meaning |
| --- | --- |
| **1** | **BUG REPRODUCED.** Query A disagrees with ground truth; Query B matches. This is the intended CI failure for the upstream issue. |
| **2** | Setup / workaround failure (RisingWave never became ready, seed failed, or Query B itself is wrong). |
| **0** | `SKIPPED: could not reproduce on this version` — every Query A variant and Query B matched. Printouts of both result sets are still in the log. |

## Upstream issue draft

Paste into a [risingwavelabs/risingwave](https://github.com/risingwavelabs/risingwave/issues/new) issue:

---

### Title

Wrong results for correlated scalar `SUM` when the outer row comes from `ORDER BY random() LIMIT n` (derived table)

### Describe the bug

RisingWave can return **systematically wrong** values for correlated scalar aggregates:

```sql
(SELECT SUM(h.amount) FROM hourly_facts h WHERE h.user_id = s.user_id)
```

when `s` is produced by a derived table such as:

```sql
(SELECT user_id FROM windows ORDER BY random() LIMIT 50)
```

On a synthetic dataset with a known lifetime `SUM` per `user_id`, this path disagrees with a pre-aggregated `GROUP BY user_id` materialized view (`windows`). In the original observation the scalar side was ~0 / `BOOL_AND(abs(delta) < 1e-12)` was false for the whole sample.

The **same** `user_id`s computed via a fixed `VALUES` list + `WHERE user_id IN (...)` + `GROUP BY` + `JOIN` match the MV exactly.

A single-row probe `FROM windows w WHERE user_id = '<literal>'` plus the same correlated `SUM` may still be correct. The failure is tied to the sample / derived-table outer relation, not to “SUM is always wrong.”

### To reproduce

Public repro: https://github.com/tsekityam/rw-correlated-scalar-repro

```bash
git clone https://github.com/tsekityam/rw-correlated-scalar-repro
cd rw-correlated-scalar-repro
docker compose up -d --wait risingwave
export PGHOST=127.0.0.1 PGPORT=4566 PGDATABASE=dev PGUSER=root
psql -c '\i sql/seed.sql'
# then sql/query_a.sql vs sql/query_b.sql
# or: bash scripts/run-repro.sh
```

Pinned image: `risingwavelabs/risingwave:v3.0.3` (`single_node --in-memory`). CI on that repo runs the same compose stack.

Schema (synthetic):

- `hourly_facts(user_id varchar, hour_utc timestamp, amount numeric)` — 80 users × 48 hours, deterministic amounts.
- `windows` = `SELECT user_id, SUM(amount) AS lifetime_sum FROM hourly_facts GROUP BY user_id`.

**Query A (wrong):**

```sql
SELECT
  s.user_id,
  w.lifetime_sum AS expected_sum,
  (SELECT SUM(h.amount) FROM hourly_facts h WHERE h.user_id = s.user_id) AS scalar_sum,
  abs(w.lifetime_sum - (SELECT SUM(h.amount) FROM hourly_facts h WHERE h.user_id = s.user_id)) < 1e-12 AS match
FROM (SELECT user_id FROM windows ORDER BY random() LIMIT 50) s
JOIN windows w ON w.user_id = s.user_id;
```

**Query B (correct workaround):**

```sql
WITH ids(user_id) AS (VALUES ('aaaaaaaa-bbbb-4ccc-8ddd-000000000001'), ...)
SELECT i.user_id, w.lifetime_sum, a.agg_sum
FROM ids i
JOIN windows w ON w.user_id = i.user_id
JOIN (
  SELECT user_id, SUM(amount) AS agg_sum
  FROM hourly_facts
  WHERE user_id IN (SELECT user_id FROM ids)
  GROUP BY user_id
) a ON a.user_id = i.user_id;
```

The repro script also tries `LATERAL`, multiple scalars, `LIMIT` without `ORDER BY`, and `BOOL_AND` over the sample.

### Expected behavior

For every sampled `user_id`, the correlated scalar `SUM` equals `windows.lifetime_sum` (and Query B). `BOOL_AND(match)` is true.

### Actual behavior

Query A / `BOOL_AND` over the derived sample disagrees (scalar side systematically wrong). Query B matches. See the CI log and `scripts/run-repro.sh` output on the repro repo.

### Workaround

Do not correlate a scalar `SUM` against a `random()/LIMIT` derived table. Materialize the id list (`VALUES` or a table) and compute `SUM` with `WHERE user_id IN (...) GROUP BY user_id`, then `JOIN`.

### Additional context

Secondary, independent of the wrong `SUM`:

1. `WITH s AS MATERIALIZED (SELECT ...)` is rejected by the parser (`Expected 'changelog'`). RisingWave uses `AS CHANGELOG` here, not Postgres CTE materialization.
2. `CAST(x AS UUID)` / type `UUID` is unsupported. The repro uses uuid-shaped `VARCHAR` keys.

---

## License

This repro is dedicated to the public domain (CC0) unless the host repository states otherwise.
