# JSONB Recordset Expansion

## Problem / Context

Your service receives arrays of JSON objects (users, products, events) and you need to insert or upsert them as rows. You want a single set-based query instead of looping, with validation and safe updates when records already exist.

Convert JSON array of objects into relational rows.

## Core Concept

- jsonb_to_recordset turns an array of objects into rows with a declared column schema.
- Pair it with INSERT ... ON CONFLICT for set-based upserts; guard with a freshness column to avoid stale overwrites.
- For heavy validation, stage first, validate, then merge.

## Implementation (Step by Step SQL)

## jsonb_to_recordset

```sql
WITH incoming AS (
  SELECT * FROM jsonb_to_recordset($1::jsonb)
    AS t(id uuid, name text, attrs jsonb, updated_at timestamptz)
)
INSERT INTO users AS u (id, name, attrs, updated_at)
SELECT id, name, attrs, updated_at
FROM incoming
ON CONFLICT (id) DO UPDATE
SET name = EXCLUDED.name,
    attrs = EXCLUDED.attrs,
    updated_at = EXCLUDED.updated_at
WHERE u.updated_at < EXCLUDED.updated_at;
```

## Dynamic Columns

Define only needed columns; extra keys ignored unless captured as jsonb.

## Validation

Pre-validate JSON schema in app or use CHECK constraints on computed columns.

## Performance

- Pass JSONB not text for fewer casts.
- Keep batch size moderate (avoid giant single JSON document).

## When to Use vs UNNEST Arrays

| Situation             | Prefer    |
| --------------------- | --------- |
| Many optional fields  | Recordset |
| Uniform typed columns | UNNEST    |
| Sparse wide objects   | Recordset |

## Related

For CRUD path updates see 13-jsonb-crud.md.

## Variations and Trade‑Offs

- Recordset vs staging: recordset is concise; staging adds observability and richer validation.
- Freshness vs version: timestamp comparisons are simple but sensitive to skew; version columns are robust but need coordination.
- Large batches: chunk input to avoid large single-document parse overhead.

## Pitfalls

- Mismatched declared types cause runtime errors; define the recordset schema carefully.
- Very large JSON arrays can cause high memory/parse time; chunk into multiple calls.
- Clock skew can let stale rows overwrite fresh ones; choose a reliable freshness strategy.

## Recap (Short Summary)

Turn arrays of JSON objects into rows with jsonb_to_recordset and upsert them with one statement. Use freshness guards and consider staging for complex validation.

## Optional Exercises

- Switch freshness guard to a version integer and compare behavior.
- Add a CHECK enforcing a required key via a generated column and test failures.
- Benchmark ingest speed for different batch sizes of JSON arrays.
  jsonb_to_recordset bridges schemaless ingest with relational constraints, enabling set-based UPSERT without staging tables.

## Summary (Cheat Sheet)

- **Ingest Array of Objects**: Use jsonb_to_recordset for set-based ingest in one round trip. Validate row count matches input length. Prefer UNNEST for narrow fixed columns.
- **Sparse Wide Objects**: Use recordset with selective columns to ignore unknown keys; note uncaptured keys are lost. Consider a staging table for heavy validation.
- **Upsert with Freshness**: Use ON CONFLICT with a WHERE updated_at < EXCLUDED.updated_at to avoid stale overwrite. Beware clock skew; compare timestamp source or use version columns.
- **Partial Column Set**: Omit unspecified columns for simplicity; defaults apply. Generated columns help derived fields.
- **Validation**: Use CHECK/domain constraints for shape; invalid rows abort the batch. Pre-validate in app for better UX.
- **Large Batch**: Keep JSON size moderate to limit parse cost; monitor memory; chunk into multiple calls if needed.
- **Dynamic Schema**: Add columns as needed, but review schema to prevent hidden drift. Migrate once stable.
- **Audit**: Include a source metadata column for traceability; validate ingestion metrics. Use staging if audit is complex.
- **Pitfalls**: Wrong column order causing mis-mapped types; over-large documents causing slow ingest. Use explicit field lists; split files.

Guideline: Use recordset for moderately wide semi-structured batches; switch to staging when validation complexity rises.

## References

- json_to_recordset / jsonb_to_recordset: https://www.postgresql.org/docs/current/functions-json.html#FUNCTIONS-JSON-PROCESSING-TABLES
- LATERAL joins: https://www.postgresql.org/docs/current/queries-table-expressions.html#QUERIES-LATERAL
- SQL/JSON path queries: https://www.postgresql.org/docs/current/functions-json.html#FUNCTIONS-SQLJSON-PATH
