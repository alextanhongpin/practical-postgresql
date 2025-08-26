# Safe Migrations

## Problem / Context

You need to add columns, indexes, and constraints to production tables that serve live traffic. The goal is to change the schema safely with minimal blocking, clear rollback or roll‑forward options, and good communication.

## Core Concept

- Prefer two-phase changes: declare fast metadata first, move data gradually, validate last.
- Avoid long ACCESS EXCLUSIVE locks on hot tables; use CONCURRENTLY and NOT VALID where possible.
- Batch backfills, watch locks and replication lag, and be ready to roll forward instead of rolling back.

Goal: Apply DDL in production with minimal locks, clear rollback or roll-forward, and good communication.

## 1. Core Principles

- Small steps beat giant scripts.
- Wrap changes in a transaction when allowed (not for CREATE INDEX CONCURRENTLY, some ALTER TYPE).
- Avoid long ACCESS EXCLUSIVE locks on hot tables.
- Be able to pause or roll forward. Rolling back large partial changes is risky.

## 2. Standard Playbook

1. Plan (list risk ops: type changes, defaulted columns, big table rewrites)
2. Test on staging clone (row counts similar)
3. Backup or confirm PITR window healthy
4. Communicate window + fallback
5. Run migration tool (Flyway, Sqitch, Rails, etc.)
6. Monitor: locks, errors, replication lag
7. Validate post-change (schema, sample queries)

## 3. Change Catalog (where to find details)

This chapter is the high-level playbook. Detailed, copyable SQL lives in focused chapters:

- Add/rename/drop columns, backfills, SELECT-list safety → see [Safe Column Changes](03-columns.md)
- Table-level ops (rename table, split hot/cold, lock watching) → see [Safe Table Changes](02-table.md)
- Type evolution (enums, int→bigint, precision) → see [Safe Type Changes](04-types.md)
- Constraints (NOT VALID/VALIDATE, UNIQUE via index, NOT NULL safely) → see [Constraints](05-constraints.md)
- Roles & users for migration separation of duties → see [Roles & Users](06-roles-and-users.md)

Quick references

- Indexes on hot tables: CREATE INDEX CONCURRENTLY (details in [Safe Table Changes](02-table.md))
- Foreign keys on existing data: ADD ... NOT VALID then VALIDATE (details in [Constraints](05-constraints.md))
- Large type changes: shadow column + swap (details in [Safe Type Changes](04-types.md))
- Backfills: PK-ordered batches with small commits (details in [Safe Column Changes](03-columns.md))

## 4. Rollback vs Roll Forward

DDL rollback can be messy. Prefer forward fixes: create a missing index, adjust a new column, etc. Keep a quick revert script only for trivial additions if disaster strikes early.

## 5. Monitoring During Migration

Watch:

- `pg_stat_activity` for waiting queries
- `pg_locks` for long ACCESS EXCLUSIVE
- replication lag (if streaming replicas) to catch cascading delay

## 6. Checklist Before You Run

- Tested on realistic data size?
- Backup / PITR window verified?
- Scripts idempotent (re-run safe)?
- Long rewrites split into shadow columns?
- FKs / CHECK added with NOT VALID when large?
- Plan to backfill in batches documented?
- Communication + monitoring in place?

## 7. Common Pitfalls

| Mistake                                                 | Pain                            |
| ------------------------------------------------------- | ------------------------------- |
| Adding column WITH default on huge table (old versions) | Full table rewrite & lock       |
| Single transaction with many long steps                 | Lock pileups, hard rollback     |
| No batch size limit in backfill                         | Long running transaction, bloat |
| Dropping index before verifying replacement             | Sudden query regression         |

Start minimal, measure, iterate. Safety is structure + patience.

## 8. Variations and Trade‑Offs

- Tooling: Framework migrations vs. declarative tools (Sqitch/Flyway). Declarative reduces drift; framework integrates with app deploys.
- Zero-downtime app changes: Write‑through compatibility (support both schemas for a deploy), then cut over.
- Blue/green vs in‑place: Blue/green isolates risk but costs infra; in‑place is cheaper but needs careful lock control.

## 9. Pitfalls

- Adding defaults on very large tables in older Postgres versions triggers a table rewrite and long lock.
- Running CREATE INDEX (non‑CONCURRENTLY) on hot tables blocks writes.
- Single huge UPDATE backfills cause long transactions and bloat; always batch.

## 10. Recap (Short Summary)

Declare structure fast, migrate data gradually, validate correctness later. Use CONCURRENTLY and NOT VALID to keep locks short, and favor roll‑forward fixes.

## 11. Optional Exercises

- Add a NULLable column on a big table, backfill in batches, then set NOT NULL and DEFAULT.
- Build a UNIQUE constraint by creating the index CONCURRENTLY and attaching it.
- Add a FOREIGN KEY with NOT VALID, fix violations, then VALIDATE in a quiet window.

## 12. Summary (Cheat Sheet)

- **Planning**: Classify risky ops (rewrite, long scan) upfront. Impact: none. Mitigation: avoid surprise long locks. Tip: estimate sizes with pg_relation_size.
- **Adding Column**: Add NULLable without default; batch backfill; add default + NOT NULL last. Impact: metadata then short locks. Risk: table rewrite/long lock (older versions). Tip: PG 11+ skips rewrite for constant defaults.
- **Backfill**: Use small ordered batches (PK range/LIMIT) with commits. Impact: short transactions. Risk: bloat, autovacuum pressure. Tip: stop when 0 rows updated.
- **Creating Index**: Use CREATE INDEX CONCURRENTLY on hot/big tables. Impact: minimal blocking; two scans. Risk: read/write blocking avoided. Tip: not inside a transaction.
- **Unique Constraint**: Build unique index CONCURRENTLY then attach constraint. Impact: same as above. Risk: avoid long ACCESS EXCLUSIVE lock.
- **Foreign Key**: Add NOT VALID then VALIDATE later. Impact: fast add; later read-only scan. Risk: long blocking validation avoided. Tip: validate in low-traffic window.
- **Type Change (Large)**: Shadow column + batch copy + swap. Impact: bounded locks. Risk: table-wide rewrite avoided. Tip: keep old column until confident.
- **Monitoring**: Watch pg_stat_activity, pg_locks, replication lag. Impact: early detection. Risk: silent lock pileups.
- **Rollback Strategy**: Prefer roll forward fixes. Impact: avoids complex undo. Risk: half-applied states mitigated. Tip: keep tiny early revert script only.
- **Checklist Use**: Run pre-flight checklist before executing. Impact: none. Risk: missing safety steps. Tip: automate where possible.
- **Pitfalls**: WITH DEFAULT on huge table (older PG) → split add + default later; massive single UPDATE → batch + commit; no validation of new constraint → schedule VALIDATE and track.

Key Principle: Declare structure fast (metadata), migrate data gradually, validate correctness late.

## References

- CREATE INDEX CONCURRENTLY: https://www.postgresql.org/docs/current/sql-createindex.html#createindex-concurrently
- VALIDATE CONSTRAINT: https://www.postgresql.org/docs/current/sql-altertable.html#SQL-ALTERTABLE-VALIDATE-CONSTRAINT
- Explicit locking overview: https://www.postgresql.org/docs/current/explicit-locking.html
- Active sessions (pg_stat_activity): https://www.postgresql.org/docs/current/monitoring-stats.html#MONITORING-PG-STAT-ACTIVITY
- Locks view (pg_locks): https://www.postgresql.org/docs/current/view-pg-locks.html
- Replication lag (pg_stat_replication): https://www.postgresql.org/docs/current/monitoring-stats.html#MONITORING-PG-STAT-REPLICATION
