# nova_crm — PostgreSQL CRM Database

A relational CRM database built in raw SQL on PostgreSQL 18, modeling the full lifecycle from first contact → qualified lead → paying customer → orders, with an interaction log across every channel.

The repo is structured as one evolving system — each file builds on the last:

| File | What it adds |
|------|--------------|
| `01-crm-database.sql` | Core schema: `contacts` + `interactions`, CRUD patterns, upsert via `ON CONFLICT ... DO UPDATE`, FK enforcement, `updated_at` trigger |
| `02-lead-manager.sql` | `leads` table with CHECK-constrained score/stage, three-table JOINs, GROUP BY / HAVING reporting, neglected-leads report |
| `02b-session-b-subqueries-ctes.sql` | Subqueries (scalar, IN / NOT IN with NULL guard, correlated, derived tables), CTEs and CTE chaining, `DISTINCT ON` newest-row-per-group idiom |
| `03-customer-portal.sql` | `customers` (one-to-at-most-one via UNIQUE FK) + `orders` (NUMERIC money, CHECK status), lead→customer promotion via `INSERT ... SELECT`, portal reports with `FILTER (WHERE ...)` aggregates, FK indexing with measured EXPLAIN ANALYZE results |

## Schema at a glance

```
contacts 1 ──< interactions      (activity log, CHECK-constrained channel)
contacts 1 ──< leads             (score: Hot/Warm/Cold · stage pipeline)
contacts 1 ──1 customers         (UNIQUE FK — a contact converts at most once)
customers 1 ──< orders           (NUMERIC(10,2) amounts, status CHECK)
```

Design choices worth noting:

- **CHECK constraints over native ENUMs** for category columns — same integrity guarantee, far easier to amend later.
- **Shared `set_updated_at()` trigger function** reused across tables instead of per-table duplicates.
- **Upsert on a stable natural key** (`email`) so re-imports update rather than duplicate.
- **Money as `NUMERIC(10,2)`**, never floating point.

## Performance: measured, not assumed

`03-customer-portal.sql` includes an indexing section backed by real `EXPLAIN ANALYZE` runs against a ~5,000-contact seeded dataset:

- Un-indexed FK lookup: Seq Scan reading the whole table → **Bitmap Index Scan** after `idx_orders_customer_id` (buffers 45 → 6).
- Correlated subquery counting orders per customer: **~277 ms → ~4.6 ms (~60× faster)** after indexing — same query shape, cheaper per loop.
- The planner **kept a Seq Scan** where the filter matched ~1/3 of the table — an index is an option offered to the planner, not an order.
- A JOIN + GROUP BY rewrite matched the indexed correlated subquery at this volume but wins on shape at scale: one pass instead of one loop per row.

Indexes follow `idx_<table>_<column>` naming; only frequently-filtered FK columns are indexed, since every index adds write cost.

## Running it

Requires PostgreSQL (developed on 18.4 via Postgres.app).

```bash
createdb nova_crm
psql -d nova_crm -f 01-crm-database.sql
psql -d nova_crm -f 02-lead-manager.sql
psql -d nova_crm -f 02b-session-b-subqueries-ctes.sql
psql -d nova_crm -f 03-customer-portal.sql
```

Files are ordered and idempotent-friendly — later files assume the earlier schema exists.

## Roadmap

- FastAPI layer exposing the portal queries as REST endpoints
