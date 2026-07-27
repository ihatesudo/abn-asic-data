-- =========================================================================
-- Analytics v2 — re-derive using ABR trading names + ABR state
-- Run AFTER abr_schema.sql:
--   duckdb asic.duckdb < analytics_v2.sql
-- Improvements over analytics.sql:
--   1. Industry classification uses TRADING NAMES + legal name (richer signal)
--   2. State views use ABR state (99.7% coverage) not ASIC state (5%)
--   3. Survival counts SOFF/EXAD as failure, not just dereg_date
-- =========================================================================
PRAGMA threads=8;

-- #########################################################################
-- PART A — INDUSTRY v2: classify using trading names + legal name
-- #########################################################################
-- For each ASIC company matched to ABR, gather ALL its names into one string,
-- then apply keyword rules. Trading names ("7-ELEVEN") beat legal names
-- ("CONVENIENCE HOLDINGS") for industry signal.

CREATE OR REPLACE TABLE fact_company_industry AS
WITH name_pool AS (
    -- concatenate legal name + all trading/business names per company
    SELECT c.acn,
           STRING_AGG(DISTINCT COALESCE(n.name_text, ''), ' | ') AS all_names
    FROM dim_company c
    LEFT JOIN fact_abr_entity e ON c.acn = e.asic_number
    LEFT JOIN fact_abr_name n ON e.abn = n.abn
    GROUP BY c.acn
),
enriched AS (
    -- add the legal name itself (always present) into the searchable text
    SELECT c.acn, c.company_name,
           UPPER(COALESCE(np.all_names || ' | ', '') || c.company_name) AS search_text
    FROM dim_company c
    LEFT JOIN name_pool np ON c.acn = np.acn
)
SELECT
    acn,
    company_name,
    CASE
        -- Specific industries fire BEFORE generic structural suffixes
        WHEN search_text LIKE '%MINING%' OR search_text LIKE '%RESOURCES%'
          OR search_text LIKE '%ENERGY%' OR search_text LIKE '%PETROLEUM%'
          OR search_text LIKE '%EXPLORATION%' OR search_text LIKE '%COAL%'
          OR search_text LIKE '%MINERALS%' OR search_text LIKE '%IRON ORE%'
          OR search_text LIKE '%GAS%' OR search_text LIKE '%DRILLING%'
          OR search_text LIKE '%METALS%' OR search_text LIKE '%STEEL%'
          OR search_text LIKE '%LITHIUM%' OR search_text LIKE '%GOLD%'
          OR search_text LIKE '%COPPER%' THEN 'Mining, Resources & Energy'
        WHEN search_text LIKE '%BANK%' OR search_text LIKE '%INSURANCE%'
          OR search_text LIKE '%FINANCE%' OR search_text LIKE '%FINANCIAL%'
          OR search_text LIKE '%WEALTH%' OR search_text LIKE '%CREDIT%' THEN 'Financial Services & Insurance'
        WHEN search_text LIKE '%SUPERANNUATION%' OR search_text LIKE '%SMSF%'
          OR search_text LIKE '%SUPER FUND%' OR search_text LIKE '%CUSTODIAN%' THEN 'Superannuation & Funds'
        WHEN search_text LIKE '%REAL ESTATE%' OR search_text LIKE '%PROPERTY%'
          OR search_text LIKE '%PROPERTIES%' OR search_text LIKE '%HOMES%'
          OR search_text LIKE '%DEVELOPMENTS%' OR search_text LIKE '%ESTATE%' THEN 'Property & Real Estate'
        WHEN search_text LIKE '%CONSTRUCTION%' OR search_text LIKE '%CONSTRUCTIONS%'
          OR search_text LIKE '%BUILDING%' OR search_text LIKE '%BUILDER%'
          OR search_text LIKE '%CIVIL%' OR search_text LIKE '%ENGINEERING%'
          OR search_text LIKE '%ELECTRICAL%' OR search_text LIKE '%PLUMBING%'
          OR search_text LIKE '%CONTRACTING%' OR search_text LIKE '%ROOFING%' THEN 'Construction & Trades'
        WHEN search_text LIKE '%TRANSPORT%' OR search_text LIKE '%LOGISTICS%'
          OR search_text LIKE '%FREIGHT%' OR search_text LIKE '%COURIER%'
          OR search_text LIKE '%SHIPPING%' OR search_text LIKE '%AVIATION%'
          OR search_text LIKE '%TRUCKING%' THEN 'Transport & Logistics'
        WHEN search_text LIKE '%MEDICAL%' OR search_text LIKE '%PHARMACEUTICAL%'
          OR search_text LIKE '%DENTAL%' OR search_text LIKE '%CLINIC%'
          OR search_text LIKE '%HOSPITAL%' OR search_text LIKE '%THERAPY%'
          OR search_text LIKE '%NDIS%' OR search_text LIKE '%CHILDCARE%'
          OR search_text LIKE '%KINDERGARTEN%' OR search_text LIKE '%EDUCATION%' THEN 'Healthcare & Education'
        WHEN search_text LIKE '%TECHNOLOGY%' OR search_text LIKE '%SOFTWARE%'
          OR search_text LIKE '%DIGITAL%' OR search_text LIKE '%SYSTEMS%'
          OR search_text LIKE '%CYBER%' OR search_text LIKE '%CLOUD%' THEN 'Technology & Digital'
        WHEN search_text LIKE '%HOSPITALITY%' OR search_text LIKE '%HOTEL%'
          OR search_text LIKE '%MOTEL%' OR search_text LIKE '%RESTAURANT%'
          OR search_text LIKE '%CAFE%' OR search_text LIKE '%TOURISM%'
          OR search_text LIKE '%RESORT%' OR search_text LIKE '%TAVERN%'
          OR search_text LIKE '%CATERING%' THEN 'Hospitality & Tourism'
        WHEN search_text LIKE '%AGRICULTURE%' OR search_text LIKE '%FARMING%'
          OR search_text LIKE '%PASTORAL%' OR search_text LIKE '%GRAZING%'
          OR search_text LIKE '%VITICULTURE%' OR search_text LIKE '%WINERY%' THEN 'Agriculture & Pastoral'
        WHEN search_text LIKE '%RETAIL%' OR search_text LIKE '%WHOLESALE%'
          OR search_text LIKE '%IMPORTS%' OR search_text LIKE '%EXPORTS%'
          OR search_text LIKE '%TRADING%' OR search_text LIKE '%7-ELEVEN%'
          OR search_text LIKE '%STORE%' OR search_text LIKE '%SHOP%' THEN 'Retail, Wholesale & Trade'
        WHEN search_text LIKE '%CONSULTING%' OR search_text LIKE '%CONSULTANTS%'
          OR search_text LIKE '%ADVISORY%' OR search_text LIKE '%LEGAL%'
          OR search_text LIKE '%ACCOUNTING%' OR search_text LIKE '%MANAGEMENT%'
          OR search_text LIKE '%PARTNERS%' THEN 'Professional Services'
        WHEN search_text LIKE '%HOLDINGS%' OR search_text LIKE '%INVESTMENTS%'
          OR search_text LIKE '%CAPITAL%' OR search_text LIKE '%VENTURES%'
          OR search_text LIKE '%NOMINEES%' THEN 'Holding Companies & Investments'
        ELSE 'Other / Unclassified'
    END AS industry
FROM enriched;

-- #########################################################################
-- PART B — COHORT SURVIVAL v2 (failure = dereg OR struck-off OR ext-admin)
-- #########################################################################
CREATE OR REPLACE TABLE fact_cohort_survival AS
WITH base AS (
    SELECT
        EXTRACT(YEAR FROM c.reg_date)::INT        AS reg_year,
        e.abr_state                               AS state_code,   -- ABR state now
        fi.industry,
        c.acn,
        c.reg_date,
        COALESCE(c.dereg_date,
                 CASE WHEN c.status_code IN ('DRGD','SOFF','DISS','CNCL')
                      THEN c.reg_date + INTERVAL 1 YEAR END) AS fail_date
    FROM dim_company c
    JOIN fact_company_industry fi ON c.acn = fi.acn
    LEFT JOIN fact_abr_entity e ON c.acn = e.asic_number
    WHERE c.reg_date IS NOT NULL AND c.reg_date >= DATE '1900-01-01'
),
cohort_size AS (
    SELECT reg_year, state_code, industry, COUNT(*) AS cohort_n
    FROM base GROUP BY 1,2,3
),
milestones AS (
    SELECT b.reg_year, b.state_code, b.industry, m.years,
           SUM(CASE WHEN b.fail_date IS NULL
                      OR b.fail_date >= (b.reg_date + INTERVAL (m.years) YEAR)
                    THEN 1 ELSE 0 END) AS survived_n
    FROM base b CROSS JOIN dim_survival_milestone m
    GROUP BY 1,2,3,4
)
SELECT cs.reg_year, cs.state_code, cs.industry, cs.cohort_n,
       m.years AS survival_year, m.survived_n,
       ROUND(100.0 * m.survived_n / cs.cohort_n, 2) AS survival_pct
FROM cohort_size cs JOIN milestones m USING (reg_year, state_code, industry);

-- #########################################################################
-- PART C — ROLLUP VIEWS (rebuilt on the better data)
-- #########################################################################

-- C1. Industry coverage — how much did trading names help?
CREATE OR REPLACE VIEW v_industry_coverage AS
SELECT industry, COUNT(*) AS n_companies,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_total
FROM fact_company_industry
GROUP BY industry ORDER BY n_companies DESC;

-- C2. State stability (5-yr survival) — now MEANINGFUL with ABR state
CREATE OR REPLACE VIEW v_state_stability AS
SELECT
    state_code,
    SUM(cohort_n)  AS companies_in_cohorts,
    SUM(survived_n) AS survived_5yr,
    ROUND(100.0 * SUM(survived_n) / SUM(cohort_n), 2) AS survival_5yr_pct
FROM fact_cohort_survival
WHERE survival_year = 5 AND reg_year <= 2021 AND state_code IS NOT NULL
GROUP BY state_code
ORDER BY survival_5yr_pct DESC;

-- C3. Industry stability
CREATE OR REPLACE VIEW v_industry_stability AS
SELECT
    industry,
    SUM(cohort_n)  AS companies_in_cohorts,
    SUM(survived_n) AS survived_5yr,
    ROUND(100.0 * SUM(survived_n) / SUM(cohort_n), 2) AS survival_5yr_pct
FROM fact_cohort_survival
WHERE survival_year = 5 AND reg_year <= 2021
GROUP BY industry ORDER BY survival_5yr_pct DESC;

-- C4. State growth — registrations per year by ABR state
CREATE OR REPLACE VIEW v_state_growth AS
WITH yearly AS (
    SELECT EXTRACT(YEAR FROM f.reg_date)::INT AS reg_year,
           e.abr_state AS state_code,
           COUNT(DISTINCT f.acn) AS new_companies
    FROM fact_name_record f
    JOIN fact_abr_entity e ON f.acn = e.asic_number
    WHERE f.reg_date IS NOT NULL AND f.is_current
    GROUP BY 1,2
)
SELECT reg_year, state_code, new_companies,
       ROUND(100.0 * (new_companies - LAG(new_companies) OVER w)
                   / NULLIF(LAG(new_companies) OVER w, 0), 1) AS yoy_pct
FROM yearly
WINDOW w AS (PARTITION BY state_code ORDER BY reg_year);

-- C5. Industry trends
CREATE OR REPLACE VIEW v_industry_trends AS
SELECT EXTRACT(YEAR FROM f.reg_date)::INT AS reg_year,
       fi.industry, COUNT(DISTINCT f.acn) AS new_companies
FROM fact_name_record f JOIN fact_company_industry fi ON f.acn = fi.acn
WHERE f.reg_date IS NOT NULL AND f.is_current
GROUP BY 1,2;

-- refresh db_stats with v2 industry count
CREATE OR REPLACE TABLE db_stats AS
SELECT 'asic_name_records'        AS metric, COUNT(*)::VARCHAR AS value FROM fact_name_record
UNION ALL SELECT 'asic_companies',          COUNT(*)::VARCHAR FROM dim_company
UNION ALL SELECT 'abr_entities',             COUNT(*)::VARCHAR FROM fact_abr_entity
UNION ALL SELECT 'abr_trading_names',        COUNT(*)::VARCHAR FROM fact_abr_name
UNION ALL SELECT 'abr_individuals',          COUNT(*)::VARCHAR FROM fact_abr_entity WHERE is_individual
UNION ALL SELECT 'abr_state_coverage_pct',   ROUND(100.0*SUM(abr_state IS NOT NULL)/COUNT(*),1)::VARCHAR FROM fact_abr_entity
UNION ALL SELECT 'abr_gst_active',           COUNT(*)::VARCHAR FROM fact_abr_entity WHERE gst_status='ACT'
UNION ALL SELECT 'industries_classified',    COUNT(*)::VARCHAR FROM fact_company_industry WHERE industry <> 'Other / Unclassified'
UNION ALL SELECT 'name_changes',             COUNT(*)::VARCHAR FROM name_history
UNION ALL SELECT 'foreign_acq_leads',        COUNT(*)::VARCHAR FROM v_foreign_acquisition_leads;
