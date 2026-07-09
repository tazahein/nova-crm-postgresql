-- ============================================================
-- NOVA CRM — Session B: Subqueries & CTEs  (CORRECTED)
-- Database: nova_crm
-- All queries are READ-ONLY (SELECT only). Safe to run.
--
-- INSTRUCTIONS:
-- Run each numbered query against the nova_crm database using
-- psql, one at a time, and show the full output of each.
-- Example: psql -d nova_crm -c "<query>"
-- Do not modify any data. Do not run anything except these queries.
--
-- CORRECTIONS APPLIED vs. the original session-b-subqueries-ctes.sql:
--   * orders.total did not exist -> replaced with orders.amount
--     (the real money column is NUMERIC(10,2), named `amount`).
--   * interactions.created_at did not exist -> replaced with interactions.received_at
--     (the real timestamp column is `received_at TIMESTAMPTZ`).
--   * ROUND(..., 2) wrapped around AVG/SUM on NUMERIC to kill decimal
--     explosion (AVG/SUM of NUMERIC(10,2) returns unconstrained NUMERIC).
--   * 1.1 left as a FLAGGED query: lead_score is TEXT ('Hot'/'Warm'/'Cold'),
--     so AVG(lead_score) is invalid. A corrected, sensible alternative is
--     given as 1.1b (benchmark leads by a numeric value).
-- ============================================================


-- ------------------------------------------------------------
-- PART 1: SUBQUERIES
-- ------------------------------------------------------------

-- 1.1 ORIGINAL (FLAGGED — DOES NOT RUN):
-- lead_score is TEXT, so AVG(lead_score) raises:
--   ERROR: function avg(text) does not exist
-- There is no meaningful "average" of Hot/Warm/Cold. Kept here as a note
-- only; do NOT run. See 1.1b for a working version.
-- SELECT id, contact_id, lead_score, stage
-- FROM leads
-- WHERE lead_score > (SELECT AVG(lead_score) FROM leads)
-- ORDER BY lead_score DESC;

-- 1.1b CORRECTED ALTERNATIVE — benchmark leads by a NUMERIC value instead.
-- Example: find orders whose amount is above the average order amount.
-- (Swap in any numeric column you actually want to benchmark on.)
SELECT id, customer_id, amount, status
FROM orders
WHERE amount > (SELECT AVG(amount) FROM orders)
ORDER BY amount DESC;

-- 1.2 IN subquery: contacts who have at least one interaction.
-- The subquery returns a LIST of ids.
SELECT id, name, email
FROM contacts
WHERE id IN (SELECT DISTINCT contact_id FROM interactions);

-- 1.3 NOT IN subquery: contacts with NO interactions (the neglected ones).
-- Compare this result with your Session 4 LEFT JOIN version!
SELECT id, name, email
FROM contacts
WHERE id NOT IN (SELECT contact_id FROM interactions WHERE contact_id IS NOT NULL);

-- 1.4 Correlated subquery: for each customer, count their orders
-- WITHOUT using GROUP BY. The inner query runs once per outer row.
SELECT c.id,
       c.contact_id,
       (SELECT COUNT(*) FROM orders o WHERE o.customer_id = c.id) AS order_count
FROM customers c
ORDER BY order_count DESC;

-- 1.5 Subquery in FROM (a "derived table"): average order total per
-- customer, then filter customers averaging above 100.
-- CORRECTED: orders.total -> orders.amount ; added ROUND(...,2).
SELECT sub.customer_id, ROUND(sub.avg_total, 2) AS avg_total
FROM (
    SELECT customer_id, AVG(amount) AS avg_total
    FROM orders
    GROUP BY customer_id
) AS sub
WHERE sub.avg_total > 100
ORDER BY sub.avg_total DESC;


-- ------------------------------------------------------------
-- PART 2: CTEs (WITH clauses)
-- ------------------------------------------------------------

-- 2.1 Same query as 1.5, rewritten as a CTE. Compare readability.
-- CORRECTED: orders.total -> orders.amount ; added ROUND(...,2).
WITH customer_averages AS (
    SELECT customer_id, AVG(amount) AS avg_total
    FROM orders
    GROUP BY customer_id
)
SELECT customer_id, ROUND(avg_total, 2) AS avg_total
FROM customer_averages
WHERE avg_total > 100
ORDER BY avg_total DESC;

-- 2.2 Multi-CTE: two building blocks, then combine.
-- Block 1: interaction counts per contact.
-- Block 2: lead info per contact.
-- Final: contacts with a lead but ZERO interactions since becoming a lead.
WITH interaction_counts AS (
    SELECT contact_id, COUNT(*) AS n_interactions
    FROM interactions
    GROUP BY contact_id
),
lead_info AS (
    SELECT contact_id, lead_score, stage
    FROM leads
)
SELECT c.name,
       li.lead_score,
       li.stage,
       COALESCE(ic.n_interactions, 0) AS n_interactions
FROM lead_info li
JOIN contacts c ON c.id = li.contact_id
LEFT JOIN interaction_counts ic ON ic.contact_id = li.contact_id
ORDER BY li.lead_score DESC;

-- 2.3 CTE chaining: a CTE can reference an earlier CTE.
-- Revenue per customer -> then classify into tiers.
-- CORRECTED: orders.total -> orders.amount ; added ROUND(...,2) on output.
WITH revenue AS (
    SELECT customer_id, SUM(amount) AS lifetime_value
    FROM orders
    GROUP BY customer_id
),
tiers AS (
    SELECT customer_id,
           lifetime_value,
           CASE
               WHEN lifetime_value >= 500 THEN 'Gold'
               WHEN lifetime_value >= 200 THEN 'Silver'
               ELSE 'Bronze'
           END AS tier
    FROM revenue
)
SELECT customer_id, ROUND(lifetime_value, 2) AS lifetime_value, tier
FROM tiers
ORDER BY lifetime_value DESC;


-- ------------------------------------------------------------
-- PART 3: CAPSTONE — full pipeline report
-- ------------------------------------------------------------

-- 3.1 One report: every contact, their lead stage (if any), their
-- customer status (if any), lifetime order value, and last
-- interaction channel — built entirely from CTEs.
-- CORRECTED: orders.total -> orders.amount ; interactions.created_at -> received_at ;
--            added ROUND(...,2) on lifetime_value.
WITH last_interaction AS (
    SELECT DISTINCT ON (contact_id)
           contact_id, channel, received_at
    FROM interactions
    ORDER BY contact_id, received_at DESC
),
lifetime AS (
    SELECT cu.contact_id, SUM(o.amount) AS lifetime_value
    FROM customers cu
    JOIN orders o ON o.customer_id = cu.id
    GROUP BY cu.contact_id
)
SELECT co.name,
       l.stage                                AS lead_stage,
       (cu.id IS NOT NULL)                    AS is_customer,
       COALESCE(ROUND(lt.lifetime_value, 2), 0) AS lifetime_value,
       li.channel                             AS last_channel
FROM contacts co
LEFT JOIN leads l            ON l.contact_id  = co.id
LEFT JOIN customers cu       ON cu.contact_id = co.id
LEFT JOIN lifetime lt        ON lt.contact_id = co.id
LEFT JOIN last_interaction li ON li.contact_id = co.id
ORDER BY lifetime_value DESC, co.name;
-- NOTE: DISTINCT ON is a PostgreSQL specialty — we will unpack it
-- together after you see the output.
