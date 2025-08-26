# Naming Conventions

Goal: predictable, readable, and consistent names.

## Problem / Context

You are a new engineer joining a team that ships fast. You inherit a database that has grown for years: some tables are CamelCase, others are snake_case; a few columns are called `ts`, `nm`, and `data`; there is a table named `user` that needs quotes everywhere; and two different `status` columns mean different things. Reviews take too long because people argue about names instead of behavior. Small migrations break because quoted identifiers and mixed styles cause mistakes. You need a simple, shared set of naming rules so everyone can guess names without looking them up and write queries without quoting.

## Rules

Good names remove friction. Adopt these and apply them everywhere:

- snake_case for all identifiers; no quoting required.
- Avoid reserved words such as `user`, `order` and `group`; prefer `app_user`, `purchase_order`, `user_group`.
- Relationships and booleans read clearly: `user_id`, `is_active`, `has_image`, `can_publish`.
- Name constraints and indexes to reveal intent: `chk_`, `fk_`, `idx_`, `uidx_`.
- Choose plural or singular table naming; pick one and be consistent.
- Consistency beats preference: once agreed, stick to it.
- **Tables**: many‑to‑many join tables combine both sides, e.g. `user_roles`.
- **Columns**: make counts/amounts explicit (e.g. `comment_count`, `total_cents`); include currency when storing money.
- **Functions & Triggers**: verbs + object (e.g. `recalculate_account_balance`); trigger functions name table + action (e.g. `trg_posts_set_updated_at`); document SECURITY DEFINER.
- **Types**: lowercase type names (e.g. `order_status`); enum values lowercase (e.g. `'pending'`, `'paid'`).
- **Schemas**: split by concern (e.g. `auth`, `billing`, `analytics`, `internal`).

## Implementation

Start by taking an inventory, agree on rules, then rename safely in small steps.

# Naming Conventions (Practical Guide)

Goal: predictable, readable, and unquoted names that the team can guess without looking them up.

## Recommended Scheme (copy/paste for your team)

- Case & style: snake_case for all identifiers; never require quotes.
- Tables: pick plural or singular and stick to it. Example here uses plural: `users`, `orders`.
- Primary key: `id` as GENERATED ALWAYS AS IDENTITY.
- Foreign keys: `<entity>_id` (e.g., `user_id`, `order_id`).
- Timestamps: `created_at`, `updated_at`, optional `deleted_at` for soft delete.
- Booleans: prefixes `is_`, `has_`, `can_` (e.g., `is_active`, `has_image`).
- Money: integer cents + currency code (e.g., `amount_cents`, `amount_currency`).
- Enums/Types: lowercase type name (e.g., `order_status`), lowercase enum values (e.g., `'pending'`).
- Join tables (many‑to‑many): singular_singular in alphabetical order, e.g., `role_user` or conventional `user_roles`—pick one convention and keep it.
- Indexes & constraints (use clear, searchable prefixes):
  - Primary key: `pk_<table>` (e.g., `pk_users`)
  - Unique index: `uidx_<table>__<col1>[_<colN>]` (e.g., `uidx_users__email`)
  - Non‑unique index: `idx_<table>__<col1>[_<colN>]`
  - Foreign key: `fk_<from_table>__<to_table>` (e.g., `fk_orders__users`)
  - Check constraint: `chk_<table>__<topic>` (e.g., `chk_orders__amount_cents_nonneg`)
- Views/materialized views: optional prefixes `v_`, `mv_` if your team prefers.
- Schemas: split by concern as needed (`auth`, `billing`, `analytics`, `internal`).

Why: the scheme avoids reserved words, casing pitfalls, and cryptic abbreviations, and makes diffs/scans obvious.

## Quick Inventory (find risky names)

```sql
-- Mixed or non-lowercase tables (require quoting)
SELECT
	n.nspname AS schema,
	c.relname AS tableFROM pg_class c
	JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE
	-- c: ordinary table
	-- p: partitioned table
	-- v: view
	-- m: materialized view
	c.relkind IN ('r', 'p', 'v', 'm')
	AND c.relname <> lower(c.relname)
ORDER BY
	1,
	2;

-- Mixed or non-lowercase columns (require quoting)
SELECT
	table_schema,
	table_name,
	column_name
FROM
	information_schema.columns
WHERE
	column_name <> lower(column_name)
ORDER BY
	1,
	2,
	3;

-- Objects named like reserved words (consider renaming)
SELECT
	n.nspname,
	c.relname
FROM
	pg_class c
	JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE
	c.relkind IN ('r', 'p')
	AND c.relname IN ('user', 'order', 'group');
```

## Walkthrough: Rename a “bad” table safely

Example “bad” table:

```sql
-- Problems: reserved word (`User`), mixed case (needs quotes), cryptic names, unclear timestamp type
CREATE TABLE "User" (
   "Id" SERIAL PRIMARY KEY,
   "Nm" TEXT,
   "TS" TIMESTAMP,
   email TEXT UNIQUE
);
```

Target (good) outcome:

```sql
CREATE TABLE users (
   id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
   name TEXT NOT NULL,
   created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
   email TEXT NOT NULL,
   CONSTRAINT uidx_users__email UNIQUE (email)
);
```

### Strategy

- Renames are metadata-only but briefly take an AccessExclusiveLock. They’re quick, but schedule during low traffic.
- If the app still references old names, keep a short‑lived compatibility view.
- If you must avoid any write disruption, use the “add new column + backfill + swap” pattern for columns instead of `RENAME COLUMN`.

### Steps (downtime‑minimal)

#### 1. Rename the table away from reserved/mixed case

```sql
ALTER TABLE "User" RENAME TO users;
```

#### 2. Rename columns to clear, conventional names

```sql
ALTER TABLE users RENAME COLUMN "Nm" TO name;
ALTER TABLE users RENAME COLUMN "TS" TO created_at;
```

#### 3. Fix types/defaults (optional but recommended)

```sql
-- TIMESTAMP -> TIMESTAMPTZ and add default
ALTER TABLE users
   ALTER COLUMN created_at TYPE timestamptz USING created_at AT TIME ZONE 'UTC',
   ALTER COLUMN created_at SET DEFAULT now(),
   ALTER COLUMN created_at SET NOT NULL;

-- Move from SERIAL to IDENTITY (optional modernization)
-- Note: confirms existing sequence ownership first; do this in a quiet window.
ALTER TABLE users ALTER COLUMN id DROP DEFAULT;         -- breaks SERIAL link
DROP SEQUENCE IF EXISTS "User_Id_seq";                 -- name may vary
ALTER TABLE users ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY;
```

#### 4. Rename constraints and indexes for clarity

```sql
-- Primary key
ALTER TABLE users RENAME CONSTRAINT "User_pkey" TO pk_users;  -- if present

-- Unique index on email (recreate with clear name if needed)
DO $$ BEGIN
   IF EXISTS (
      SELECT 1 FROM pg_indexes WHERE schemaname = 'public'
         AND indexname = '"User_email_key"'
   ) THEN
      ALTER INDEX "User_email_key" RENAME TO uidx_users__email;
   END IF;
END $$;

-- Or ensure existence explicitly
CREATE UNIQUE INDEX IF NOT EXISTS uidx_users__email ON users(email);
```

#### 5. Backward‑compatibility (temporary)

```sql
-- Read‑only compatibility view for old code paths
CREATE OR REPLACE VIEW "User" AS
SELECT id, name, created_at, email FROM users;

-- If writes to the old name are still happening, add simple rules (optional)
-- INSERT example:
CREATE OR REPLACE RULE user_insert_redirect AS
ON INSERT TO "User" DO INSTEAD
   INSERT INTO users(id, name, created_at, email)
   VALUES (NEW.id, NEW.name, NEW.created_at, NEW.email);
```

#### 6. Recheck privileges and comments

```sql
-- Renames keep privileges, but new objects (views/rules) may need grants
GRANT SELECT ON users TO readonly;
COMMENT ON TABLE users IS 'Application users (human accounts)';
COMMENT ON COLUMN users.created_at IS 'Creation timestamp (UTC)';
```

#### 7. Cutover and cleanup

```sql
-- After application is deployed and no longer uses the old name
DROP VIEW IF EXISTS "User" CASCADE;  -- removes rules attached to the view
```

### Zero‑downtime column rename pattern (alternative)

When renaming a hot column without locking DDL:

1. Add new column (e.g., `ALTER TABLE users ADD COLUMN created_at timestamptz;`).
2. Backfill in chunks; keep in sync via triggers if needed.
3. Update app to read/write the new column.
4. Remove old column in a later migration.

## Enforce going forward

- Publish the scheme above in your repo (README/PR template).
- Add a CI check that flags non‑lowercase identifiers and reserved words.
- Review migrations for constraint/index names that follow the prefixes.

## Pitfalls

- Quoted identifiers force quoting everywhere; stick to snake_case.
- Reserved words like `user`, `order`, `group` create friction; avoid them.
- SERIAL leaves behind sequences; prefer modern IDENTITY columns.
- Grants on newly created compatibility objects (views/rules) aren’t automatic.
- ORMs may cache metadata; coordinate DB and app deploys.

## References

- Identifiers and quoting: https://www.postgresql.org/docs/current/sql-syntax-lexical.html#SQL-SYNTAX-IDENTIFIERS
- Reserved key words: https://www.postgresql.org/docs/current/sql-keywords-appendix.html
- COMMENT ON: https://www.postgresql.org/docs/current/sql-comment.html
- ALTER TABLE RENAME: https://www.postgresql.org/docs/current/sql-altertable.html
- Identity columns (vs SERIAL): https://www.postgresql.org/docs/current/ddl-identity-columns.html
