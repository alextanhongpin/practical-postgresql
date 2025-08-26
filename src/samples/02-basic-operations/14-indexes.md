# Indexes (Make Lookups Fast)

## Problem / Context

You own the reporting endpoint for a marketplace. Pages that list recent orders started timing out after traffic grew. EXPLAIN shows sequential scans over millions of rows. You need a way to jump to the right rows fast. PostgreSQL indexes act like a lookup map so the planner can avoid scanning the whole table and return results quickly.

## Core Concept

An index is a fast lookup structure beside your table. Instead of scanning every row, PostgreSQL can jump to the rows you need. Indexes speed reads but add work on writes. Add indexes that have a clear, measured benefit.

We’ll cover: how to see if an index is used, core index types, simple rules, and special cases (GIN, GiST, BRIN, full text).

## Implementation

### 1. Check if an index is used

Use the planner and statistics instead of guessing.
Explain the query plan (planner intention):

```sql
EXPLAIN SELECT * FROM logs WHERE created_at > now() - interval '1 day';
```

If you see `Index Scan using idx_logs_brin` (or similar), the planner wants that index.

Run it for real:

```sql
EXPLAIN ANALYZE SELECT * FROM logs WHERE created_at > now() - interval '1 day';
```

This shows actual timing and row counts.

Check usage counts since the last stats reset:

```sql
SELECT relname   AS table,
       indexrelname AS index,
       idx_scan  AS times_used
FROM pg_stat_user_indexes
ORDER BY idx_scan DESC NULLS LAST
LIMIT 20;
```

A low or zero `idx_scan` over a long period suggests an index might be unused. Verify with workload knowledge before dropping.

Filter by name or pattern when checking a specific index:

```sql
SELECT relname AS table, indexrelname AS index, idx_scan
FROM pg_stat_user_indexes
WHERE indexrelname LIKE '%brin%';
```

Tip: if an index is not used, confirm your query matches the index columns and operators. Update planner stats if they are stale:

```sql
VACUUM (ANALYZE) your_table;
```

### 2. Core B-tree patterns

B-tree is the default. It covers equality and range operators for most scalar types.
Equality on a column:

```sql
CREATE INDEX idx_users_email ON users(email);
```

Filter and order on (user_id, created_at):

```sql
CREATE INDEX idx_orders_user_created_at ON orders(user_id, created_at);
```

Case-insensitive lookup:

```sql
CREATE INDEX idx_users_email_lower ON users (LOWER(email));
-- Query must use same expression
SELECT * FROM users WHERE LOWER(email) = LOWER('someone@example.com');
```

Unique constraint as index:

```sql
CREATE UNIQUE INDEX uidx_users_email ON users(email);
```

Note: deferrable uniqueness is a table constraint feature. See the Constraints chapter for deferrable UNIQUE and transaction control.
Partial index (only active rows need speed or uniqueness):

```sql
CREATE UNIQUE INDEX uidx_users_active_email ON users(email) WHERE is_active;
```

Covering index (include payload columns for index-only scans):

```sql
CREATE INDEX idx_orders_user_created_cover ON orders(user_id, created_at) INCLUDE (total);
```

Leftmost-prefix rule: a multi-column B-tree helps queries that use the leftmost columns. Put the most selective filter first.

Match ORDER BY direction when it matters:

```sql
CREATE INDEX idx_orders_created_desc ON orders (created_at DESC);
-- Helps ORDER BY created_at DESC LIMIT 50
```

### 3. Special index types (choose on purpose)

GIN (arrays, JSONB containment, full text):

```sql
CREATE INDEX idx_articles_tags_gin ON articles USING gin (tags);
-- Array queries
SELECT * FROM articles WHERE tags @> ARRAY['postgres'];
```

JSONB containment (key/value):

```sql
-- Index the whole JSONB for containment operators
CREATE INDEX idx_events_data_gin ON events USING gin (data);
-- Query: rows with country = 'US'
SELECT * FROM events WHERE data @> '{"country":"US"}'::jsonb;
```

Full text tsvector:

```sql
CREATE INDEX idx_articles_fts ON articles USING gin (to_tsvector('english', title || ' ' || body));
```

Equality on a single JSONB key? Prefer a B-tree functional index:

```sql
CREATE INDEX idx_events_country ON events ((data->>'country'));
```

LIKE or ILIKE on large text? Consider pg_trgm with GIN:

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX idx_title_trgm ON articles USING gin (title gin_trgm_ops);
```

GiST (ranges, geometry, KNN, exclusion):

```sql
CREATE INDEX idx_booking_period_gist ON room_booking USING gist (period);
```

Needed for range overlap operators like `&&` with speed.

BRIN (huge append-only tables):

```sql
CREATE INDEX idx_logs_created_brin ON logs USING brin (created_at);
```

Tiny and fast to create; best when the column is naturally ordered. Summarize new pages for big loads:

```sql
SELECT brin_summarize_new_values('idx_logs_created_brin');
```

Hash (equality only): niche; B-tree is usually fine.

## Variations and Trade‑Offs

- **Expression vs stored value**: sometimes a generated column plus B-tree helps SELECT payloads; otherwise a functional index is enough.
- **Partial vs full indexes**: partial reduce size and write cost but only help matching predicates.
- **Concurrent builds**: CREATE INDEX CONCURRENTLY avoids long locks but is slower to build.
- **Covering vs narrow**: INCLUDE speeds index-only scans at the cost of size and write overhead.

## Pitfalls

- Over-indexing slows writes and consumes disk. Each index must earn its keep.
- Mismatch between query and index expression prevents use (for example, missing LOWER()).
- Stale statistics mislead the planner. Run ANALYZE or rely on autovacuum.
- CREATE/DROP INDEX CONCURRENTLY cannot run inside a transaction block.

## Recap

- Indexes trade write cost for read speed. Start with B-tree and add others on purpose.
- Verify usefulness with EXPLAIN, ANALYZE, and pg_stat_user_indexes.
- Use expression, partial, covering, and special types (GIN, GiST, BRIN) for specific needs.
- Build and drop concurrently in live systems; watch for bloat and rebuild if needed.

## References

- Indexes overview: https://www.postgresql.org/docs/current/indexes.html
- B-tree, Hash, GiST, SP-GiST, GIN, BRIN: https://www.postgresql.org/docs/current/indexes-types.html
- Covering indexes (INCLUDE): https://www.postgresql.org/docs/current/indexes-index-only-scans.html#INDEXES-ONLY-SCANS-COVERING
- Partial indexes: https://www.postgresql.org/docs/current/indexes-partial.html
- Index maintenance and VACUUM: https://www.postgresql.org/docs/current/routine-vacuuming.html

## Optional Exercises

- Add a functional index on LOWER(email) and compare EXPLAIN plans with/without it.
- Create a partial unique index on users(email) WHERE is_active and test toggling is_active.
- Build a BRIN on a large timestamped table; run brin_summarize_new_values and check plan changes.
- Add a GIN index on jsonb data and test containment queries.
