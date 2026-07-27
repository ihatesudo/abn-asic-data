-- =========================================================================
-- ASIC analytics layer — industry, stability, trends, concentration, M&A trail
-- Additive to schema.sql. Run AFTER the base schema is built.
--   duckdb asic.duckdb < schema.sql    (base)
--   duckdb asic.duckdb < analytics.sql (this file)
-- =========================================================================
PRAGMA threads=8;

-- #########################################################################
-- PART A — INDUSTRY DIMENSION (inferred from company-name keywords)
-- #########################################################################
-- Honest note: ASIC's NAME register has no official industry classification.
-- These rules classify by keyword. ~70% of names are plain "PTY LTD" shells
-- with no industry signal and fall into "Other / Unclassified". Confidence
-- flags let you filter to high-confidence classifications in dashboards.

-- A1. Editable rule table (auditable in Metabase). Priority = eval order.
CREATE OR REPLACE TABLE dim_industry_rule (
    rule_id     INTEGER,
    industry    VARCHAR,
    keyword     VARCHAR,         -- ILIKE pattern; first-match-wins by priority
    priority    INTEGER          -- lower = evaluated first
);
INSERT INTO dim_industry_rule VALUES
  -- Specific industries fire BEFORE generic structural suffixes (Holdings/Group)
  ( 1,'Mining, Resources & Energy','%MINING%',1),
  ( 2,'Mining, Resources & Energy','%RESOURCES%',1),
  ( 3,'Mining, Resources & Energy','%ENERGY%',1),
  ( 4,'Mining, Resources & Energy','%PETROLEUM%',1),
  ( 5,'Mining, Resources & Energy','%EXPLORATION%',1),
  ( 6,'Mining, Resources & Energy','%COAL%',1),
  ( 7,'Mining, Resources & Energy','%MINERALS%',1),
  ( 8,'Mining, Resources & Energy','%IRON ORE%',1),
  ( 9,'Mining, Resources & Energy','%GAS%',1),
  (10,'Mining, Resources & Energy','%DRILLING%',1),
  (87,'Mining, Resources & Energy','%METALS%',1),
  (88,'Mining, Resources & Energy','%STEEL%',1),
  (89,'Mining, Resources & Energy','%LITHIUM%',1),
  (90,'Mining, Resources & Energy','%GOLD%',1),
  (91,'Mining, Resources & Energy','%COPPER%',1),
  (11,'Financial Services & Insurance','%BANK%',2),
  (12,'Financial Services & Insurance','%INSURANCE%',2),
  (13,'Financial Services & Insurance','%FINANCE%',2),
  (14,'Financial Services & Insurance','%FINANCIAL%',2),
  (15,'Financial Services & Insurance','%WEALTH%',2),
  (16,'Financial Services & Insurance','%CREDIT%',2),
  (17,'Superannuation & Funds','%SUPERANNUATION%',3),
  (18,'Superannuation & Funds','%SMSF%',3),
  (19,'Superannuation & Funds','%SUPER FUND%',3),
  (20,'Superannuation & Funds','%CUSTODIAN%',3),
  (21,'Property & Real Estate','%REAL ESTATE%',4),
  (22,'Property & Real Estate','%PROPERTY%',4),
  (23,'Property & Real Estate','%PROPERTIES%',4),
  (24,'Property & Real Estate','%HOMES%',4),
  (25,'Property & Real Estate','%DEVELOPMENTS%',4),
  (26,'Property & Real Estate','%ESTATE%',4),
  (27,'Construction & Trades','%CONSTRUCTION%',5),
  (28,'Construction & Trades','%CONSTRUCTIONS%',5),
  (29,'Construction & Trades','%BUILDING%',5),
  (30,'Construction & Trades','%BUILDER%',5),
  (31,'Construction & Trades','%CIVIL%',5),
  (32,'Construction & Trades','%ENGINEERING%',5),
  (33,'Construction & Trades','%ELECTRICAL%',5),
  (34,'Construction & Trades','%PLUMBING%',5),
  (35,'Construction & Trades','%CONTRACTING%',5),
  (36,'Construction & Trades','%ROOFING%',5),
  (37,'Transport & Logistics','%TRANSPORT%',6),
  (38,'Transport & Logistics','%LOGISTICS%',6),
  (39,'Transport & Logistics','%FREIGHT%',6),
  (40,'Transport & Logistics','%COURIER%',6),
  (41,'Transport & Logistics','%SHIPPING%',6),
  (42,'Transport & Logistics','%AVIATION%',6),
  (43,'Transport & Logistics','%TRUCKING%',6),
  (44,'Healthcare','%MEDICAL%',7),
  (45,'Healthcare','%PHARMACEUTICAL%',7),
  (46,'Healthcare','%DENTAL%',7),
  (47,'Healthcare','%CLINIC%',7),
  (48,'Healthcare','%HOSPITAL%',7),
  (49,'Healthcare','%THERAPY%',7),
  (50,'Healthcare','%NDIS%',7),
  (51,'Technology & Digital','%TECHNOLOGY%',8),
  (52,'Technology & Digital','%SOFTWARE%',8),
  (53,'Technology & Digital','%DIGITAL%',8),
  (54,'Technology & Digital','%SYSTEMS%',8),
  (55,'Technology & Digital','%CYBER%',8),
  (56,'Technology & Digital','%CLOUD%',8),
  (57,'Hospitality & Tourism','%HOSPITALITY%',9),
  (58,'Hospitality & Tourism','%HOTEL%',9),
  (59,'Hospitality & Tourism','%MOTEL%',9),
  (60,'Hospitality & Tourism','%RESTAURANT%',9),
  (61,'Hospitality & Tourism','%CAFE%',9),
  (62,'Hospitality & Tourism','%TOURISM%',9),
  (63,'Hospitality & Tourism','%RESORT%',9),
  (64,'Agriculture & Pastoral','%AGRICULTURE%',10),
  (65,'Agriculture & Pastoral','%FARMING%',10),
  (66,'Agriculture & Pastoral','%PASTORAL%',10),
  (67,'Agriculture & Pastoral','%GRAZING%',10),
  (68,'Agriculture & Pastoral','%VITICULTURE%',10),
  (69,'Agriculture & Pastoral','%WINERY%',10),
  (70,'Retail, Wholesale & Trade','%RETAIL%',11),
  (71,'Retail, Wholesale & Trade','%WHOLESALE%',11),
  (72,'Retail, Wholesale & Trade','%IMPORTS%',11),
  (73,'Retail, Wholesale & Trade','%EXPORTS%',11),
  (74,'Retail, Wholesale & Trade','%TRADING%',11),
  (75,'Professional Services','%CONSULTING%',12),
  (76,'Professional Services','%CONSULTANTS%',12),
  (77,'Professional Services','%ADVISORY%',12),
  (78,'Professional Services','%LEGAL%',12),
  (79,'Professional Services','%ACCOUNTING%',12),
  (80,'Professional Services','%MANAGEMENT%',12),
  (81,'Professional Services','%PARTNERS%',12),
  (82,'Holding Companies & Investments','%HOLDINGS%',13),  -- structural; fires last
  (83,'Holding Companies & Investments','%INVESTMENTS%',13),
  (84,'Holding Companies & Investments','%CAPITAL%',13),
  (85,'Holding Companies & Investments','%VENTURES%',13),
  (86,'Holding Companies & Investments','%NOMINEES%',13);

-- A2. Lookup dim for clean labels + ordering
CREATE OR REPLACE TABLE dim_industry AS
SELECT * FROM (VALUES
    ( 1,'Mining, Resources & Energy'),
    ( 2,'Financial Services & Insurance'),
    ( 3,'Superannuation & Funds'),
    ( 4,'Property & Real Estate'),
    ( 5,'Construction & Trades'),
    ( 6,'Transport & Logistics'),
    ( 7,'Healthcare'),
    ( 8,'Technology & Digital'),
    ( 9,'Hospitality & Tourism'),
    (10,'Agriculture & Pastoral'),
    (11,'Retail, Wholesale & Trade'),
    (12,'Professional Services'),
    (13,'Holding Companies & Investments'),
    (14,'Other / Unclassified')
) AS i(industry_id, industry);

-- A3. Classify every company (one row per ACN). First-match-wins by priority.
CREATE OR REPLACE TABLE fact_company_industry AS
WITH ranked AS (
    SELECT
        c.acn,
        c.company_name,
        r.industry,
        r.priority,
        ROW_NUMBER() OVER (PARTITION BY c.acn ORDER BY r.priority ASC) AS rn
    FROM dim_company c
    LEFT JOIN dim_industry_rule r ON c.company_name ILIKE r.keyword
)
SELECT
    acn,
    company_name,
    COALESCE(industry, 'Other / Unclassified') AS industry
FROM ranked
WHERE rn = 1;

-- #########################################################################
-- PART B — INDUSTRY CONCENTRATION  (the "monopoly / centralization" view)
-- #########################################################################
-- Since the dataset has NO ownership/parent-child field, we measure
-- concentration at the industry level: how many distinct entities (ACNs)
-- operate in an industry, and how much of the name-space the top holders
-- occupy. We use name-counts as a proxy for entity scale.

CREATE OR REPLACE VIEW v_industry_concentration AS
WITH per_company AS (
    SELECT fi.industry,
           c.acn,
           c.company_name,
           COUNT(*) AS name_records   -- proxy for entity's footprint
    FROM fact_company_industry fi
    JOIN fact_name_record c USING (acn)
    GROUP BY 1,2,3
),
ranked AS (
    SELECT industry, acn, company_name, name_records,
           SUM(name_records) OVER (PARTITION BY industry) AS industry_total,
           ROW_NUMBER() OVER (PARTITION BY industry ORDER BY name_records DESC) AS rk
    FROM per_company
)
SELECT
    industry,
    COUNT(DISTINCT acn)                                  AS n_companies,
    SUM(name_records)                                    AS total_name_records,
    -- Top-5 share: how concentrated is the industry?
    ROUND(100.0 * SUM(CASE WHEN rk <= 5 THEN name_records ELSE 0 END)
                   / NULLIF(SUM(name_records),0), 2)     AS top5_share_pct,
    ROUND(100.0 * SUM(CASE WHEN rk = 1 THEN name_records ELSE 0 END)
                   / NULLIF(SUM(name_records),0), 2)     AS top1_share_pct
FROM ranked
GROUP BY industry;

-- #########################################################################
-- PART C — M&A / RESTRUCTURING TRAIL  (proxy for hidden ownership transfer)
-- #########################################################################
-- When a company is acquired it usually RENAMES. 434K name changes exist.
-- We surface the full chain per company + flag foreign-origin new names
-- as INVESTIGATION LEADS (not conclusions). Ground truth requires ASIC's
-- beneficial-ownership register, which is a separate dataset.

CREATE OR REPLACE TABLE dim_foreign_keyword AS
SELECT * FROM (VALUES
    ('Japan',  '%JAPAN%'),
    ('Japan',  '%JAPANESE%'),
    ('China',  '%CHINA%'),
    ('China',  '%CHINESE%'),
    ('Korea',  '%KOREA%'),
    ('Korea',  '%KOREAN%'),
    ('USA',    '%AMERICAN%'),
    ('USA',    '%USA%'),
    ('Singapore','%SINGAPORE%'),
    ('Germany','%GERMAN%'),
    ('UK',     '%BRITISH%'),
    ('India',  '%INDIA%'),
    ('Canada', '%CANADIAN%'),
    ('France', '%FRENCH%')
) AS k(country_hint, pattern);

-- v_name_change_trail: full previous->current history, with foreign hint
CREATE OR REPLACE VIEW v_name_change_trail AS
SELECT
    h.acn,
    fi.industry                      AS current_industry,
    h.previous_name,
    h.current_name,
    h.current_name_start,
    fk.country_hint                  AS foreign_acquisition_lead
FROM name_history h
LEFT JOIN fact_company_industry fi USING (acn)
LEFT JOIN dim_foreign_keyword fk
       ON h.current_name ILIKE fk.pattern
      AND h.previous_name NOT ILIKE fk.pattern;  -- only NEW (acquired) foreign signal

-- v_foreign_acquisition_leads: filtered, de-duplicated leads
CREATE OR REPLACE VIEW v_foreign_acquisition_leads AS
SELECT
    acn,
    current_industry,
    current_name,
    STRING_AGG(DISTINCT previous_name, ' -> ' ORDER BY previous_name) AS prior_names,
    foreign_acquisition_lead AS country_hint,
    MIN(current_name_start) AS first_foreign_name_date
FROM v_name_change_trail
WHERE foreign_acquisition_lead IS NOT NULL
GROUP BY acn, current_industry, current_name, foreign_acquisition_lead
ORDER BY first_foreign_name_date DESC;

-- #########################################################################
-- PART D — COHORT SURVIVAL  (the "stability" metric)
-- #########################################################################
-- For each (registration_year x industry x state) cohort, what fraction
-- of companies are still Registered at +1/+3/+5/+10 years? This is the
-- fair stability comparison — normalizes for WHEN companies were founded.

CREATE OR REPLACE TABLE dim_survival_milestone AS
SELECT * FROM (VALUES (1),(3),(5),(10)) AS m(years);

CREATE OR REPLACE TABLE fact_cohort_survival AS
WITH base AS (
    -- one row per company. "failed" = deregistered OR struck off OR dissolved.
    -- Survival to N years = did not fail before reg_date + N years.
    SELECT
        EXTRACT(YEAR FROM c.reg_date)::INT        AS reg_year,
        COALESCE(c.state_code,'')                 AS state_code,
        fi.industry,
        c.acn,
        c.reg_date,
        COALESCE(c.dereg_date,
                 CASE WHEN c.status_code IN ('DRGD','SOFF','DISS','CNCL')
                      THEN c.reg_date + INTERVAL 1 YEAR END) AS fail_date
    FROM dim_company c
    JOIN fact_company_industry fi USING (acn)
    WHERE c.reg_date IS NOT NULL
      AND c.reg_date >= DATE '1900-01-01'
),
cohort_size AS (
    SELECT reg_year, state_code, industry, COUNT(*) AS cohort_n
    FROM base GROUP BY 1,2,3
),
milestones AS (
    -- Survived N years = no failure (dereg OR strike-off) before reg_date + N years.
    SELECT b.reg_year, b.state_code, b.industry, m.years,
           SUM(CASE WHEN b.fail_date IS NULL
                      OR b.fail_date >= (b.reg_date + INTERVAL (m.years) YEAR)
                    THEN 1 ELSE 0 END) AS survived_n
    FROM base b CROSS JOIN dim_survival_milestone m
    GROUP BY 1,2,3,4
)
SELECT
    cs.reg_year,
    cs.state_code,
    cs.industry,
    cs.cohort_n,
    m.years AS survival_year,
    m.survived_n,
    ROUND(100.0 * m.survived_n / cs.cohort_n, 2) AS survival_pct
FROM cohort_size cs
JOIN milestones m USING (reg_year, state_code, industry);

-- #########################################################################
-- PART E — ROLLUP VIEWS (ready for charts)
-- #########################################################################

-- E1. State stability: 5-year survival by state (cohorts aged >=5 yrs)
CREATE OR REPLACE VIEW v_state_stability AS
SELECT
    state_code,
    SUM(cohort_n)  AS companies_in_cohorts,
    SUM(survived_n) AS survived_5yr,
    ROUND(100.0 * SUM(survived_n) / SUM(cohort_n), 2) AS survival_5yr_pct
FROM fact_cohort_survival
WHERE survival_year = 5
  AND reg_year <= 2021          -- cohort old enough to have a 5-yr outcome
GROUP BY state_code
ORDER BY survival_5yr_pct DESC;

-- E2. Industry stability: 5-year survival by industry
CREATE OR REPLACE VIEW v_industry_stability AS
SELECT
    industry,
    SUM(cohort_n)  AS companies_in_cohorts,
    SUM(survived_n) AS survived_5yr,
    ROUND(100.0 * SUM(survived_n) / SUM(cohort_n), 2) AS survival_5yr_pct
FROM fact_cohort_survival
WHERE survival_year = 5
  AND reg_year <= 2021
GROUP BY industry
ORDER BY survival_5yr_pct DESC;

-- E3. State growth: registrations per year + YoY
CREATE OR REPLACE VIEW v_state_growth AS
WITH yearly AS (
    SELECT EXTRACT(YEAR FROM reg_date)::INT AS reg_year,
           COALESCE(state_code,'') AS state_code,
           COUNT(DISTINCT acn) AS new_companies
    FROM fact_name_record
    WHERE reg_date IS NOT NULL AND is_current
    GROUP BY 1,2
)
SELECT reg_year, state_code, new_companies,
       LAG(new_companies) OVER (PARTITION BY state_code ORDER BY reg_year) AS prev_year,
       ROUND(100.0 * (new_companies - LAG(new_companies) OVER (PARTITION BY state_code ORDER BY reg_year))
                   / NULLIF(LAG(new_companies) OVER (PARTITION BY state_code ORDER BY reg_year),0), 1) AS yoy_pct
FROM yearly;

-- E4. Industry trends: registrations by industry x year
CREATE OR REPLACE VIEW v_industry_trends AS
SELECT EXTRACT(YEAR FROM f.reg_date)::INT AS reg_year,
       fi.industry,
       COUNT(DISTINCT f.acn) AS new_companies
FROM fact_name_record f
JOIN fact_company_industry fi USING (acn)
WHERE f.reg_date IS NOT NULL AND f.is_current
GROUP BY 1,2;

-- E5. Industry coverage audit (bucket sizes + confidence)
CREATE OR REPLACE VIEW v_industry_coverage AS
SELECT industry,
       COUNT(*) AS n_companies,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_total
FROM fact_company_industry
GROUP BY industry
ORDER BY n_companies DESC;

-- #########################################################################
-- PART F — STATS REFRESH
-- #########################################################################
CREATE OR REPLACE TABLE db_stats AS
SELECT 'total_name_records'        AS metric, COUNT(*)::VARCHAR AS value FROM fact_name_record
UNION ALL SELECT 'unique_companies (acn)', COUNT(DISTINCT acn)::VARCHAR FROM fact_name_record
UNION ALL SELECT 'current_companies',     COUNT(*)::VARCHAR FROM fact_name_record WHERE is_current
UNION ALL SELECT 'deregistered',          COUNT(*)::VARCHAR FROM fact_name_record WHERE dereg_date IS NOT NULL
UNION ALL SELECT 'name_changes',          COUNT(*)::VARCHAR FROM name_history
UNION ALL SELECT 'industries_classified', COUNT(*)::VARCHAR FROM fact_company_industry WHERE industry <> 'Other / Unclassified'
UNION ALL SELECT 'foreign_acq_leads',     COUNT(*)::VARCHAR FROM v_foreign_acquisition_leads;

CREATE INDEX IF NOT EXISTS idx_fci_acn ON fact_company_industry(acn);
CREATE INDEX IF NOT EXISTS idx_fci_ind ON fact_company_industry(industry);
