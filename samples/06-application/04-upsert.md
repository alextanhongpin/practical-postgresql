# UPSERT (INSERT ... ON CONFLICT) Patterns

## Problem / Context

You ingest product updates from partners. Sometimes the product is new; sometimes it already exists and only a few fields change. You want a single statement that inserts new rows and updates existing ones without race conditions, while avoiding useless rewrites when nothing changed.

Goal: Insert a row if it does not exist; otherwise update parts of it—atomically, without race conditions. PostgreSQL gives this via `INSERT ... ON CONFLICT`.

## Core Concept

- ON CONFLICT targets a unique index/constraint; conflicting rows are locked and either updated or ignored.
- Prefer WHERE guards with IS DISTINCT FROM to avoid dead updates and reduce WAL churn.
- For massive batches, stage data then merge with a single INSERT ... SELECT ON CONFLICT statement.

## Implementation (Step by Step SQL)

## 1. Basic Keyed Upsert

```sql
CREATE TABLE products (
	id         BIGSERIAL PRIMARY KEY,
	sku        TEXT UNIQUE,
	name       TEXT NOT NULL,
	price_cents INT NOT NULL,
	updated_at timestamptz NOT NULL DEFAULT now()
);

-- Insert new or update price + name when sku already exists
INSERT INTO products(sku, name, price_cents)
VALUES ($1, $2, $3)
ON CONFLICT (sku)
DO UPDATE SET
	name = EXCLUDED.name,
	price_cents = EXCLUDED.price_cents,
	updated_at = now()
RETURNING *;
```

Notes:

- `EXCLUDED.column` = the value you attempted to insert.
- Only columns you list are updated—others keep old values.

## 2. Idempotent Counter (Increment Existing)

```sql
CREATE TABLE daily_views (
	day  date PRIMARY KEY,
	count bigint NOT NULL DEFAULT 0
);

INSERT INTO daily_views(day, count)
VALUES ($1, 1)
ON CONFLICT (day)
DO UPDATE SET count = daily_views.count + 1
RETURNING count;
```

Why not `EXCLUDED.count + 1`? Because you inserted 1; you want prior stored value plus 1.

## 3. Partial Update (Only When Value Changes)

```sql
INSERT INTO products(sku, name, price_cents)
VALUES ($1,$2,$3)
ON CONFLICT (sku)
DO UPDATE SET
	name = EXCLUDED.name,
	price_cents = EXCLUDED.price_cents,
	updated_at = CASE
		WHEN products.price_cents IS DISTINCT FROM EXCLUDED.price_cents
			 OR products.name IS DISTINCT FROM EXCLUDED.name
		THEN now() ELSE products.updated_at END
RETURNING *;
```

`IS DISTINCT FROM` treats NULLs sanely.

## 4. Conditional DO NOTHING

```sql
INSERT INTO products(sku, name, price_cents)
VALUES ($1,$2,$3)
ON CONFLICT (sku) DO NOTHING;
```

With fallback id lookup:

```sql
WITH ins AS (
	INSERT INTO products(sku, name, price_cents)
	VALUES ($1,$2,$3)
	ON CONFLICT (sku) DO NOTHING
	RETURNING id
)
SELECT COALESCE((SELECT id FROM ins), (SELECT id FROM products WHERE sku=$1)) AS id;
```

## 5. Multi-Column Unique Constraint

```sql
CREATE TABLE user_settings (
	user_id bigint NOT NULL,
	key text NOT NULL,
	value jsonb NOT NULL,
	updated_at timestamptz NOT NULL DEFAULT now(),
	PRIMARY KEY (user_id, key)
);

INSERT INTO user_settings(user_id, key, value)
VALUES ($1,$2,$3)
ON CONFLICT (user_id, key)
DO UPDATE SET
	value = EXCLUDED.value,
	updated_at = now();
```

## 6. Upsert With Derived Column (Aggregate Field)

```sql
CREATE TABLE tag_counts (
	tag text PRIMARY KEY,
	usages bigint NOT NULL DEFAULT 0,
	updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO tag_counts(tag, usages)
VALUES ($1, $2)
ON CONFLICT (tag)
DO UPDATE SET
	usages = tag_counts.usages + EXCLUDED.usages,
	updated_at = now();
```

## 7. Upsert Avoiding Dead Updates (WHERE Clause)

```sql
INSERT INTO products(sku, name, price_cents)
VALUES ($1,$2,$3)
ON CONFLICT (sku) DO UPDATE
SET name = EXCLUDED.name,
		price_cents = EXCLUDED.price_cents,
		updated_at = now()
WHERE (products.name, products.price_cents) IS DISTINCT FROM (EXCLUDED.name, EXCLUDED.price_cents)
RETURNING *;
```

If WHERE false → treated like DO NOTHING.

## 8. Bulk Upsert (Multiple Rows)

```sql
INSERT INTO products(sku, name, price_cents)
VALUES
	($1,$2,$3),
	($4,$5,$6)
ON CONFLICT (sku) DO UPDATE SET
	name = EXCLUDED.name,
	price_cents = EXCLUDED.price_cents,
	updated_at = now();
```

For very large batches consider staging table merge.

## 9. Staging Table Merge Pattern

```sql
INSERT INTO products (sku, name, price_cents)
SELECT sku, name, price_cents FROM staging_products
ON CONFLICT (sku) DO UPDATE SET
	name = EXCLUDED.name,
	price_cents = EXCLUDED.price_cents,
	updated_at = now();
```

## 10. Concurrency Behavior

- Per-row lock on conflict.
- Last writer wins unless you encode alternative (e.g. `GREATEST`).
- Wrap multi-row logical operations in one statement when possible.

## 11. Pitfalls and Smells

- Updating static columns → toast churn.
- Missing unique index → ON CONFLICT unusable.
- Hot counter row contention → batch increments.
- Massive conflict ratio degrading throughput → stage & merge.

## 12. Testing Strategy

Cases: insert new, update changed, update identical (WHERE guard), concurrent updates.

## 13. Choosing a Pattern

| Need                  | Pattern           |
| --------------------- | ----------------- |
| Simple create/replace | Basic upsert      |
| Increment             | Counter increment |
| Skip identical        | WHERE guard       |
| Massive batch         | Staging merge     |
| Accumulate numeric    | Derived aggregate |

## Appendix: Upsert vs MERGE

MERGE for multi-branch logic; ON CONFLICT for simple replace. Measure both if in doubt.

## Recap (Short Summary)

Use ON CONFLICT with a unique index to atomically insert or update. Guard updates to avoid unnecessary writes, and use staging merges for large batches. Test both “no change” and “conflict” paths.

## Optional Exercises

- Add a WHERE guard to skip identical updates and verify updated_at only changes when fields change.
- Convert a per-row upsert loop into a staging table merge and compare performance.
- Implement a “keep max timestamp” upsert using GREATEST and confirm correctness under concurrency.

## Summary (Cheat Sheet)

- **Simple Replace**: DO UPDATE SET col = EXCLUDED.col. Key: ON CONFLICT (unique_cols). Guard: WHERE old IS DISTINCT FROM excluded. Note: row lock on conflict. Alternative: MERGE for multi-branch.
- **Insert or Ignore**: DO NOTHING. Key: ON CONFLICT (unique_cols). Concurrency: no update contention. Alternative: fallback SELECT for id.
- **Increment Counter**: count = count + 1. Key: ON CONFLICT (pk). Risk: hot row contention. Alternative: batch aggregate later.
- **Accumulate Value**: usages = usages + EXCLUDED.usages. Key: ON CONFLICT (key). Guard: WHERE excluded.usages > 0. Concurrency: serialized per key. Alternative: periodic SUM.
- **Partial Update When Changed**: updated_at with CASE. Guard: WHERE (cols) IS DISTINCT FROM (EXCLUDED.cols). Benefit: avoid dead updates; locks only on real change.
- **Bulk Batch**: Multi-VALUES. Guard: WHERE distinct to skip identical. Risk: high conflict ratio. Alternative: stage and merge.
- **Staging Merge**: INSERT ... SELECT FROM staging with ON CONFLICT DO UPDATE. Guard: WHERE distinct. Benefit: faster set-based. Alternative: MERGE for more logic.
- **Last-Write Wins**: Basic replace. Guard: optional field compare. Risk: later arrival overwrites. Alternative: add version column.
- **Keep Max/Min**: col = GREATEST(col, EXCLUDED.col). Guard: WHERE excluded.col > col. Use for logical timestamp rules. Alternative: MERGE.
- **Skip Identical Rows**: WHERE tuple IS DISTINCT FROM. Benefit: reduces WAL and bloat. Alternative: trigger compare.
- **Concurrency Sensitive**: Optimistic version column. Key: ON CONFLICT (pk) WHERE version = EXCLUDED.version - 1. Behavior: missed updates error. Alternative: MERGE with matched condition.

Principle: Match pattern to mutation semantics and guard against dead updates to reduce churn.

## References

- INSERT ON CONFLICT (UPSERT): https://www.postgresql.org/docs/current/sql-insert.html#SQL-ON-CONFLICT
- MERGE command: https://www.postgresql.org/docs/current/sql-merge.html
- Indexes and conflict targets: https://www.postgresql.org/docs/current/sql-insert.html#SQL-ON-CONFLICT-EXAMPLES
