# Debugging Slow Queries

## Problem / Context

You’re on-call and a critical endpoint slowed down after a feature launch. Product dashboards time out and customers see spinners. You need a repeatable way to find the slowest queries, understand why the planner chose a bad path, and apply the smallest fix (index, rewrite, fresh stats) to restore performance.

Slow queries hurt performance. PostgreSQL has tools to find and fix them.

## Core Concept

- Always start with a plan (EXPLAIN ANALYZE, BUFFERS) to see reality vs estimates.
- Cheap fixes first: fresh stats, missing index, narrower SELECT, correct data types.
- Verify change with before/after metrics and drop redundant indexes to keep writes fast.

## Slow query triage (make it fast)

Goal: Find why a query is slow, fix cheap things first, verify improvement.

## Implementation (step by step SQL)

### 1. Get the plan

```sql
EXPLAIN SELECT * FROM orders WHERE user_id = 123;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE user_id = 123;
```

Look for:

- Seq Scan on huge table with selective predicate → missing index
- Nested Loop with large inner row estimate → bad stats / wrong join order
- Hash Join + high rows removed afterwards → filter pushdown opportunity
- Lots of time in sorting / hashing → maybe reduce columns or add index matching order

### 2. Cheap fix checklist

| Symptom                           | Likely Fix                                                                     |
| --------------------------------- | ------------------------------------------------------------------------------ |
| Seq Scan on selective column      | CREATE INDEX (col)                                                             |
| Using function on column in WHERE | Expression index or precomputed column                                         |
| Repeated large sort               | Index on ORDER BY columns                                                      |
| Low correlation after update      | VACUUM (ANALYZE) or just ANALYZE                                               |
| Underestimated rows               | Increase statistics target (ALTER TABLE ... ALTER COLUMN ... SET STATISTICS n) |

### 3. pg_stat_statements (top offenders)

Prerequisite: the extension must be preloaded at server start.

- Set shared_preload_libraries and restart the server, then run CREATE EXTENSION in the database.

Example (docker-compose):

```yaml
services:
	db:
		image: postgres:17.4
		ports:
			- ${DB_HOST}:${DB_PORT}:5432
		command: >-
			-c shared_preload_libraries=pg_stat_statements
			-c pg_stat_statements.track=all
			-c pg_stat_statements.max=10000
		environment:
			POSTGRES_DB: ${DB_NAME}
			POSTGRES_USER: ${DB_USER}
			POSTGRES_PASSWORD: ${DB_PASS}
		volumes:
			- postgres_data:/var/lib/postgresql/data
			- ./internal/:/tmp/postgres/

volumes:
	postgres_data:
```

Then enable in your database:

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

PostgreSQL 15/16+ (modern columns):

```sql
SELECT
	toplevel,
	queryid,
	calls,
	total_plan_time AS plan_ms,
	total_exec_time AS exec_ms,
	ROUND((total_exec_time / NULLIF(calls,0))::numeric, 2) AS mean_exec_ms,
	rows,
	query
FROM pg_stat_statements
WHERE toplevel IS TRUE
ORDER BY total_exec_time DESC
LIMIT 10;
```

Note: total_plan_time, total_exec_time (PG 15/16+) and total_time (PG 13–14) are already in milliseconds. No need to multiply by 1000. The mean above is ms per call.

PostgreSQL 13–14 (legacy column names):

```sql
SELECT
	calls,
	total_time   AS total_ms,
	mean_time    AS mean_ms,
	rows,
	query
FROM pg_stat_statements
ORDER BY total_time DESC
LIMIT 10;
```

Tips

- Reset stats when starting a local investigation: `SELECT pg_stat_statements_reset();`
- Filter by database if needed: `WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())`.
- Focus on high total cost first (total_exec_time/total_time), then high mean per call.

### 4. Lock wait vs compute

If runtime is long but buffers and rows are low, it may be waiting on a lock. See [Locks](04-locks.md) for diagnosing blockers and deadlocks.

```sql
SELECT pid, now()-query_start AS run, wait_event_type, wait_event, query
FROM pg_stat_activity WHERE state <> 'idle' ORDER BY run DESC;
```

### 5. Refresh statistics

Outdated stats cause bad plans.

```sql
ANALYZE orders; -- or entire DB
```

For large changes, autovacuum might lag.

### 6. Avoid SELECT \*

Pulling unused large columns increases I/O:

```sql
SELECT id, user_id, status FROM orders WHERE user_id=123;
```

This avoids visiting TOAST for large JSON/text.

### 7. Batch backfills and updates

A long UPDATE that touches many rows can block. Process in chunks:

```sql
UPDATE orders SET flag=true WHERE ... LIMIT 1000; -- repeat in app/job
```

(Or use ORDER BY with a primary key cursor.)

### 8. Log slow queries

Set `log_min_duration_statement = 500` (ms). Keep it practical; too low is noisy. Rotate and parse logs.

### 9. EXPLAIN ANALYZE caution

It runs the query. For destructive queries, wrap in a transaction and ROLLBACK, or test on staging.

### 10. Index creation safety

```sql
CREATE INDEX CONCURRENTLY idx_orders_user_id ON orders(user_id);
```

This avoids a long ACCESS EXCLUSIVE lock. It needs a separate transaction and cannot be inside another transaction block.

### 11. Common pitfalls

- Function on column prevents index use (`WHERE lower(email)=...`) → add functional index.
- Implicit cast mismatch (text vs uuid) → explicit cast or correct type.
- Leading wildcard (`LIKE '%abc'`) → cannot use btree; consider trigram or GIN.
- Over-indexing: too many similar indexes slow writes.

### 12. Verification loop

1. Capture baseline (mean_time, buffers, runtime)
2. Apply change (index / rewrite)
3. Re-run EXPLAIN (ANALYZE, BUFFERS)
4. Confirm timing + buffer reductions
5. Drop any now-redundant index

### 13. Summary checklist

- Plan inspected?
- Stats fresh?
- Missing / wrong index fixed?
- Data fetched trimmed?
- Lock waits ruled out?
- Improvement measured?

Fix the highest total cost query, then repeat. Small consistent wins beat big refactors.

## Variations and Trade‑Offs

- Rewrite vs index: sometimes reformulating the query (join order, predicate pushdown) beats adding yet another index.
- Sampling: on giant tables, test on a realistic subset to iterate quickly, then verify on staging with size parity.
- Planner hints aren’t native; use enable\_\* GUC toggles only for diagnosis, not in production.

## Pitfalls

- EXPLAIN without ANALYZE shows estimates only; you may miss the real cost.
- Over-indexing speeds reads but hurts writes; balance and prune duplicates.
- Function-wrapped predicates block index use unless you add expression indexes.

## Recap (Short Summary)

Measure with EXPLAIN (ANALYZE, BUFFERS), fix the smallest cause first, and verify with before/after timing and buffers. Keep indexes purposeful and trim SELECT lists.

## Optional Exercises

- Capture top 10 queries by total_time via pg_stat_statements and fix one with the cheapest index.
- Rewrite a query to push filters before joins and compare plans.
- Add a functional index for a lower(email) lookup and confirm index usage in the plan.

## Summary (Cheat Sheet)

- **Plan**: Use EXPLAIN (ANALYZE, BUFFERS). Signal: seq scan on selective filter. Fix: add/adjust index. Verify: buffers/time drop.
- **Statistics**: ANALYZE table. Signal: row estimate off vs actual. Fix: raise STATISTICS target. Verify: estimates align.
- **Lock Wait**: Inspect pg_stat_activity wait_event. Signal: wait_event_type = 'Lock'. Fix: resolve blocker or reschedule. Verify: runtime shrinks.
- **Column Trim**: Select only needed columns. Signal: high buffer hits, TOAST reads. Fix: avoid SELECT \*. Verify: lower I/O.
- **Functional Predicate**: WHERE function(col) = value. Signal: no index usage. Fix: expression index. Verify: index scan appears.
- **Sorting**: Large Sort node with high time/mem. Fix: index matching ORDER BY. Verify: Sort removed.
- **Join Order**: Nested Loop with huge inner scans. Signal: bad estimates. Fix: analyze + rewrite join. Verify: plan uses better join.
- **Regressions**: New index overhead. Signal: slower writes. Fix: drop redundant index. Verify: write latency recovers.
- **Logging**: Set log_min_duration_statement. Signal: too noisy or missing. Fix: tune threshold. Verify: actionable entries.
- **Verify**: Re-run baseline metrics after change. If unclear, capture after numbers and document delta.
- **Pitfalls**: EXPLAIN without ANALYZE; over-indexing; ignoring VACUUM.

Loop: Measure → Hypothesize → Change → Verify → Document.

## References

- EXPLAIN: https://www.postgresql.org/docs/current/using-explain.html
- Buffer usage (BUFFERS): https://www.postgresql.org/docs/current/using-explain.html#USING-EXPLAIN-BUFFERS
- Query planning (planner): https://www.postgresql.org/docs/current/runtime-config-query.html
- Statistics target: https://www.postgresql.org/docs/current/runtime-config-query.html#GUC-DEFAULT-STATISTICS-TARGET
- pg_stat_statements: https://www.postgresql.org/docs/current/pgstatstatements.html
- Logging slow statements (log_min_duration_statement): https://www.postgresql.org/docs/current/runtime-config-logging.html#GUC-LOG-MIN-DURATION-STATEMENT
