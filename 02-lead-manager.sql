-- ============================================================
-- LEAD MANAGER
-- Database: nova_crm | PostgreSQL 18
-- Requires: contacts + interactions tables (01-crm-database.sql)
-- ============================================================


-- ------------------------------------------------------------
-- 1. SCHEMA — leads table
-- One row per lead. Two inline CHECK constraints lock
-- lead_score and stage to their allowed values.
-- stage defaults to 'New' so fresh leads land there automatically.
-- ------------------------------------------------------------
CREATE TABLE leads (
    id         SERIAL PRIMARY KEY,
    contact_id INTEGER NOT NULL REFERENCES contacts(id),
    lead_score TEXT NOT NULL CHECK (lead_score IN ('Hot', 'Warm', 'Cold')),
    stage      TEXT NOT NULL DEFAULT 'New' CHECK (stage IN ('New', 'Contacted', 'Qualified', 'Won', 'Lost')),
    source     TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);


-- ------------------------------------------------------------
-- 2. TRIGGER — auto-stamp updated_at on every UPDATE
-- Reuses the shared set_updated_at() function
-- (one function per database, one CREATE TRIGGER per table).
-- ------------------------------------------------------------
CREATE TRIGGER leads_updated_at
BEFORE UPDATE ON leads
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

-- For reference, the shared function:
-- CREATE OR REPLACE FUNCTION set_updated_at()
-- RETURNS TRIGGER AS $$
-- BEGIN
--     NEW.updated_at = now();
--     RETURN NEW;
-- END;
-- $$ LANGUAGE plpgsql;


-- ------------------------------------------------------------
-- 3. SEED DATA
-- Note: SELECT real contact ids first, never guess —
-- SERIAL sequences can have gaps.
-- ------------------------------------------------------------
INSERT INTO leads (contact_id, lead_score, source, stage) VALUES
    ((SELECT id FROM contacts WHERE email = 'somchai@example.com'), 'Hot',  'Email',    'Won'),
    ((SELECT id FROM contacts WHERE email = 'nina@example.com'),    'Warm', 'Referral', 'Won'),
    ((SELECT id FROM contacts WHERE email = 'arun@example.com'),    'Cold', 'Email',    'New'),
    ((SELECT id FROM contacts WHERE email = 'mali@example.com'),    'Warm', 'Fiverr',   'New');


-- ------------------------------------------------------------
-- 4. STAGE MOVEMENT — pipeline progression
-- The trigger bumps updated_at automatically; these statements
-- never mention it. created_at stays frozen.
-- ------------------------------------------------------------
UPDATE leads SET stage = 'Contacted' WHERE contact_id = 3;
UPDATE leads SET stage = 'Contacted' WHERE contact_id = 5;
UPDATE leads SET stage = 'Qualified' WHERE contact_id = 3;

-- CHECK enforcement (expected to FAIL — constraint violation):
-- UPDATE leads SET stage = 'Ghosted' WHERE contact_id = 3;
-- ERROR: new row for relation "leads" violates check constraint "leads_stage_check"


-- ------------------------------------------------------------
-- 5. REPORT: Hot leads
-- Which leads are Hot right now, and where are they in the pipeline?
-- ------------------------------------------------------------
SELECT contacts.name, contacts.email, leads.stage, leads.source
FROM contacts
JOIN leads ON contacts.id = leads.contact_id
WHERE leads.lead_score = 'Hot';


-- ------------------------------------------------------------
-- 6. REPORT: Full pipeline overview (three-table JOIN)
-- Every lead with its score, stage, and interaction count.
-- LEFT JOIN keeps zero-interaction contacts;
-- COUNT(interactions.id), not COUNT(*), so all-NULL rows count as 0.
-- ------------------------------------------------------------
SELECT contacts.name, leads.lead_score, leads.stage,
       COUNT(interactions.id) AS interaction_count
FROM leads
JOIN contacts ON leads.contact_id = contacts.id
LEFT JOIN interactions ON contacts.id = interactions.contact_id
GROUP BY contacts.name, leads.lead_score, leads.stage
ORDER BY interaction_count ASC;


-- ------------------------------------------------------------
-- 7. REPORT: Neglected leads
-- Hot/Warm leads with ZERO interactions — follow up with these.
-- WHERE filters raw rows before grouping; HAVING filters after aggregation.
-- ------------------------------------------------------------
SELECT contacts.name, leads.lead_score, leads.stage,
       COUNT(interactions.id) AS interaction_count
FROM leads
JOIN contacts ON leads.contact_id = contacts.id
LEFT JOIN interactions ON contacts.id = interactions.contact_id
WHERE leads.lead_score IN ('Hot', 'Warm')
GROUP BY contacts.name, leads.lead_score, leads.stage
HAVING COUNT(interactions.id) = 0;


-- ------------------------------------------------------------
-- 8. REPORT: Recently touched leads
-- Trigger-maintained updated_at makes this "for free".
-- ------------------------------------------------------------
SELECT contacts.name, leads.lead_score, leads.stage, leads.updated_at
FROM leads
JOIN contacts ON leads.contact_id = contacts.id
ORDER BY leads.updated_at DESC;
