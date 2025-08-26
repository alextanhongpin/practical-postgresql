# Schemas and Tables

## Problem / Context

You’ve inherited a growing monolith database. Names collide, and accidental cross-feature queries cause bugs. You need a clean way to group objects per feature/team and create tables with safe defaults. PostgreSQL schemas give you namespaces, and well-structured tables make intent clear from day one.

## Core Concept

- A schema is a namespace that groups database objects (tables, views, functions). By default everything goes into `public`.
- A table stores rows. Always give tables a primary key—tools and ORMs expect it. Even for write-only logs, add an identity column for ordering and debugging.
- Prefer fully qualified names (for example, `auth.users`). Use schemas early to avoid name collisions and to manage permissions.
- Tip: `user` is reserved. Prefer `app_user` or `auth.user`. Avoid quoting identifiers unless necessary.

## Implementation

Follow these steps to organize with schemas and create solid tables.

### 1. Create a schema and a table

Create an `accounting` schema and a table inside it:

```sql
CREATE SCHEMA accounting;

CREATE TABLE accounting.invoices (
    id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id INT NOT NULL,
    amount NUMERIC(10,2) NOT NULL,
    issued_at TIMESTAMPTZ DEFAULT now()
);
```

Outcome: a new namespace and a table with clear types and a primary key.

### 2. Reuse table names safely across domains

Two departments track their own employee lists without conflicts:

```sql
CREATE SCHEMA sales;
CREATE SCHEMA hr;

CREATE TABLE sales.employees (
  id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name TEXT NOT NULL
);

CREATE TABLE hr.employees (
  id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name TEXT NOT NULL
);
```

Outcome: same table name, different schemas, no conflict.

### 3. Adopt schemas later (migration steps)

Move tables out of `public` with minimal risk:

1. Create the new schema.
2. Move tables:
   - `ALTER TABLE public.some_table SET SCHEMA app;`
3. Update code to reference `schema.table` (or adjust `search_path`).
4. Fix grants: ensure the app role has USAGE on the schema.
5. Lock down `public` if you no longer want new objects there.

### 4. Permissions quick-start

Grant usage on a schema to a role and limit writes as needed:

```sql
GRANT USAGE ON SCHEMA accounting TO app_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA accounting TO app_role;
```

## Variations and Trade‑Offs

- Staying in `public`: OK for prototypes or learning. As concerns split (auth, billing, analytics), add schemas.
- search_path: lets you omit schema prefixes, but can hide ambiguity. Prefer fully qualified names in migrations and critical code.
- Naming: choose predictable, lowercase names. Avoid reserved words. Don’t rely on quoted identifiers.
- Multi-tenant patterns: separate schemas per tenant can work for small numbers; for many tenants prefer a single schema with tenant_id.

## Pitfalls

- Putting everything in `public` leads to all-or-nothing permissions and name collisions.
- Using reserved names like `user` forces quoting and causes tool friction.
- Forgetting grants after moving tables—apps get “permission denied.”
- Relying on search_path differences between sessions can cause surprises.

## Recap

- Schemas split names and permissions. Use them early to avoid a messy `public` schema.
- Always define a primary key (even for logs) to make operations and debugging easier.
- Moving later is possible but touches names and permissions; plan grants and search_path.
- Prefer fully qualified names when clarity matters.

## Optional Exercises

1. Create two schemas (app, audit) and move an existing table into each. Adjust `search_path` to test resolution.
2. Add a role that can only SELECT from `audit.*`. Verify that a write fails.
3. Rename a table while moving it to a new schema in one migration (`ALTER TABLE ... SET SCHEMA ... RENAME TO ...`).
4. Create `hr.employees` and `sales.employees`, then write a query that unions them with a source column.
5. Lock down `public` so no new objects can be created there. Record the GRANT statements you changed.

## References

- Schemas and search path: https://www.postgresql.org/docs/current/ddl-schemas.html
- CREATE SCHEMA: https://www.postgresql.org/docs/current/sql-createschema.html
- CREATE TABLE: https://www.postgresql.org/docs/current/sql-createtable.html
- ALTER TABLE: https://www.postgresql.org/docs/current/sql-altertable.html
- Information schema: https://www.postgresql.org/docs/current/information-schema.html
