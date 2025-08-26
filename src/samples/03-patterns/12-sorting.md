# Sorting Patterns (Keep Lists Friendly)

## Problem / Context

You’re building a product list page for an e‑commerce site. PM asks for: “Sort by popularity by default; if ratings tie, show cheaper first; within each category, let users see the top 3 items; pagination must be stable.” You need clear ordering rules, a deterministic tie‑breaker, and patterns for per‑group top‑N.

## Core Concept

- ORDER BY is a priority list: the first column decides, the next is the tie‑breaker, and so on.
- Deterministic order needs a unique final tie‑breaker (often the primary key) so pagination doesn’t jitter.
- Use CASE for custom buckets (featured first), explicit NULLS FIRST/LAST for clarity, and window functions for “top N per group.”

Sorting is just deciding the order humans read rows. A good ORDER BY answers: what ties come first? what happens inside groups? can I show “top N per group” cleanly? Here are core mini-patterns.

## Implementation (step by step SQL)

## Setup

```sql
CREATE TABLE product (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  category TEXT NOT NULL,
  price NUMERIC NOT NULL,
  rating INT
);
INSERT INTO product (name, category, price, rating) VALUES
 ('Laptop','Electronics',1200,5),
 ('Smartphone','Electronics',800,4),
 ('Book A','Books',20,5),
 ('Book B','Books',15,4),
 ('Headphones','Electronics',100,3);
```

Quick start: to load a richer dataset (including hierarchy and comments for Top‑N), run scripts/seed_sorting.sql in your database.

## 1. Simple multi-column

“If categories together, then cheaper first.”

```sql
SELECT * FROM product ORDER BY category, price; -- default ASC
```

“If categories A→Z, inside each highest rating first.”

```sql
SELECT * FROM product ORDER BY category ASC, rating DESC;
```

“If show most expensive first, but break price ties by name.”

```sql
SELECT * FROM product ORDER BY price DESC, name ASC;
```

Takeaway: ORDER BY is a priority list; earlier columns dominate tie‑breaking.

## 2. Deterministic ordering

Production rule: every query that feeds pagination should end with a unique tie breaker (often primary key) so order can’t “jiggle.”

```sql
SELECT * FROM product ORDER BY price DESC, id DESC; -- stable
```

## 3. Custom sort buckets (CASE)

Put “featured” first, rest alphabetical.

```sql
SELECT * FROM product
ORDER BY (CASE WHEN rating = 5 THEN 0 ELSE 1 END), name;
```

## 4. Null handling

```sql
SELECT * FROM product ORDER BY rating DESC NULLS LAST;
```

Explicit NULLS FIRST/LAST keeps surprises away.

## 5. Hierarchy ordering (depth and name)

Adjacency list of categories:

```sql
CREATE TABLE category (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  parent_id INT REFERENCES category(id)
);
INSERT INTO category (name,parent_id) VALUES
 ('Electronics',NULL),
 ('Laptops',1),
 ('Smartphones',1),
 ('Books',NULL),
 ('Fiction',4),
 ('Non-fiction',4),
 ('Fantasy',5);
```

Build a tree with depth, then order: first top levels (smaller depth) then name.

```sql
WITH RECURSIVE tree AS (
  SELECT id,name,parent_id,1 AS depth, LPAD(id::text,5,'0') AS path_key
  FROM category WHERE parent_id IS NULL
  UNION ALL
  SELECT c.id,c.name,c.parent_id,t.depth+1, t.path_key||'.'||LPAD(c.id::text,5,'0')
  FROM category c JOIN tree t ON c.parent_id=t.id
)
SELECT * FROM tree ORDER BY depth, name;
```

For a strict “nested order” you can ORDER BY path_key instead.

## 6. Top N per group (window function)

“Show top 3 highest score replies per parent comment.”

```sql
CREATE TABLE comment (
  id SERIAL PRIMARY KEY,
  parent_id INT REFERENCES comment(id),
  content TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  score INT NOT NULL DEFAULT 0
);
INSERT INTO comment (content, score) VALUES ('First',10), ('Second',5);
INSERT INTO comment (parent_id, content, score) VALUES
 (1,'R1',7),(1,'R2',9),(1,'R3',3),(1,'R4',8),
 (2,'R1',2),(2,'R2',6);

SELECT * FROM (
  SELECT *,
         ROW_NUMBER() OVER (PARTITION BY parent_id ORDER BY score DESC, id) AS rn
  FROM comment WHERE parent_id IS NOT NULL
) x
WHERE rn <= 3
ORDER BY parent_id, score DESC;
```

ROW_NUMBER ranks inside each parent group; then we filter.

Swap ROW_NUMBER for RANK or DENSE_RANK if you want ties to behave differently.

## 7. Keyset pagination prep

Stable deterministic sort is required before you can switch from OFFSET/LIMIT to keyset (cursor) pagination.

```sql
SELECT * FROM product ORDER BY price DESC, id DESC LIMIT 20; -- later WHERE (price,id) < (?,?)
```

## 8. Performance hints

- Add matching index columns in the same leading order as your most selective + ordering pattern.
- Avoid random functions (like ORDER BY random()) for large tables—precompute or sample.
- For window top‑N, an index on (parent_id, score DESC) can help the planner prune.

## 9. Checklist

- Defined exact tie breaker? (unique)
- Null order intentional? (NULLS LAST?)
- Need buckets? (CASE)
- Need per‑group top N? (window + filter)
- Pagination planned? (stable order)

Clear ordering = calm UIs and predictable caches.

## 10. User-defined ordering (WITH ORDINALITY)

Let users supply an explicit order (IDs or labels) and apply it in SQL using WITH ORDINALITY.

Example: sort products by a user-picked list of IDs

```sql
-- Desired order: [3, 5, 2]
SELECT p.*
FROM product p
JOIN unnest(ARRAY[3,5,2]) WITH ORDINALITY AS u(id, ord)
  ON u.id = p.id
ORDER BY u.ord, p.id; -- deterministic tie-breaker
```

Example: category preference order, then inside category by rating DESC, id DESC

```sql
-- Desired category order: ['Books','Electronics','Home']
SELECT p.*
FROM product p
LEFT JOIN unnest(ARRAY['Books','Electronics','Home']) WITH ORDINALITY AS u(category, ord)
  ON u.category = p.category
ORDER BY COALESCE(u.ord, 2147483647),  -- unmatched last
         p.rating DESC,
         p.id DESC;                    -- unique tie-breaker
```

Notes

- WITH ORDINALITY assigns a 1-based position to each element; join on the value and ORDER BY the position.
- Use LEFT JOIN if some rows may not appear in the user list; send unmatched to the end via COALESCE.
- Always add a unique final tie-breaker (e.g., id) to keep pagination stable.
- For dynamic inputs from the app, bind an array parameter and cast (e.g., $1::int[], $1::text[]).
- VALUES(...),(...) works too; WITH ORDINALITY is concise for arrays.

## Variations and Trade‑Offs

- Bucketed sorts with CASE are flexible but can reduce index usefulness; consider generated columns to index buckets.
- Window choices: ROW_NUMBER (no ties), RANK/DENSE_RANK (ties kept) — pick based on UX.
- Locale/collation affects text ordering; ICU collations may be slower but user‑friendly.
- Keyset (cursor) pagination is faster and stable than OFFSET/LIMIT, but needs careful tuple comparisons.

## Pitfalls

- Missing unique tie‑breaker leads to duplicate/missing rows across pages.
- Forgetting NULLS FIRST/LAST makes results vary by planner defaults.
- ORDER BY random() on large tables is expensive; preselect candidates instead.
- Mixed ASC/DESC without matching WHERE operators breaks keyset pagination.

## Recap (Short Summary)

Define a strict, deterministic ORDER BY with explicit NULL handling and a unique final tie‑breaker. Use CASE for buckets and window functions for per‑group top‑N. Prefer keyset pagination once the order is stable.

## Optional Exercises

- Add a “featured first, then by rating DESC, price ASC, id DESC” order to the sample products and verify stability across pages.
- Implement “top 2 per category” using ROW_NUMBER and compare with DENSE_RANK.
- Try a locale‑aware collation on product names and observe sort differences.

## Summary (Cheat Sheet)

- **Multi-Column Priority**: ORDER BY a, b DESC, c to define tie-breaking sequence. Pitfall: missing unique tie-breaker for pagination.
- **Deterministic Pagination**: Final ORDER BY includes PK to keep pages stable. Pitfall: jitter if PK omitted.
- **Custom Bucket Ordering**: Use CASE WHEN ... THEN ... END for feature/bucket order. Pitfall: complex CASE can hurt index use.
- **Null Handling**: Use NULLS FIRST or NULLS LAST explicitly to avoid surprises.
- **Hierarchy Ordering**: Recursive CTE + depth/path for tree order. Pitfall: deep trees expensive without indexes.
- **Top N per Group**: Use ROW_NUMBER() OVER (PARTITION BY ...) then filter. Pitfall: DISTINCT ON without deterministic order.
- **Keyset Prep**: ORDER BY business cols + unique id to prepare for cursor pagination. Pitfall: non-unique ordering leads to duplicates.

## References

- ORDER BY and NULLS FIRST/LAST: https://www.postgresql.org/docs/current/queries-order.html
- Collation support: https://www.postgresql.org/docs/current/collation.html
- WITH ORDINALITY and table functions: https://www.postgresql.org/docs/current/queries-table-expressions.html#QUERIES-TABLEFUNCTIONS
