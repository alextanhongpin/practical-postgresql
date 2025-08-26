# Advisory Locks (One at a Time)

## Problem / Context

You have a nightly job that sometimes starts twice from two workers, causing duplicated emails. You want only one to run at a time without adding new infrastructure.

## Core Concept

- Advisory locks are app‑defined mutexes keyed by integers. They’re separate from row/table locks.
- Two flavors: session locks (held until released/connection closes) and transaction locks (auto‑release on commit/rollback).
- Prefer try‑lock variants when skipping is acceptable.

Advisory locks are simple, app-controlled locks. Use them when you want only one session to run a piece of work at a time. They do not lock tables or rows for you. You pick a key; Postgres keeps a lock on that key.

## Implementation (step by step SQL)

Examples:

- “Run the nightly job once, even if 5 workers start it.”
- “Make sure only one process rebuilds a report right now.”

## Two types

- Session lock: stays until you release it or the connection closes.
- Transaction lock: releases automatically on COMMIT or ROLLBACK.

Use a transaction lock for short critical sections. Use a session lock if the protected work spans multiple statements or transactions.

## Core calls (single 64-bit key)

- `pg_advisory_lock(bigint)` waits until the key is free.
- `pg_try_advisory_lock(bigint)` returns immediately with true/false.
- `pg_advisory_xact_lock(bigint)` is like `pg_advisory_lock` but auto-releases at transaction end.
- `pg_advisory_unlock(bigint)` releases a session lock.

There are also two-key versions that take two 32-bit integers, for example: `pg_advisory_lock(int, int)`. This is handy to “namespace” a lock, such as (tenant_id, resource_id).

## Basic usage

```sql
SELECT pg_advisory_lock(12345);  -- acquire
-- do critical work
SELECT pg_advisory_unlock(12345); -- release
```

Transaction-scoped:

```sql
BEGIN;
SELECT pg_advisory_xact_lock(67890);
-- work
COMMIT; -- auto release
```

Non-blocking attempt:

```sql
SELECT pg_try_advisory_lock(42) AS got; -- run only if got = true
```

## Hashing text names into keys

You can hash a string to a 64-bit key for the single-key functions:

```sql
SELECT pg_try_advisory_lock(hashtextextended('nightly-maintenance', 0));
```

For two-key functions (each key is 32-bit), use `hashtext` for both parts:

```sql
SELECT pg_try_advisory_lock(hashtext('tenant:7'), hashtext('refresh-report'));
```

## Pattern: idempotent job runner

Your job runner can do a quick check like this:

```sql
WITH attempt AS (
  SELECT pg_try_advisory_lock(hashtext('job:daily-email')) AS ok
)
SELECT CASE WHEN ok THEN 'run' ELSE 'skip' END FROM attempt;
```

If it returns “skip”, another worker already holds the lock.

## Pattern: per-account mutex

```sql
CREATE OR REPLACE FUNCTION process_account(_acct BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  locked BOOLEAN;
BEGIN
  SELECT pg_try_advisory_lock(_acct) INTO locked;
  IF NOT locked THEN
    RAISE NOTICE 'Account % busy; skip', _acct;
    RETURN;
  END IF;

  -- Ensure we always release the lock
  BEGIN
    -- critical work here
    NULL; -- placeholder
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_advisory_unlock(_acct);
    RAISE; -- bubble up the error
  END;

  PERFORM pg_advisory_unlock(_acct);
END;
$$;
```

## Pitfalls (in plain words)

- Forgetting to release a session lock keeps it held until the connection ends.
- Holding a lock while doing slow work makes other sessions wait.
- Hash collisions (rare) can serialize unrelated work. Use two-key locks to reduce risk.
- Sometimes row locks (`SELECT ... FOR UPDATE`) are a better, simpler fit.
- Be consistent in how you build keys across services. The same work must map to the same key.
- Avoid taking multiple advisory locks in different orders across code paths; that can deadlock.

Tip: when skipping is okay, prefer `pg_try_advisory_lock` over waiting. You can also set `statement_timeout` to avoid waiting too long.

## Monitoring locks

See who holds what:

```sql
SELECT pid,
       locktype,
       classid,
       objid,
       objsubid,
       pg_blocking_pids(pid) AS blocked_by
FROM pg_locks
WHERE locktype = 'advisory';
```

Count them:

```sql
SELECT COUNT(*) FROM pg_locks WHERE locktype = 'advisory';
```

## Good practices

- Keep the critical section small.
- Prefer the try variant when you can skip.
- Log how long you hold the lock for jobs that may grow over time.
- Use two-key locks (or a clear naming scheme) to avoid accidental collisions.
- Remember: these locks are in-memory and do not survive a server restart.

## When not to use

- Enforcing relational rules (let UNIQUE/FK constraints do that).
- High-frequency per-row writes where row-level locks are enough.
- Cross-database or cross-service coordination (consider an external lock service).

## Variations and Trade‑Offs

- Single 64‑bit vs two 32‑bit keys: the two‑key form helps reduce accidental collisions and gives a natural namespace.
- Session locks survive across transactions but not restarts; transaction locks auto‑release, which is safer for short tasks.
- External lock services (like Redis/etcd) can coordinate across databases/services, but add complexity.

## Recap (Short Summary)

Advisory locks are a small mutex toolkit built into Postgres. Use them on purpose, keep the locked work short, and release quickly. They prevent duplicate work without new infrastructure.

## Optional Exercises

- Wrap a maintenance job with pg_try_advisory_lock(hashtextextended('job:nightly',0)) and log if it skips.
- Convert a session‑scoped lock to a transaction‑scoped one and observe behavior on errors.
- Build a two‑key scheme: (tenant_id, 'recalc') using hashtext for the second key.

## Summary (Cheat Sheet)

- **Purpose**: Lightweight mutual exclusion keyed by app-defined integer(s).
- **Acquire**: pg_advisory_lock, pg_try_advisory_lock, or pg_advisory_xact_lock.
- **Release**: pg_advisory_unlock or at transaction end.
- **Key Strategy**: Hash string names; prefer two keys to reduce collisions.
- **Use Cases**: Singleton job runner, per-account serialization, rare critical sections.
- **Pitfalls**: Forgotten unlocks, long-held locks, hash collisions, inconsistent keying.
- **Monitoring**: Inspect pg_locks where locktype = 'advisory'.
- **Alternatives**: Row locks or an external distributed lock service.

## References

- Advisory locks: https://www.postgresql.org/docs/current/explicit-locking.html#ADVISORY-LOCKS
