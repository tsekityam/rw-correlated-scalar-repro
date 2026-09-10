#!/usr/bin/env bash
# Reproduce RisingWave wrong results for correlated scalar SUM over a
# derived sample (ORDER BY random() LIMIT n), versus a correct VALUES+IN+JOIN.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-4566}"
export PGDATABASE="${PGDATABASE:-dev}"
export PGUSER="${PGUSER:-root}"
export PGPASSWORD="${PGPASSWORD:-}"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/rw-repro.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

PSQL=(psql -X -v ON_ERROR_STOP=1)
PSQL_TUPLE=(psql -X -v ON_ERROR_STOP=1 -A -t -F $'\t')

banner() {
  printf '\n========== %s ==========\n' "$1"
}

psql_ok() {
  "${PSQL[@]}" "$@"
}

psql_tuples() {
  "${PSQL_TUPLE[@]}" "$@"
}

# Returns 0 if the SQL batch succeeds.
try_sql() {
  "${PSQL[@]}" -c "$1" >/dev/null 2>"${WORKDIR}/try.err"
}

count_bool_col() {
  # stdin: TSV rows; $1 = 1-based match-column index; prints "n n_true n_false n_null"
  awk -F '\t' -v col="$1" '
    NF >= col {
      n++
      v = tolower($col)
      if (v == "t" || v == "true") t++
      else if (v == "f" || v == "false") f++
      else nnull++
    }
    END { printf "%d %d %d %d\n", n+0, t+0, f+0, nnull+0 }
  '
}

extract_ids() {
  # stdin: TSV; first column is user_id
  awk -F '\t' 'NF && $1 != "" { print $1 }'
}

sql_values_list() {
  # stdin: one user_id per line → ('id'),('id'),...
  awk '
    NF {
      gsub(/'\''/, "'\'''\''")
      printf "%s('\''%s'\'')", (n ? ",\n        " : ""), $0
      n++
    }
    END { if (!n) exit 1 }
  '
}

banner "RisingWave version"
RW_VERSION="$(psql_tuples -c 'SELECT version()' | tr -d '\r' | head -n1 || true)"
echo "${RW_VERSION:-<unknown>}"
echo "PGHOST=${PGHOST} PGPORT=${PGPORT} PGDATABASE=${PGDATABASE} PGUSER=${PGUSER}"

banner "Seed"
psql_ok -f "${ROOT}/sql/seed.sql"
echo "Seed complete."
psql_ok -c "SELECT COUNT(*) AS n_facts FROM hourly_facts;"
psql_ok -c "SELECT COUNT(*) AS n_users, MIN(lifetime_sum) AS min_sum, MAX(lifetime_sum) AS max_sum FROM windows;"
# Closed form check on a couple of users (u=1 → 49128, u=80 → 3841128).
psql_ok -c "
SELECT user_id, lifetime_sum,
       (48000 * 1 + 1128) AS expected_u1
FROM windows
WHERE user_id = 'aaaaaaaa-bbbb-4ccc-8ddd-000000000001';
"

# Prefer ORDER BY random() to match the production sample pattern.
SAMPLE_ORDER="random()"
if try_sql "SELECT random();"; then
  echo "random() is available; Query A will use ORDER BY random() LIMIT n."
else
  SAMPLE_ORDER="md5(user_id)"
  echo "random() is NOT available; falling back to ORDER BY md5(user_id) LIMIT n"
  echo "(still a derived table + LIMIT, which is the suspected trigger)."
  if [[ -s "${WORKDIR}/try.err" ]]; then
    echo "random() error: $(tr '\n' ' ' < "${WORKDIR}/try.err")"
  fi
fi

CONTROL_USER="aaaaaaaa-bbbb-4ccc-8ddd-000000000001"
A_MISMATCH=0
A_RAN=0
B_MISMATCH=0
B_RAN=0
REPRO_VARIANT=""

run_query_a() {
  local name="$1"
  local sql="$2"
  local out="${WORKDIR}/a_${name}.tsv"
  banner "Query A / ${name}"
  echo "${sql}"
  echo "----- EXPLAIN -----"
  psql_ok -c "EXPLAIN ${sql}" || true
  echo "----- RESULT -----"
  psql_tuples -c "${sql}" | tee "${out}"
  local stats
  stats="$(count_bool_col 4 < "${out}")"
  local n n_true n_false n_null
  read -r n n_true n_false n_null <<<"${stats}"
  local n_scalar_null
  n_scalar_null="$(awk -F '\t' 'NF>=3 && $3 == "" { c++ } END { print c+0 }' "${out}")"
  echo "rows=${n} match_true=${n_true} match_false=${n_false} match_null=${n_null} scalar_sum_null=${n_scalar_null}"
  echo "NOTE: match_null usually means a correlated SUM came back NULL (SQL NULL < eps is NULL)."
  A_RAN=$((A_RAN + 1))
  if [[ "${n}" -eq 0 ]]; then
    echo "WARNING: ${name} returned 0 rows."
    return 0
  fi
  if [[ $((n_false + n_null)) -gt 0 ]]; then
    echo "MISMATCH: ${name} disagreed with windows / expected totals."
    A_MISMATCH=$((A_MISMATCH + 1))
    if [[ -z "${REPRO_VARIANT}" ]]; then
      REPRO_VARIANT="${name}"
    fi
    return 1
  fi
  echo "OK: ${name} matched expected totals."
  return 0
}

run_query_b() {
  local ids_file="$1"
  if [[ ! -s "${ids_file}" ]]; then
    echo "ERROR: no sampled user_ids for Query B." >&2
    return 2
  fi
  local values
  values="$(sql_values_list < "${ids_file}")"
  local sql
  sql="
WITH ids(user_id) AS (
    VALUES
        ${values}
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
"
  banner "Query B / VALUES + IN + GROUP BY + JOIN"
  echo "${sql}"
  echo "----- EXPLAIN -----"
  psql_ok -c "EXPLAIN ${sql}" || true
  echo "----- RESULT -----"
  local out="${WORKDIR}/b.tsv"
  psql_tuples -c "${sql}" | tee "${out}"
  local stats n n_true n_false n_null
  stats="$(count_bool_col 4 < "${out}")"
  read -r n n_true n_false n_null <<<"${stats}"
  echo "rows=${n} match_true=${n_true} match_false=${n_false} match_null=${n_null}"
  B_RAN=1
  if [[ "${n}" -eq 0 || $((n_false + n_null)) -gt 0 ]]; then
    echo "ERROR: Query B (workaround) did not match expected totals."
    B_MISMATCH=1
    return 1
  fi
  echo "OK: Query B matched expected totals (workaround holds)."
  return 0
}

# --- Control: single literal user (often matches even when the sample path does not)
CONTROL_SQL="
SELECT
    w.user_id,
    w.lifetime_sum AS expected_sum,
    (
        SELECT SUM(h.amount)
        FROM hourly_facts h
        WHERE h.user_id = w.user_id
    ) AS scalar_sum,
    abs(
        w.lifetime_sum
        - (
            SELECT SUM(h.amount)
            FROM hourly_facts h
            WHERE h.user_id = w.user_id
        )
    ) < 0.000000000001 AS match
FROM windows w
WHERE w.user_id = '${CONTROL_USER}';
"
set +e
run_query_a "control_literal_user" "${CONTROL_SQL}"
set -e

# --- Variant 1: production pattern — derived sample + correlated scalar SUM
V1="
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
    ORDER BY ${SAMPLE_ORDER}
    LIMIT 50
) AS s
JOIN windows w ON w.user_id = s.user_id
ORDER BY s.user_id;
"
set +e
run_query_a "sample_random_limit_scalar" "${V1}"
V1_RC=$?
set -e
extract_ids < "${WORKDIR}/a_sample_random_limit_scalar.tsv" > "${WORKDIR}/ids.txt"

# --- Variant 2: several correlated scalars at once (lifetime, day-1, count)
V2="
SELECT
    s.user_id,
    w.lifetime_sum AS expected_sum,
    (
        SELECT SUM(h.amount) FROM hourly_facts h WHERE h.user_id = s.user_id
    ) AS scalar_sum,
    (
        abs(
            w.lifetime_sum
            - (SELECT SUM(h.amount) FROM hourly_facts h WHERE h.user_id = s.user_id)
        ) < 0.000000000001
        AND abs(
            d.day1_sum
            - (
                SELECT SUM(h.amount)
                FROM hourly_facts h
                WHERE h.user_id = s.user_id
                  AND h.hour_utc < TIMESTAMP '2024-01-02 00:00:00'
            )
        ) < 0.000000000001
        AND (
            SELECT COUNT(*) FROM hourly_facts h WHERE h.user_id = s.user_id
        ) = w.n_hours
    ) AS match
FROM (
    SELECT user_id
    FROM windows
    ORDER BY ${SAMPLE_ORDER}
    LIMIT 50
) AS s
JOIN windows w ON w.user_id = s.user_id
JOIN day1_windows d ON d.user_id = s.user_id
ORDER BY s.user_id;
"
set +e
run_query_a "sample_multi_scalar" "${V2}"
set -e
if [[ ! -s "${WORKDIR}/ids.txt" ]]; then
  extract_ids < "${WORKDIR}/a_sample_multi_scalar.tsv" > "${WORKDIR}/ids.txt"
fi

# --- Variant 3: LATERAL instead of a select-list scalar
V3="
SELECT
    s.user_id,
    w.lifetime_sum AS expected_sum,
    lat.scalar_sum,
    abs(w.lifetime_sum - lat.scalar_sum) < 0.000000000001 AS match
FROM (
    SELECT user_id
    FROM windows
    ORDER BY ${SAMPLE_ORDER}
    LIMIT 50
) AS s
JOIN windows w ON w.user_id = s.user_id,
LATERAL (
    SELECT SUM(h.amount) AS scalar_sum
    FROM hourly_facts h
    WHERE h.user_id = s.user_id
) AS lat
ORDER BY s.user_id;
"
set +e
run_query_a "sample_lateral" "${V3}"
set -e

# --- Variant 4: derived LIMIT without ORDER BY (still a sample subquery)
V4="
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
    LIMIT 50
) AS s
JOIN windows w ON w.user_id = s.user_id
ORDER BY s.user_id;
"
set +e
run_query_a "sample_limit_only" "${V4}"
set -e

# --- Variant 5: BOOL_AND of the sample, computed client-side.
# RisingWave rejects "subquery inside aggregation calls", so we do not
# ask the engine for BOOL_AND((SELECT SUM...) ...).
banner "Query A / bool_and_summary (client-side)"
PRIMARY_TSV="${WORKDIR}/a_sample_random_limit_scalar.tsv"
if [[ -s "${PRIMARY_TSV}" ]]; then
  stats="$(count_bool_col 4 < "${PRIMARY_TSV}")"
  read -r n n_true n_false n_null <<<"${stats}"
  echo "BOOL_AND(match) over sample_random_limit_scalar: n=${n} true=${n_true} false=${n_false} null=${n_null}"
  A_RAN=$((A_RAN + 1))
  if [[ "${n}" -gt 0 && "${n_true}" -eq "${n}" ]]; then
    echo "OK: client-side BOOL_AND is true."
  else
    echo "MISMATCH: client-side BOOL_AND is not true (production-style all-false / NULL sample check)."
    A_MISMATCH=$((A_MISMATCH + 1))
    if [[ -z "${REPRO_VARIANT}" ]]; then
      REPRO_VARIANT="bool_and_summary"
    fi
  fi
else
  echo "No primary sample TSV; skipping client-side BOOL_AND."
fi

# If we still have no ids (every A variant failed to produce rows), use a fixed set.
if [[ ! -s "${WORKDIR}/ids.txt" ]]; then
  printf '%s\n' \
    'aaaaaaaa-bbbb-4ccc-8ddd-000000000001' \
    'aaaaaaaa-bbbb-4ccc-8ddd-000000000010' \
    'aaaaaaaa-bbbb-4ccc-8ddd-000000000025' \
    'aaaaaaaa-bbbb-4ccc-8ddd-000000000040' \
    'aaaaaaaa-bbbb-4ccc-8ddd-000000000080' \
    > "${WORKDIR}/ids.txt"
fi

set +e
run_query_b "${WORKDIR}/ids.txt"
B_RC=$?
set -e

banner "Verdict"
echo "RisingWave: ${RW_VERSION:-<unknown>}"
echo "Query A variants run: ${A_RAN}; mismatching variants: ${A_MISMATCH}"
echo "Query B ran: ${B_RAN}; mismatch: ${B_MISMATCH}"

if [[ "${B_MISMATCH}" -ne 0 || "${B_RAN}" -eq 0 ]]; then
  echo "SETUP/WORKAROUND FAILURE: Query B did not confirm ground truth."
  echo "Cannot treat this run as a clean correlated-scalar reproduction."
  exit 2
fi

if [[ "${A_MISMATCH}" -gt 0 ]]; then
  echo "BUG REPRODUCED: correlated scalar SUM over a derived sample disagrees"
  echo "with expected / windows totals, while Query B (VALUES + IN + GROUP BY + JOIN) matches."
  echo "First failing variant: ${REPRO_VARIANT}"
  echo "Typical wrong value is NULL (decorrelated plan re-runs ORDER BY random()/LIMIT"
  echo "independently on the agg side, then LeftOuter/FullOuter-joins a different sample)."
  echo "Control (literal user) and LATERAL usually match; that is expected."
  echo "This exit status is the intended signal for the upstream issue."
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "## BUG REPRODUCED"
      echo
      echo "- RisingWave: \`${RW_VERSION}\`"
      echo "- First failing variant: \`${REPRO_VARIANT}\`"
      echo "- Query A mismatches: ${A_MISMATCH} / ${A_RAN}"
      echo "- Query B: matched"
    } >> "${GITHUB_STEP_SUMMARY}"
  fi
  exit 1
fi

echo "SKIPPED: could not reproduce on this version (${RW_VERSION:-unknown})."
echo "Query A (all variants) and Query B both matched ground truth."
echo "Re-run after bumping RW_IMAGE in VERSION / docker-compose.yml if needed."
exit 0
