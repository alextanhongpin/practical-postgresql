# Slowly Changing Dimensions (Type 2 History Made Simple)

## Problem / Context

Analytics asks, “What did we believe about this customer on June 1?” Your current table only keeps the latest address, so answers drift over time. You need to keep each historical version with a validity window for accurate as‑of queries.

## Core Concept

Store one row per version with `[valid_from, valid_to)` where `valid_to` is NULL for the current version. Update the previous open row’s `valid_to` on change and INSERT a new row starting at the change time.

## Implementation (step by step SQL)

### Table

```sql
CREATE TABLE customer_dim (
  customer_id INT NOT NULL,
  name        TEXT NOT NULL,
  address     TEXT NOT NULL,
  valid_from  TIMESTAMPTZ NOT NULL,
  valid_to    TIMESTAMPTZ,
  PRIMARY KEY (customer_id, valid_from)
);
```

### Insert first version

```sql
INSERT INTO customer_dim (customer_id, name, address, valid_from)
VALUES (1,'Alice','123 Main St','2025-01-01');
```

### Apply change (close old row, add new)

```sql
UPDATE customer_dim
  SET valid_to = '2025-07-01'
WHERE customer_id=1 AND valid_to IS NULL;

INSERT INTO customer_dim (customer_id, name, address, valid_from)
VALUES (1,'Alice','456 Oak Ave','2025-07-01');
```

### Current snapshot

```sql
SELECT * FROM customer_dim WHERE customer_id=1 AND valid_to IS NULL;
```

### As of a date

```sql
SELECT * FROM customer_dim
WHERE customer_id=1
  AND '2025-06-01' >= valid_from
  AND ('2025-06-01' < valid_to OR valid_to IS NULL);
```

### Notes

- Always close the previous open row before inserting a new one.
- Consider a trigger or stored procedure to handle the close + insert atomically.
- Add an index on (customer_id, valid_to) if lookups are heavy.
- Use half‑open semantics: treat valid_to as the instant the version stops being true.

### Optional helpers

View for current:

```sql
CREATE OR REPLACE VIEW customer_current AS
SELECT * FROM customer_dim WHERE valid_to IS NULL;
```

### Trigger: enforce continuous, valid intervals (tstzrange + range_agg)

Use a simple trigger to check three things per `customer_id` when inserting/updating a version row:

- Each row has a valid half-open window: `valid_from < valid_to` (or `valid_to IS NULL` for the current open version)
- No overlaps between versions for the same customer
- Continuity: consecutive windows are exactly adjacent (previous `valid_to` equals next `valid_from`) so there are no gaps

This uses `tstzrange` to build ranges and `range_agg` to get a normalized multirange we can scan for gaps.

```sql
CREATE OR REPLACE FUNCTION customer_dim_enforce_continuity()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  mr tstzmultirange;
  gaps int;
  _cid int := NEW.customer_id;
  _new_range tstzrange := tstzrange(NEW.valid_from, NEW.valid_to, '[)');
BEGIN
  -- 1) Per-row validity
  IF NEW.valid_to IS NOT NULL AND NEW.valid_from >= NEW.valid_to THEN
    RAISE EXCEPTION USING
      MESSAGE = '[SCD_0001] invalid validity window',
      DETAIL  = json_build_object('customer_id', _cid, 'valid_from', NEW.valid_from, 'valid_to', NEW.valid_to)::text,
      HINT    = 'Use half-open [valid_from, valid_to) with valid_from < valid_to';
  END IF;

  -- 2) Explicit overlap check against existing rows (allow adjacency only)
  IF EXISTS (
    SELECT 1
    FROM customer_dim d
    WHERE d.customer_id = _cid
      AND (TG_OP = 'INSERT' OR (d.valid_from, d.valid_to) IS DISTINCT FROM (OLD.valid_from, OLD.valid_to))
      AND tstzrange(d.valid_from, d.valid_to, '[)') && _new_range
      AND NOT upper(tstzrange(d.valid_from, d.valid_to, '[)')) = lower(_new_range)
      AND NOT upper(_new_range) = lower(tstzrange(d.valid_from, d.valid_to, '[)'))
  ) THEN
    RAISE EXCEPTION USING
      MESSAGE = '[SCD_0002] overlapping versions for customer',
      DETAIL  = json_build_object('customer_id', _cid)::text,
      HINT    = 'Close previous row at valid_to = new.valid_from, then insert the new version';
  END IF;

  -- 3) Continuity check (no gaps): aggregate all ranges (including NEW) and
  -- ensure every next range starts exactly at the previous end
  SELECT range_agg(r ORDER BY lower(r))
  INTO mr
  FROM (
    SELECT tstzrange(valid_from, valid_to, '[)') AS r
    FROM customer_dim
    WHERE customer_id = _cid
    UNION ALL
    SELECT _new_range
  ) q;

  -- Count places where next.lower <> prev.upper
  SELECT count(*) INTO gaps
  FROM (
    SELECT upper(r) AS prev_end,
           lead(lower(r)) OVER (ORDER BY lower(r)) AS next_start
    FROM unnest(mr) AS r
  ) s
  WHERE next_start IS NOT NULL AND next_start <> prev_end;

  IF gaps > 0 THEN
    RAISE EXCEPTION USING
      MESSAGE = '[SCD_0003] non-contiguous history for customer',
      DETAIL  = json_build_object('customer_id', _cid, 'gaps', gaps)::text,
      HINT    = 'Ensure each version starts at the previous valid_to (half-open [) semantics)';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_customer_dim_enforce ON customer_dim;
CREATE TRIGGER trg_customer_dim_enforce
  BEFORE INSERT OR UPDATE ON customer_dim
  FOR EACH ROW
  EXECUTE FUNCTION customer_dim_enforce_continuity();
```

Notes

- This trigger enforces local continuity per `customer_id`. If you insert historical backfills out of order, wrap them in a transaction; the trigger runs per-row. For bulk loads, a staging table plus a set-based validation query can be faster.
- Overlap prevention can also be done with an exclusion constraint: `EXCLUDE USING gist (customer_id WITH =, tstzrange(valid_from, valid_to, '[)') WITH &&)`; the trigger here adds the “no gaps” guarantee as well.
- `[)` half‑open semantics treat adjacency (prev `valid_to` equals next `valid_from`) as continuous.

### Write helpers: close-and-insert (CTE and MERGE)

Close the current open row and insert the new version atomically using a CTE:

```sql
WITH close AS (
  UPDATE customer_dim
     SET valid_to = $1
   WHERE customer_id = $2
     AND valid_to IS NULL
)
INSERT INTO customer_dim (customer_id, name, address, valid_from, valid_to)
VALUES ($2, $3, $4, $1, NULL);
-- Bind $1=new_valid_from, $2=customer_id, $3=name, $4=address
```

Alternative with MERGE (PostgreSQL 15+): use MERGE to close the open row, then INSERT. MERGE cannot both update and insert for the same source row in one statement.

```sql
-- Close the open row if any
MERGE INTO customer_dim t
USING (VALUES ($1::int, $2::timestamptz)) s(customer_id, new_from)
ON (t.customer_id = s.customer_id AND t.valid_to IS NULL)
WHEN MATCHED THEN
  UPDATE SET valid_to = s.new_from;

-- Then insert the new current version
INSERT INTO customer_dim (customer_id, name, address, valid_from, valid_to)
VALUES ($1, $3, $4, $2, NULL);
-- Bind $1=customer_id, $2=new_valid_from, $3=name, $4=address
```

Notes

- Include a “no-op” guard if you want to skip inserts when values didn’t change, by comparing against the latest version.
- MERGE simplifies the “close” step but still needs a separate INSERT for Type 2.

## Recap (Short Summary)

Type 2 lets you reconstruct past truth and audit changes cleanly. Each new version is an append; nothing destructive to history.

## Limits of explicit valid_from and valid_to

- **Two-Step Write**: You must UPDATE the old row then INSERT the new; slightly more latency; wrap both in one transaction to avoid races.
- **Gaps**: If valid_to doesn’t match the next version’s start, as-of queries can return no row; enforce by procedure or scheduled checks.
- **Overlaps**: Wrong valid_from/valid_to causes ambiguous truth; use an exclusion constraint on tstzrange or a trigger check.
- **Retro Corrections**: Back-dated changes mean splitting an old interval; provide a helper to “surgery” intervals safely.
- **Clock Skew**: If app servers aren’t time-synced, version order can be wrong; use server-side NOW().
- **Write Amplification**: Updating valid_to writes the row twice; on frequent changes consider an append-only snapshot (below).

When change frequency is modest these are acceptable; if changes are very frequent, consider an append-only snapshot table and derive ranges at query time.

## Alternate: snapshot approach (append-only)

Prefer a minimal-write log and derive intervals on read? See the dedicated follow-up chapter:

- [Slow‑changing dimensions (Snapshot approach)](11a-slow-changing-dimensions.md)

## Summary (Cheat Sheet)

- **Purpose**: Preserve historical versions for as-of queries.
- **Row Shape**: (business key, attributes..., valid_from, valid_to NULL for current).
- **Write Flow**: Close the open row (set valid_to) then insert a new version.
- **Query Current**: WHERE valid_to IS NULL.
- **As-Of Query**: date >= valid_from AND (date < valid_to OR valid_to IS NULL).
- **Integrity**: Use a trigger or procedure to enforce a single open row per key.
- **Indexing**: (business_key, valid_to) or (business_key, valid_from DESC).
- **Pitfalls**: Missing close, overlapping windows, clock skew.
- **Extensions**: Add changed-columns diffs, a history view, or temporal partitioning.

## References

- Window functions: https://www.postgresql.org/docs/current/tutorial-window.html
- Temporal data and range queries: https://www.postgresql.org/docs/current/rangetypes.html
