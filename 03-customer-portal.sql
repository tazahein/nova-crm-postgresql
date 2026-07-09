-- ============================================================
-- 03 — CUSTOMER PORTAL
-- Extends the CRM: a lead that reaches stage 'Won' becomes a
-- customer; the portal answers "what did I order, what did I
-- spend." Covers one-to-at-most-one relationships, money columns,
-- subqueries, CTEs, per-aggregate FILTERs, FK indexes, and
-- reading query plans with EXPLAIN.
-- ============================================================

-- ------------------------------------------------------------
-- 1. SCHEMA
-- ------------------------------------------------------------

-- customers: one-to-AT-MOST-one with contacts.
-- The UNIQUE constraint on the FK is what enforces "at most one
-- customer record per contact" — without it this would be a
-- plain one-to-many. UNIQUE is implemented as an index, so this
-- column is also indexed for free.
-- DATE (not TIMESTAMPTZ) because "customer since" is a calendar
-- fact — no time or timezone component needed.
CREATE TABLE customers (
    id         SERIAL PRIMARY KEY,
    contact_id INTEGER UNIQUE NOT NULL REFERENCES contacts(id),
    since      DATE DEFAULT CURRENT_DATE,
    status     TEXT NOT NULL DEFAULT 'Active'
               CHECK (status IN ('Active', 'Paused', 'Churned')),
    created_at TIMESTAMPTZ DEFAULT now()
);

-- orders: the money table.
-- NUMERIC(10,2) for exact decimal money — never FLOAT, which
-- accumulates rounding errors. CHECK (amount >= 0) rejects
-- negative amounts at the database layer, no matter which app
-- or script does the insert.
CREATE TABLE orders (
    id          SERIAL PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers(id),
    description TEXT,
    amount      NUMERIC(10,2) NOT NULL CHECK (amount >= 0),
    status      TEXT NOT NULL DEFAULT 'Pending'
                CHECK (status IN ('Pending', 'Paid', 'Refunded')),
    created_at  TIMESTAMPTZ DEFAULT now(),
    updated_at  TIMESTAMPTZ DEFAULT now()
);

-- Reuse the shared updated_at trigger function (defined in 01):
-- functions belong to the database, not to a table — one function,
-- one CREATE TRIGGER per table.
CREATE TRIGGER orders_updated_at
BEFORE UPDATE ON orders
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

-- ------------------------------------------------------------
-- 2. PROMOTION: Won leads become customers
-- ------------------------------------------------------------

-- INSERT ... SELECT: feed an insert from a query instead of
-- hand-typed ids. Sequence-gap-proof — no guessed ids, and the
-- business rule ("Won = customer") lives in the SQL itself.
INSERT INTO customers (contact_id)
SELECT contact_id
FROM leads
WHERE stage = 'Won';

-- Sample orders.
INSERT INTO orders (customer_id, description, amount, status) VALUES
    (1, 'Lead scoring automation',   320.00, 'Paid'),
    (1, 'Appointment booking bot',   180.00, 'Paid'),
    (1, 'Workflow maintenance',      250.00, 'Pending'),
    (2, 'Appointment booking bot',   180.00, 'Paid'),
    (2, 'Auto-responder setup',       90.00, 'Pending');

-- ------------------------------------------------------------
-- 3. PORTAL REPORTS
-- ------------------------------------------------------------

-- 3.1 Order history — three-table JOIN (orders → customers →
-- contacts). Always add a unique tiebreaker (id DESC) after a
-- timestamp sort: rows inserted in one batch share an identical
-- now() timestamp (transaction start time), so the timestamp
-- alone does not guarantee a stable order.
SELECT ct.name, o.description, o.amount, o.status, o.created_at
FROM orders o
JOIN customers c  ON o.customer_id = c.id
JOIN contacts  ct ON c.contact_id  = ct.id
ORDER BY o.created_at DESC, o.id DESC;

-- 3.2 Customer summary — FILTER (WHERE ...) applies a condition
-- to ONE aggregate at a time, so paid vs pending totals come out
-- as separate columns in a single pass over the data.
SELECT
    ct.name,
    COUNT(o.id)                                        AS order_count,
    SUM(o.amount)                                      AS total_amount,
    SUM(o.amount) FILTER (WHERE o.status = 'Paid')     AS paid_total,
    SUM(o.amount) FILTER (WHERE o.status = 'Pending')  AS pending_total
FROM customers c
JOIN contacts ct ON c.contact_id = ct.id
LEFT JOIN orders o ON o.customer_id = c.id
GROUP BY ct.name;

-- 3.3 Above-average orders — a scalar subquery in WHERE.
-- Aggregates are not allowed directly in WHERE (WHERE filters raw
-- rows before any aggregation exists), so the average is computed
-- in a subquery. ROUND(...,2) because AVG of NUMERIC(10,2)
-- returns unconstrained NUMERIC with a long decimal tail.
SELECT id, description, amount
FROM orders
WHERE amount > (SELECT AVG(amount) FROM orders);

-- 3.4 Same benchmark as a CTE — the average is defined in exactly
-- ONE place, then CROSS JOINed onto every row (a 1-row CTE glued
-- to each row). Duplicating the same subquery in multiple spots
-- invites logic drift; a CTE names it once.
WITH avg_order AS (
    SELECT ROUND(AVG(amount), 2) AS avg_amount
    FROM orders
)
SELECT o.id, o.description, o.amount,
       a.avg_amount,
       o.amount - a.avg_amount AS diff_from_avg
FROM orders o
CROSS JOIN avg_order a
ORDER BY diff_from_avg DESC;

-- 3.5 Big spenders — a CTE for per-customer paid totals, then a
-- subquery ON the CTE for the benchmark. Once aggregation happens
-- inside the CTE, paid_total is just a column: no HAVING
-- gymnastics needed in the outer query, plain WHERE works.
WITH customer_totals AS (
    SELECT
        c.id,
        ct.name,
        SUM(o.amount) FILTER (WHERE o.status = 'Paid') AS paid_total
    FROM customers c
    JOIN contacts ct ON c.contact_id = ct.id
    LEFT JOIN orders o ON o.customer_id = c.id
    GROUP BY c.id, ct.name
)
SELECT name, paid_total
FROM customer_totals
WHERE paid_total > (SELECT AVG(paid_total) FROM customer_totals);

-- 3.6 Latest order per customer — DISTINCT ON, the Postgres
-- newest-row-per-group idiom: DISTINCT ON (key) keeps the FIRST
-- row per key, and the ORDER BY decides which row comes first.
SELECT DISTINCT ON (o.customer_id)
       o.customer_id, ct.name, o.description, o.amount, o.created_at
FROM orders o
JOIN customers c  ON o.customer_id = c.id
JOIN contacts  ct ON c.contact_id  = ct.id
ORDER BY o.customer_id, o.created_at DESC, o.id DESC;

-- ------------------------------------------------------------
-- 4. INDEXES + EXPLAIN
-- ------------------------------------------------------------

-- Postgres auto-indexes PRIMARY KEY and UNIQUE columns only.
-- Plain FK columns are NOT auto-indexed — and FK columns are
-- exactly what JOINs and lookups filter on, so they are usually
-- the first candidates for a manual index.
CREATE INDEX idx_orders_customer_id       ON orders (customer_id);
CREATE INDEX idx_interactions_contact_id  ON interactions (contact_id);
CREATE INDEX idx_leads_contact_id         ON leads (contact_id);

-- Reading plans (measured on ~4K orders / ~1K customers of test
-- volume — tiny tables always Seq Scan, plans only get
-- interesting with data):
--
--   EXPLAIN ANALYZE SELECT * FROM orders WHERE customer_id = 42;
--
-- Before the index: Seq Scan, all rows read, ~45 buffers.
-- After: Bitmap Index Scan using idx_orders_customer_id, 6 buffers.
--
-- A correlated subquery (per-customer order count) dropped from
-- ~277 ms to ~4.6 ms: the per-row loops still happen — an index
-- cannot change a query's SHAPE — but each loop became an
-- Index Only Scan (answered from the index alone, zero table
-- fetches, since customer_id is the only column COUNT needs).
--
-- Counterpoint: a query filtering status = 'Paid' (~1/3 of the
-- table) kept its Seq Scan even WITH indexes available — reading
-- most of a table sequentially is cheaper than thousands of
-- index jumps. An index is an option offered to the planner,
-- not an order. Verify with EXPLAIN; don't assume.
--
-- Cost side: every index is a separate structure kept in sync on
-- every INSERT/UPDATE/DELETE. Index columns that are filtered or
-- joined on frequently; leave the rest alone.
