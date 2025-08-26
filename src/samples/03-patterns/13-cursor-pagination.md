# Cursor (Keyset) Pagination (Fast "Load More")

## Problem / Context

Your feed shows newest posts first. With OFFSET/LIMIT, page 3 shifts when new posts arrive and big offsets are slow. You want “Load more” that’s fast and stable even as data changes.

## Core Concept

- Use a deterministic ORDER BY that ends with a unique column.
- Remember the last row’s ordering values and request the next page with a WHERE that moves “after” that tuple.
- Use row-wise tuple comparison when all directions match; expand to OR chains when directions differ.

Offset pagination (`OFFSET 10000 LIMIT 20`) asks Postgres to count past 10k rows just to throw them away. Keyset (cursor) pagination says: “Start after this last row; give me the next chunk.” Way less work, stable, no skipping when rows are inserted.

## Implementation (step by step SQL)

## 1. Single column (id)

```sql
CREATE TABLE post (
  id SERIAL PRIMARY KEY,
  content TEXT NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO post (content) VALUES ('First'),('Second'),('Third'),('Fourth'),('Fifth');

-- Page 1
SELECT * FROM post ORDER BY id ASC LIMIT 3;
-- Suppose last id = 3
SELECT * FROM post WHERE id > 3 ORDER BY id ASC LIMIT 3; -- Page 2
```

Rule: WHERE uses the same ordering direction (`id > last_id` when ASC).

## 2. Why not OFFSET?

```sql
SELECT * FROM post ORDER BY id ASC OFFSET 10000 LIMIT 20; -- scans/skips 10k
```

Slow for large offsets and newly inserted rows can shift pages leading to duplicates / gaps for users.

## 3. Multi-column ordering

Need ALL ordering columns in cursor comparison.

```sql
CREATE TABLE scored_post (
  id SERIAL PRIMARY KEY,
  content TEXT NOT NULL,
  score INT NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
-- Order: score DESC, created_at DESC, id DESC (id as final unique tie breaker)
SELECT * FROM scored_post
ORDER BY score DESC, created_at DESC, id DESC
LIMIT 10;
-- Suppose last row: (score=8, created_at='2025-07-29 10:00Z', id=42)
SELECT * FROM scored_post
WHERE (score, created_at, id) < (8, '2025-07-29 10:00Z', 42)
ORDER BY score DESC, created_at DESC, id DESC
LIMIT 10;
```

Rule: For DESC sort, use `<` to move “after” the last tuple; for ASC use `>`. Put a unique column last to guarantee strict ordering.

## 4. Composite direction mix

If directions differ (e.g., score DESC, created_at ASC): you cannot use a simple row comparison. Expand logic:

```sql
-- Order: score DESC, created_at ASC, id ASC
WHERE (
      score < last_score
  OR (score = last_score AND created_at > last_created_at)
  OR (score = last_score AND created_at = last_created_at AND id > last_id)
)
```

Then reuse same ORDER BY. Application builds this predicate.

## 5. Dynamic sort options

Let user pick sort? Predefine allowed patterns. Each pattern lists: columns, directions, comparison builder. Reject arbitrary input to avoid SQL injection and impossible indexes.

## 6. Encoding the cursor

Store last row’s ordering values. Examples:

- JSON: `{"score":10,"created_at":"2025-07-29T10:00:00Z","id":42}`
- Pipe string: `10|2025-07-29T10:00:00Z|42`
- Base64 encode to keep URL tidy.

On next request: decode → build WHERE predicate.

## 7. Insert/delete safety

New rows earlier than your current page appear on future pages (fine). Deletions just shrink results; no shifting like OFFSET. Stable.

## 8. Indexing

Match leading order:

```sql
CREATE INDEX ON scored_post (score DESC, created_at DESC, id DESC);
```

Postgres stores DESC physically like ASC + flag; still useful to mirror directions for planner clarity.

## 9. Page backwards (optional)

To go “previous,” store first row’s cursor too. Then invert comparison / directions or run a reversed ORDER BY query and reverse in application.

## 10. Checklist

- Deterministic ORDER BY ending in unique column?
- WHERE predicate compares all ORDER BY columns?
- Directions matched (DESC → <, ASC → >)?
- Cursor encoded/decoded safely?
- Matching index exists?

Keyset pagination = constant-time page jumps and no shaky user experience.

## Variations and Trade‑Offs

- With mixed directions, tuple comparison is not supported; you must build a lexicographic OR chain.
- Cursors can be opaque strings (Base64 JSON) or structured tokens; opaque is tidy but harder to debug.
- Keyset is perfect for infinite scroll; OFFSET can still be fine for small pages in admin tools.

## Pitfalls

- Missing the unique tie‑breaker leads to duplicate or missing rows across pages.
- Using the wrong operator direction (> vs <) fetches the wrong page.
- Allowing arbitrary ORDER BY from users breaks indexes and cursor building; whitelist patterns.

## Recap (Short Summary)

Choose a stable ORDER BY that ends with a unique column. For the next page, compare the ordering tuple against the last row’s values using the correct operators. Encode/decode the cursor safely and add a matching composite index.

## Optional Exercises

- Implement backwards paging: fetch the previous page given the first row’s cursor.
- Add a secondary sort (score DESC, created_at DESC, id DESC) and build the tuple WHERE. Try both ASC and DESC.
- Design a cursor schema your API can evolve (include version, sort key names, and values).

## Summary (Cheat Sheet)

- **Problem**: OFFSET has large skip cost and causes page drift.
- **Solution**: WHERE compares the ordering tuple < or > last tuple values.
- **Requirement**: Deterministic ORDER BY ending in a unique column.
- **Multi-Column**: Use row comparison for uniform directions; mixed directions need a manual OR chain.
- **Direction Logic**: ASC uses >; DESC uses < for the next page.
- **Cursor Encoding**: Serialize ordering columns (JSON, pipe, Base64).
- **Backwards**: Flip the operator or reverse order and re-reverse on the client.
- **Index**: Composite index matching ORDER BY columns and directions.
- **Pitfalls**: Missing unique tie breaker, wrong operator sign, user-controlled arbitrary ORDER BY.

## References

- Composite indexes and ordering: https://www.postgresql.org/docs/current/indexes-ordering.html
- Index-only scans: https://www.postgresql.org/docs/current/indexes-index-only-scans.html
