# Testing Strategy

## Problem / Context

Bugs slip past mocked database layers because SQL, constraints, and triggers are not exercised. You want fast, reliable tests that use a real Postgres instance, isolate data per test run, and avoid flaky assertions.

## Pyramid

1. Unit (pure logic / SQL fragments)
2. Integration (real DB)
3. Contract / API

## Core Concept

- Prefer a real database for integration tests and isolate state per test run.
- Keep data setup minimal and explicit via factories; avoid heavy fixtures.
- Make time and randomness deterministic to reduce flakes.

## Implementation (Step by Step SQL)

## Real DB over Mocks

- Exercise SQL, constraints, triggers.
- Catch migration drift.

## Test DB Lifecycle

- Dedicated database per test run.
- Schema migrated up (no down needed).
- Wrap each test in transaction + rollback OR use template cloning.

## Parallelism

- One DB per worker process to avoid lock contention.

## Data Isolation Options

| Technique            | Pros         | Cons                   |
| -------------------- | ------------ | ---------------------- |
| Transaction Rollback | Fast         | No cross-conn coverage |
| Truncate Tables      | Cross-conn   | Slower, need FK defers |
| Template DB Clone    | Near-instant | Requires superuser     |

## Determinism

- Freeze time (e.g. set timezone, mock clock source).
- Seed RNG.
- Avoid relying on implicit ordering.

## Flaky Sources

- Timeouts too tight.
- Non-deterministic ORDER BY.
- Background workers not synchronized.

## Assertions

Prefer structural over incidental:

- Assert row count, key presence, invariant truths.
- Avoid matching full JSON if only one field matters.

## Tooling

- pgTAP for SQL-level tests (optional).
- App language test framework (Go testing, etc.).

## Variations and Trade‑Offs

- Transaction rollback vs template clone: rollback is fast and simple; template clone isolates cross-connection effects but needs privileges.
- Factories vs fixtures: factories are flexible and minimal; fixtures are easy to get started but grow brittle.
- Dockerized DB vs local cluster: Docker is portable; local cluster can be faster with less setup.

## Pitfalls

- Relying on implicit ordering causes random failures; always ORDER BY.
- Global mutable state across tests creates heisenbugs; avoid shared singletons.
- Mocked DB layers miss constraint/trigger behavior; run integration tests regularly.

## Recap (Short Summary)

Use a real DB, isolate state per test, keep data setup minimal and explicit, and make time/random deterministic to avoid flakes.

## Optional Exercises

- Add ORDER BY to a failing flaky test and verify stability.
- Replace a large YAML fixture with a factory helper and compare readability.
- Switch from rollback to template DB cloning in CI and measure speed vs isolation.
  Use a real database, isolate fast, keep fixtures lean, and focus on invariants not brittle snapshots.

## Summary (Cheat Sheet)

- **DB Realism**: Use a real Postgres instance to catch SQL issues early; accept setup overhead (Docker/local cluster).
- **Isolation**: Use transaction rollback or template clone for deterministic tests; template needs privileges; transactions are fast.
- **Parallelism**: One DB per worker to avoid lock contention; watch resource usage; template cloning helps.
- **Data Setup**: Use factories plus minimal seeds for clear intent; more helper code; factory functions.
- **Deterministic Time**: Freeze the clock for stable assertions; add a time helper abstraction.
- **Randomness**: Seed the RNG for reproducibility; track global seed.
- **Slow Tests**: Profile and move up the pyramid for faster feedback; tag tests.
- **Flakiness**: Make ORDER BY explicit to avoid nondeterministic order; stabilize suite.
- **Schema Drift**: Migrate fresh each run to catch missing migrations; cache template to speed startup.
- **Cleanup**: Roll back or drop DBs to avoid residual state; use harness scripts.
- **Assertion Scope**: Prefer structural invariants over brittle snapshots; use domain-specific asserts.
- **Pitfalls**: Over-mocking hides integration bugs; massive fixtures increase debug time; refactor to factories.

Principle: Aim for high signal and low brittleness to build trust in failures.

## References

- https://www.postgresql.org/docs/current/sql-rollback.html
- https://www.postgresql.org/docs/current/functions-admin.html#FUNCTIONS-ADVISORY-LOCKS
- https://www.postgresql.org/docs/current/manage-ag-config.html#MANAGE-AG-CONFIG-CREATE-DB-TEMPLATE
