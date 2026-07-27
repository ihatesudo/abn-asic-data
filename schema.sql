-- =========================================================================
-- ASIC Company Name Register -> DuckDB normalized analytics schema
-- Source: 5c3914e6-413e-4a2c-b890-bf8efe3eabf2.json (4.41M name records)
-- Target: asic.duckdb
-- =========================================================================
INSTALL json; LOAD json;
INSTALL parquet; LOAD parquet;

PRAGMA threads=8;

-- -------------------------------------------------------------------------
-- 1) STAGING: stream NDJSON into typed rows. Each line is a JSON array of 16.
--    Columns are documented inline so the meaning is self-evident.
-- -------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_name_record AS
SELECT
    json_extract(rec, '$[0]')::BIGINT                                AS record_id,
    json_extract_string(rec, '$[1]')                               AS company_name,
    json_extract_string(rec, '$[2]')                               AS acn,
    json_extract_string(rec, '$[3]')                               AS type_code,
    json_extract_string(rec, '$[4]')                               AS class_code,
    json_extract_string(rec, '$[5]')                               AS subclass_code,
    json_extract_string(rec, '$[6]')                               AS status_code,
    TRY_STRPTIME(json_extract_string(rec, '$[7]'), '%d/%m/%Y')::DATE  AS reg_date,
    TRY_STRPTIME(json_extract_string(rec, '$[8]'), '%d/%m/%Y')::DATE  AS dereg_date,
    json_extract_string(rec, '$[9]')                               AS prev_state_code,
    json_extract_string(rec, '$[10]')                              AS state_reg_no,
    json_extract_string(rec, '$[11]')                              AS modified_since_last,
    json_extract_string(rec, '$[12]')                              AS current_name_indicator,
    json_extract_string(rec, '$[13]')                              AS abn,
    json_extract_string(rec, '$[14]')                              AS current_name,
    TRY_STRPTIME(json_extract_string(rec, '$[15]'), '%d/%m/%Y')::DATE AS current_name_start_date
FROM read_json_auto('records.ndjson', columns={'rec': 'JSON'});

-- -------------------------------------------------------------------------
-- 2) DIMENSIONS (small lookup tables — clean star schema)
--    Each dimension carries the raw code + a human-readable description.
-- -------------------------------------------------------------------------
CREATE OR REPLACE TABLE dim_type AS
SELECT * FROM (VALUES
    ('APTY', 'Australian Proprietary Company (Pty Ltd)'),
    ('APUB', 'Australian Public Company (Ltd)'),
    ('FNOS', 'Foreign Company'),
    ('ARSL', 'Australian Registrable Body (ASIC scheme)')
) AS t(type_code, type_desc);

CREATE OR REPLACE TABLE dim_class AS
SELECT * FROM (VALUES
    ('LMSH', 'Limited by Shares'),
    ('LMGT', 'Limited by Guarantee'),
    ('UNLT', 'Unlimited'),
    ('NO LI', 'No Liability (mining)'),
    ('ULST', 'Ultimate Parent / Listed status'),
    ('NONE', 'None / Not Applicable')
) AS c(class_code, class_desc);

CREATE OR REPLACE TABLE dim_subclass AS
SELECT * FROM (VALUES
    ('PROP', 'Proprietary'),
    ('PSTC', 'Public / No Liability'),
    ('LISN', 'Listed'),
    ('UNL1', 'Unlimited with share capital'),
    ('NONE', 'None')
) AS s(subclass_code, subclass_desc);

CREATE OR REPLACE TABLE dim_status AS
SELECT * FROM (VALUES
    ('REGD', 'Registered (active)'),
    ('DRGD', 'Deregistered'),
    ('SOFF', 'Struck Off the register'),
    ('EXAD', 'In External Administration'),
    ('NOAC', 'No Active Status'),
    ('CNCL', 'Cancelled (non-company entity)'),
    ('DISS', 'Dissolved'),
    ('SUSP', 'Suspended')
) AS s(status_code, status_desc);

CREATE OR REPLACE TABLE dim_state AS
SELECT * FROM (VALUES
    ('NSW', 'New South Wales'),
    ('VIC', 'Victoria'),
    ('QLD', 'Queensland'),
    ('WA',  'Western Australia'),
    ('SA',  'South Australia'),
    ('TAS', 'Tasmania'),
    ('ACT', 'Australian Capital Territory'),
    ('NT',  'Northern Territory')
) AS s(state_code, state_desc);

-- -------------------------------------------------------------------------
-- 3) DIM_COMPANY — one row per ACN (the real-world entity). Aggregate the
--    many name-rows into the current canonical company.
-- -------------------------------------------------------------------------
CREATE OR REPLACE TABLE dim_company AS
WITH ranked AS (
    -- Prefer the row flagged current_name_indicator='Y'; fall back to latest record_id.
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY acn
               ORDER BY (current_name_indicator = 'Y') DESC, record_id DESC
           ) AS rn
    FROM stg_name_record
)
SELECT
    acn,
    company_name,
    reg_date,
    dereg_date,
    type_code,
    status_code,
    prev_state_code AS state_code,
    abn,
    COUNT(*) OVER (PARTITION BY acn) AS name_record_count
FROM ranked
WHERE rn = 1;

-- -------------------------------------------------------------------------
-- 4) FACT_NAME_RECORD — the grain. One row per name record (current OR prior).
--    This is the table you query for trend / historical analysis.
--    Join keys (FKs) to dims included for star joins.
-- -------------------------------------------------------------------------
CREATE OR REPLACE TABLE fact_name_record AS
SELECT
    s.record_id,
    s.acn,
    s.company_name,
    s.type_code,
    s.class_code,
    s.subclass_code,
    s.status_code,
    COALESCE(s.prev_state_code, '') AS state_code,
    s.reg_date,
    s.dereg_date,
    s.abn,
    s.current_name_indicator = 'Y'   AS is_current,
    s.current_name,
    s.current_name_start_date,
    s.modified_since_last = 'Y'      AS modified_since_last
FROM stg_name_record s;

-- -------------------------------------------------------------------------
-- 5) NAME_HISTORY — resolved previous-name -> current-name transitions.
--    Captures "company X was previously called Y" as explicit edges.
--    This is the data-science relationship table.
-- -------------------------------------------------------------------------
CREATE OR REPLACE TABLE name_history AS
SELECT
    s.acn,
    s.company_name            AS previous_name,
    s.current_name,
    s.reg_date                AS previous_name_start,
    s.current_name_start_date AS current_name_start
FROM stg_name_record s
WHERE s.current_name IS NOT NULL
  AND s.company_name IS NOT NULL
  AND s.company_name <> s.current_name;

-- -------------------------------------------------------------------------
-- 6) ANALYTIC VIEWS (common data-science questions)
-- -------------------------------------------------------------------------

-- v_companies_by_state_year: registration cohort analysis
CREATE OR REPLACE VIEW v_companies_by_state_year AS
SELECT
    EXTRACT(YEAR FROM reg_date)::INT AS reg_year,
    state_code,
    COUNT(DISTINCT acn)              AS companies_registered,
    COUNT(DISTINCT acn) FILTER (WHERE status_code='REGD') AS still_active
FROM fact_name_record
WHERE reg_date IS NOT NULL
GROUP BY 1,2;

-- v_lifespan: how long deregistered companies lived
CREATE OR REPLACE VIEW v_lifespan AS
SELECT
    acn,
    company_name,
    type_code,
    reg_date,
    dereg_date,
    DATE_DIFF('year', reg_date, dereg_date) AS lifespan_years
FROM fact_name_record
WHERE dereg_date IS NOT NULL
  AND reg_date IS NOT NULL
  AND is_current;

-- v_name_change_frequency: companies with the most name changes
CREATE OR REPLACE VIEW v_name_change_frequency AS
SELECT
    acn,
    ANY_VALUE(current_name)      AS current_name,
    COUNT(*)                     AS name_change_count,
    STRING_AGG(DISTINCT previous_name, ' -> ' ORDER BY previous_name) AS name_chain
FROM name_history
GROUP BY acn
HAVING COUNT(*) >= 1;

-- v_type_mix_by_year: entity-type composition over time
CREATE OR REPLACE VIEW v_type_mix_by_year AS
SELECT
    EXTRACT(YEAR FROM reg_date)::INT AS reg_year,
    t.type_code,
    t.type_desc,
    COUNT(DISTINCT f.acn)            AS companies
FROM fact_name_record f
JOIN dim_type t USING (type_code)
WHERE f.reg_date IS NOT NULL AND f.is_current
GROUP BY 1,2,3;

-- v_current_companies: clean list of currently-registered companies
CREATE OR REPLACE VIEW v_current_companies AS
SELECT
    f.acn, f.company_name, f.type_code, t.type_desc, f.state_code,
    f.reg_date, f.abn
FROM fact_name_record f
JOIN dim_type t USING (type_code)
WHERE f.is_current AND f.status_code = 'REGD';

-- -------------------------------------------------------------------------
-- 7) STATS & INDEXES (helpful metadata, kept lightweight)
-- -------------------------------------------------------------------------
CREATE OR REPLACE TABLE db_stats AS
SELECT 'total_name_records'   AS metric, COUNT(*)::VARCHAR AS value FROM fact_name_record
UNION ALL SELECT 'unique_companies (acn)', COUNT(DISTINCT acn)::VARCHAR FROM fact_name_record
UNION ALL SELECT 'current_companies',  COUNT(*)::VARCHAR FROM fact_name_record WHERE is_current
UNION ALL SELECT 'deregistered',       COUNT(*)::VARCHAR FROM fact_name_record WHERE dereg_date IS NOT NULL
UNION ALL SELECT 'name_changes',       COUNT(*)::VARCHAR FROM name_history;

-- In-memory; persistent indexes added after population
CREATE INDEX IF NOT EXISTS idx_fact_acn      ON fact_name_record(acn);
CREATE INDEX IF NOT EXISTS idx_fact_state    ON fact_name_record(state_code);
CREATE INDEX IF NOT EXISTS idx_fact_regdate  ON fact_name_record(reg_date);
CREATE INDEX IF NOT EXISTS idx_company_acn   ON dim_company(acn);
CREATE INDEX IF NOT EXISTS idx_history_acn   ON name_history(acn);
