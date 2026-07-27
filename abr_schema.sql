-- =========================================================================
-- ABR (Australian Business Register) layer — load + join to ASIC
-- Run AFTER schema.sql + analytics.sql:
--   duckdb asic.duckdb < abr_schema.sql
-- Source: abr/abr_entities.parquet (20.4M ABNs) + abr/abr_names.parquet (18.6M names)
-- =========================================================================
PRAGMA threads=8;
INSTALL parquet; LOAD parquet;

-- -------------------------------------------------------------------------
-- 1) FACT TABLES — materialize Parquet into DuckDB (typed, indexed)
-- -------------------------------------------------------------------------
CREATE OR REPLACE TABLE fact_abr_entity AS
SELECT
    abn,
    abn_status,
    TRY_CAST(abn_status_date AS DATE)   AS abn_status_date,
    entity_type_code,
    entity_type_text,
    legal_name,
    is_individual,
    state                               AS abr_state,
    postcode,
    asic_number,
    gst_status,
    TRY_CAST(gst_status_date AS DATE)   AS gst_status_date,
    dgr_status,
    TRY_CAST(dgr_status_date AS DATE)   AS dgr_status_date,
    TRY_CAST(record_last_updated AS DATE) AS record_last_updated,
    replaced
FROM read_parquet('abr/abr_entities.parquet');

CREATE OR REPLACE TABLE fact_abr_name AS
SELECT abn, name_type, name_text
FROM read_parquet('abr/abr_names.parquet');

-- -------------------------------------------------------------------------
-- 2) DIM_ABR_ENTITY_TYPE — authoritative lookup, sourced FROM the data
--    (EntityTypeInd + EntityTypeText appear inline, so no scraping needed)
-- -------------------------------------------------------------------------
CREATE OR REPLACE TABLE dim_abr_entity_type AS
SELECT entity_type_code, ANY_VALUE(entity_type_text) AS entity_type_text
FROM fact_abr_entity
WHERE entity_type_code IS NOT NULL
GROUP BY entity_type_code
ORDER BY entity_type_code;

-- Cross-walk: ASIC's 5 codes -> ABR's authoritative taxonomy
CREATE OR REPLACE TABLE dim_asic_to_abr_type AS
SELECT * FROM (VALUES
    ('APTY', 'Australian Proprietary Company (ASIC)', 'PRV', 'Australian Private Company',            'high',   'direct equivalent'),
    ('APUB', 'Australian Public Company (ASIC)',      'PUB', 'Australian Public Company',             'high',   'direct equivalent'),
    ('CCIV', 'Corporate Collective Investment Vehicle','CSF', 'CCIV Sub-Fund',                        'medium', 'structural analog'),
    ('FNOS', 'Foreign Company (ASIC)',                NULL,   NULL,                                    'none',   'ABR has no foreign-entity code'),
    ('RACN', 'Registrable Australian Body (ASIC)',    NULL,   NULL,                                    'none',   'ABR has no equivalent code')
) AS x(asic_code, asic_desc, abr_code, abr_desc, confidence, note);

-- -------------------------------------------------------------------------
-- 3) V_COMPANY_FULL — the enriched master: ASIC ⟕ ABR on acn = asic_number
--    This is the single most useful table. ASIC brings registration history
--    + name changes; ABR brings state/postcode/GST/authoritative type.
-- -------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_company_full AS
SELECT
    c.acn,
    c.company_name,
    c.reg_date,
    c.dereg_date,
    c.status_code,
    fi.industry                         AS inferred_industry,
    e.abn,
    e.abr_state,
    e.postcode,
    e.entity_type_code                  AS abr_entity_type,
    e.gst_status,
    e.abn_status,
    (e.gst_status = 'ACT')              AS is_active_trader
FROM dim_company c
LEFT JOIN fact_abr_entity e ON c.acn = e.asic_number
LEFT JOIN fact_company_industry fi ON c.acn = fi.acn;

-- Coverage metric: how many ASIC companies match an ABN record?
CREATE OR REPLACE VIEW v_abr_join_coverage AS
SELECT
    COUNT(*) AS asic_companies,
    SUM(abn IS NOT NULL) AS matched_to_abr,
    ROUND(100.0 * SUM(abn IS NOT NULL) / COUNT(*), 2) AS match_pct,
    SUM(is_active_trader) AS active_traders
FROM v_company_full;

-- -------------------------------------------------------------------------
-- 4) V_BRAND_UMBRELLAS — one entity behind many trading/business names.
--    Filtered to NON-individuals (companies/trusts), ranked by name count.
--    This surfaces the "hidden ownership" multi-brand structure.
-- -------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_brand_umbrellas AS
SELECT
    e.abn,
    e.legal_name,
    e.entity_type_code,
    e.abr_state,
    COUNT(*) AS trading_name_count,
    STRING_AGG(DISTINCT n.name_text, ' | ' ORDER BY n.name_text) AS name_sample
FROM fact_abr_entity e
JOIN fact_abr_name n USING (abn)
WHERE NOT e.is_individual
GROUP BY e.abn, e.legal_name, e.entity_type_code, e.abr_state
HAVING COUNT(*) >= 3
ORDER BY trading_name_count DESC;

-- -------------------------------------------------------------------------
-- 5) ABR-native analytic views (the state analysis we couldn't do before)
-- -------------------------------------------------------------------------

-- Active traders by state (GST=ACT) — real operating businesses, not shells
CREATE OR REPLACE VIEW v_active_traders_by_state AS
SELECT
    abr_state,
    COUNT(*) AS active_traders,
    SUM(entity_type_code = 'PRV') AS pty_active,
    SUM(entity_type_code = 'PUB') AS pub_active,
    SUM(is_individual) AS sole_traders_active
FROM fact_abr_entity
WHERE gst_status = 'ACT' AND abn_status = 'ACT'
GROUP BY abr_state
ORDER BY active_traders DESC;

-- Entity-type mix by state (structural composition of each state's economy)
CREATE OR REPLACE VIEW v_entity_mix_by_state AS
SELECT
    abr_state,
    entity_type_code,
    entity_type_text,
    COUNT(*) AS n
FROM fact_abr_entity
WHERE abr_state IS NOT NULL AND abn_status = 'ACT'
GROUP BY 1,2,3;

-- -------------------------------------------------------------------------
-- 6) INDEXES + stats refresh
-- -------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_abr_abn   ON fact_abr_entity(abn);
CREATE INDEX IF NOT EXISTS idx_abr_acn   ON fact_abr_entity(asic_number);
CREATE INDEX IF NOT EXISTS idx_abr_state ON fact_abr_entity(abr_state);
CREATE INDEX IF NOT EXISTS idx_abrn_abn  ON fact_abr_name(abn);

CREATE OR REPLACE TABLE db_stats AS
SELECT 'asic_name_records'        AS metric, COUNT(*)::VARCHAR AS value FROM fact_name_record
UNION ALL SELECT 'asic_companies',          COUNT(*)::VARCHAR FROM dim_company
UNION ALL SELECT 'abr_entities',             COUNT(*)::VARCHAR FROM fact_abr_entity
UNION ALL SELECT 'abr_trading_names',        COUNT(*)::VARCHAR FROM fact_abr_name
UNION ALL SELECT 'abr_individuals',          COUNT(*)::VARCHAR FROM fact_abr_entity WHERE is_individual
UNION ALL SELECT 'abr_companies_with_acn',   COUNT(*)::VARCHAR FROM fact_abr_entity WHERE asic_number IS NOT NULL
UNION ALL SELECT 'abr_state_coverage_pct',   ROUND(100.0*SUM(abr_state IS NOT NULL)/COUNT(*),1)::VARCHAR FROM fact_abr_entity
UNION ALL SELECT 'abr_gst_active',           COUNT(*)::VARCHAR FROM fact_abr_entity WHERE gst_status='ACT'
UNION ALL SELECT 'industries_classified',    COUNT(*)::VARCHAR FROM fact_company_industry WHERE industry <> 'Other / Unclassified'
UNION ALL SELECT 'name_changes',             COUNT(*)::VARCHAR FROM name_history
UNION ALL SELECT 'foreign_acq_leads',        COUNT(*)::VARCHAR FROM v_foreign_acquisition_leads;
