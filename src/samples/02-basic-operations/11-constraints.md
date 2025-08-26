# Constraints (Rules the Database Enforces)

## Problem / Context

Your team keeps shipping validations in app code, but data still goes bad when scripts or new services bypass checks. You want the database to reject invalid rows so bugs stop at the door. PostgreSQL constraints make rules first-class and visible in schema.

## Core Concept

Constraints are declarative rules that PostgreSQL enforces automatically. They block bad writes and keep data clean regardless of how it’s written (app, script, or psql).

Core types:

- **PRIMARY KEY**: unique row id; implies NOT NULL and UNIQUE.
- **UNIQUE**: no duplicate values in a column or a set of columns.
- **CHECK**: a per-row rule that must be true.
- **FOREIGN KEY**: child values must exist in the parent table.

## Implementation

### 1. CHECK (custom rule)

```sql
CREATE TABLE products (
  id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  price NUMERIC(10,2) NOT NULL,
  CONSTRAINT chk_products_price_positive CHECK (price > 0)
);
```

Outcome: inserting a negative price fails.

### 2. UNIQUE (no duplicates)

```sql
CREATE TABLE users (
  id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email TEXT NOT NULL,
  CONSTRAINT uidx_users_email UNIQUE (email)
);
```

You can also make a unique rule on many columns (for example, one row per (user_id, year)).

### 3. Naming style

Name constraints for clarity and easy ALTER/DROP:

- `pk_<table>`
- `uidx_<table>_<col>`
- `chk_<table>_<meaning>`
- `fk_<table>_<refcol>`

Example:

```sql
CREATE TABLE orders (
  id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id INT NOT NULL,
  total NUMERIC(10,2) NOT NULL,
  CONSTRAINT fk_orders_user_id FOREIGN KEY (user_id) REFERENCES users(id),
  CONSTRAINT chk_orders_total_positive CHECK (total >= 0)
);
```

### 4. Deferrable constraints (check at commit)

Hypothetical: you keep a ranked list with a UNIQUE position. You need to swap positions of two items. If uniqueness is checked on each UPDATE, the first update fails. You want the database to allow temporary duplicates during the transaction and only check at COMMIT.

Deferrable makes this work. PostgreSQL checks these constraints at COMMIT, not at each row change.

How to declare

- Add DEFERRABLE to a FOREIGN KEY or UNIQUE constraint.
- Choose INITIALLY DEFERRED (default to end-of-transaction checks) or INITIALLY IMMEDIATE (check now, but you can defer inside a transaction).

Temporarily defer inside a transaction

```sql
BEGIN;
  SET CONSTRAINTS ALL DEFERRED;             -- or a specific name
  -- do your updates/inserts here
COMMIT;                                     -- checks run now
```

Example A: swapping positions with a deferrable UNIQUE

```sql
CREATE TABLE list_items (
  id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  position INT NOT NULL,
  CONSTRAINT uidx_list_items_position UNIQUE (position) DEFERRABLE INITIALLY DEFERRED
);

BEGIN;
  UPDATE list_items SET position = 0 WHERE position = 1; -- temporary duplicate/gap allowed
  UPDATE list_items SET position = 1 WHERE position = 2;
  UPDATE list_items SET position = 2 WHERE position = 0;
COMMIT; -- uniqueness checked here
```

Without DEFERRABLE, the first UPDATE would violate uniqueness.

Example B: insert child before parent with a deferrable FOREIGN KEY

```sql
CREATE TABLE users (
  id INT PRIMARY KEY
);

CREATE TABLE invoices (
  id INT PRIMARY KEY,
  user_id INT NOT NULL,
  CONSTRAINT fk_invoices_user_id
    FOREIGN KEY (user_id) REFERENCES users(id)
    DEFERRABLE INITIALLY DEFERRED
);

BEGIN;
  INSERT INTO invoices (id, user_id) VALUES (1, 100); -- parent 100 not yet present
  INSERT INTO users (id) VALUES (100);                 -- parent arrives later
COMMIT;                                               -- FK checked now and passes
```

Self-reference also works the same way (a row pointing to another row in the same table). Define the FK as DEFERRABLE to allow a sequence of updates/inserts that is only valid at the end.

Notes

- Use constraint syntax (ALTER TABLE ... ADD CONSTRAINT ... UNIQUE/FOREIGN KEY). A raw CREATE UNIQUE INDEX cannot be DEFERRABLE.
- Keep all related changes inside one transaction. Mid-transaction states can be invalid, and other sessions will not see a globally valid state until COMMIT.
- INITIALLY IMMEDIATE + SET CONSTRAINTS ... DEFERRED lets you defer only in special code paths.
- Only UNIQUE/PRIMARY KEY/EXCLUSION and FOREIGN KEY can be deferrable. CHECK and NOT NULL are not deferrable.

Troubleshooting and migration

- Error: “constraint XYZ is not deferrable”
  - Check the flag:

  ```sql
  SELECT conname, deferrable, initially_deferred
  FROM pg_constraint
  WHERE conrelid = 'your_table'::regclass
    AND conname = 'your_constraint_name';
  ```

- SET CONSTRAINTS works only inside a transaction and only for deferrable constraints:

  ```sql
  BEGIN;
    SET CONSTRAINTS your_constraint_name DEFERRED;
    -- do work
  COMMIT;
  ```

- Make a FOREIGN KEY deferrable (low risk path)

  ```sql
  ALTER TABLE invoices
    DROP CONSTRAINT fk_invoices_user_id;
  ALTER TABLE invoices
    ADD CONSTRAINT fk_invoices_user_id
    FOREIGN KEY (user_id) REFERENCES users(id)
    DEFERRABLE INITIALLY IMMEDIATE
    NOT VALID;         -- skip full check now
  ALTER TABLE invoices
    VALIDATE CONSTRAINT fk_invoices_user_id;  -- check existing rows online
  ```

- Make a UNIQUE constraint deferrable
  - PostgreSQL does not support a deferrable unique index. Deferrable applies to the table constraint.
  - You cannot turn an existing unique index into a deferrable constraint in place.
  - Simple path (maintenance window):

    ```sql
    ALTER TABLE users DROP CONSTRAINT uidx_users_email; -- old unique
    ALTER TABLE users
      ADD CONSTRAINT uidx_users_email
      UNIQUE (email) DEFERRABLE INITIALLY DEFERRED;     -- new deferrable unique
    ```

  - Lower-lock idea (plan carefully): build a second unique index concurrently, switch to a deferrable unique constraint during a short window, then drop the old index.
    - Build index: CREATE UNIQUE INDEX CONCURRENTLY uidx_users_email_tmp ON users(email);
    - In a window, DROP the old constraint, ADD a new deferrable UNIQUE (which will create/attach an index), then DROP the extra index.
    - Test on staging first; exact locks depend on version.

### 5. Partial uniqueness and covering

For patterns like partial unique indexes and covering (INCLUDE) indexes, see the Indexes chapter. That chapter shows how to tailor uniqueness to active rows and how to include extra columns for faster reads.

## Variations and Trade‑Offs

- Domains: encapsulate common CHECK logic in a reusable type.
- Exclusion constraints: prevent overlapping ranges or conflicting values using GiST.
- Deferrable vs immediate: deferring unblocks swaps and batch changes, but hides invalid states until COMMIT and adds a bit of overhead. Use only when needed.
- Partial unique index vs table-level UNIQUE: partial is flexible but lives as an index (introspection differs).

## Pitfalls

- No constraints early → bad data and costly cleanups. Add PK, FK, and key CHECKs on day one.
- Unclear names make operations hard. Use pk*, fk*, uidx*, chk* prefixes consistently.
- Complex CHECK with subqueries can hurt performance and lock. Prefer triggers or periodic validators.
- Type/collation mismatches for FKs or UNIQUE across tables block creation.

## Recap

- Constraints declare rules the database enforces. They block bad data at the door.
- Use PRIMARY KEY, UNIQUE, CHECK, and FOREIGN KEY where they fit; name them clearly.
- Use DEFERRABLE when correctness depends on the end state of a transaction.
- Partial unique indexes and INCLUDE help tailor performance and business rules.

## Optional Exercises

- Add a CHECK to ensure price >= 0 and verify the error on a negative insert.
- Make (user_id, year) unique in a table and test with duplicates.
- Create a DEFERRABLE UNIQUE on position and perform a three-way swap in one transaction.
- Add a partial unique index on users(email) WHERE is_active and test activation toggles.

## References

- Constraints overview: https://www.postgresql.org/docs/current/ddl-constraints.html
- NOT VALID and VALIDATE CONSTRAINT: https://www.postgresql.org/docs/current/sql-altertable.html#SQL-ALTERTABLE-VALIDATE-CONSTRAINT
- Deferrable constraints: https://www.postgresql.org/docs/current/sql-createtable.html#SQL-CREATETABLE-CONSTRAINTS
- Exclusion constraints: https://www.postgresql.org/docs/current/ddl-constraints.html#DDL-CONSTRAINTS-EXCLUSION
