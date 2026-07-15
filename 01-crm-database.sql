-- ============================================================
-- CRM DATABASE — core schema
-- Database: nova_crm | PostgreSQL 18
-- Tables: contacts (one row per person)
--         interactions (append-only activity log, many per contact)
-- ============================================================


-- ------------------------------------------------------------
-- 1. SCHEMA — contacts table
-- UNIQUE on email = the stable match key for upserts.
-- TIMESTAMPTZ DEFAULT now() auto-stamps creation time.
-- ------------------------------------------------------------
CREATE TABLE contacts (
    id         SERIAL PRIMARY KEY,
    name       TEXT NOT NULL,
    email      TEXT UNIQUE NOT NULL,
    company    TEXT,
    phone      TEXT,
    created_at TIMESTAMPTZ DEFAULT now()
);


-- ------------------------------------------------------------
-- 2. UPSERT PATTERN — insert-or-update on email conflict
-- EXCLUDED.column refers to the incoming values.
-- name is deliberately left out of SET: protected from
-- casual overwrite while phone/company still update.
-- ------------------------------------------------------------
INSERT INTO contacts (name, email, company, phone)
VALUES ('Somchai Prasert', 'somchai@example.com', 'Prasert Trading', '081-000-0000')
ON CONFLICT (email) DO UPDATE
SET company = EXCLUDED.company,
    phone   = EXCLUDED.phone;

-- ----------------------------------------------------------
-- 2b. SEED CONTACTS — referenced by later files via email
-- (email is the stable key; ids are never referenced anywhere)
-- ----------------------------------------------------------
INSERT INTO contacts (name, email, company, phone) VALUES
    ('Nina Wattana',  'nina@example.com',  'Wattana Design',  '082-000-0001'),
    ('Arun Chai',     'arun@example.com',  'Chai Logistics',  '083-000-0002'),
    ('Mali Suksan',   'mali@example.com',  'Suksan Cafe',     '084-000-0003');


-- ------------------------------------------------------------
-- 3. SCHEMA — interactions table (one-to-many)
-- Foreign key enforces that every interaction belongs to a
-- real contact. CHECK constraint locks channel to an
-- allow-list (chosen over a native ENUM type: a CHECK is
-- easier to redefine later as the list evolves).
-- ------------------------------------------------------------
CREATE TABLE interactions (
    id          SERIAL PRIMARY KEY,
    contact_id  INTEGER NOT NULL REFERENCES contacts(id),
    channel     TEXT,
    notes       TEXT,
    received_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE interactions
ADD CONSTRAINT channel_check
CHECK (channel IN ('Email', 'Telegram', 'Slack', 'Phone', 'Meeting'));


-- ------------------------------------------------------------
-- 4. TRIGGER — auto-stamp updated_at on every UPDATE
-- Postgres has no "on update" default, so a BEFORE UPDATE
-- trigger stamps it instead. The function is shared:
-- defined once per database, attached per table with
-- one CREATE TRIGGER statement.
-- ------------------------------------------------------------
ALTER TABLE contacts ADD COLUMN updated_at TIMESTAMPTZ DEFAULT now();

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER contacts_updated_at
BEFORE UPDATE ON contacts
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();


-- ------------------------------------------------------------
-- 5. REPORT: Recent activity
-- Always add a unique tiebreaker (id DESC): now() is the
-- transaction start time, so rows from one batch INSERT
-- share an identical timestamp.
-- ------------------------------------------------------------
SELECT contacts.name, interactions.channel, interactions.notes,
       interactions.received_at
FROM interactions
JOIN contacts ON interactions.contact_id = contacts.id
ORDER BY interactions.received_at DESC, interactions.id DESC
LIMIT 5;


-- ------------------------------------------------------------
-- 6. REPORT: Interactions per contact
-- LEFT JOIN keeps zero-interaction contacts in the result;
-- COUNT(interactions.id), not COUNT(*), so the all-NULL row
-- a LEFT JOIN produces counts as 0 instead of a phantom 1.
-- ------------------------------------------------------------
SELECT contacts.name, COUNT(interactions.id) AS interaction_count
FROM contacts
LEFT JOIN interactions ON contacts.id = interactions.contact_id
GROUP BY contacts.name
ORDER BY interaction_count DESC;


-- ------------------------------------------------------------
-- 7. REPORT: Contacts with no interactions yet
-- WHERE filters raw rows before grouping;
-- HAVING filters after aggregation.
-- Order of operations:
-- FROM/JOIN -> WHERE -> GROUP BY -> HAVING -> ORDER BY -> LIMIT
-- ------------------------------------------------------------
SELECT contacts.name, COUNT(interactions.id) AS interaction_count
FROM contacts
LEFT JOIN interactions ON contacts.id = interactions.contact_id
GROUP BY contacts.name
HAVING COUNT(interactions.id) = 0;
