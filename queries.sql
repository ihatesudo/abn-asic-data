-- =========================================================================
-- Example queries for asic.duckdb
-- Run with:  duckdb asic.duckdb < queries.sql
-- =========================================================================

-- 1. Look up a company by name (fuzzy)
SELECT acn, company_name, type_code, reg_date, dereg_date
FROM dim_company
WHERE company_name ILIKE '%BHP%'
LIMIT 10;

-- 2. Full name history of one company (by ACN)
SELECT company_name, reg_date, current_name, current_name_start_date
FROM fact_name_record
WHERE acn = '000000019'
ORDER BY record_id;

-- 3. Registrations per year, last decade (growth trend)
SELECT reg_year, SUM(companies_registered) AS new_companies
FROM v_companies_by_state_year
WHERE reg_year >= 2015
GROUP BY reg_year
ORDER BY reg_year;

-- 4. Survival rate by registration cohort
SELECT reg_year,
       companies_registered,
       still_active,
       ROUND(100.0 * still_active / companies_registered, 1) AS pct_active
FROM v_companies_by_state_year
WHERE state_code = '' AND reg_year >= 2010
ORDER BY reg_year;

-- 5. Top 20 most-renamed companies (M&A / rebrand signal)
SELECT current_name, name_change_count, name_chain
FROM v_name_change_frequency
ORDER BY name_change_count DESC
LIMIT 20;

-- 6. Average lifespan of deregistered companies, by type
SELECT type_code, t.type_desc,
       ROUND(AVG(lifespan_years),1) AS avg_years_alive,
       COUNT(*) AS n
FROM v_lifespan l
JOIN dim_type t USING (type_code)
WHERE lifespan_years BETWEEN 0 AND 150
GROUP BY 1,2
ORDER BY avg_years_alive DESC;

-- 7. Companies registered in your state this year
SELECT company_name, acn, type_desc, reg_date
FROM v_current_companies
WHERE state_code = 'VIC' AND EXTRACT(YEAR FROM reg_date) = 2025
ORDER BY reg_date DESC
LIMIT 20;

-- 8. Dormant shell detection: old companies still registered, never renamed
SELECT c.acn, c.company_name, c.reg_date,
       DATE_DIFF('year', c.reg_date, CURRENT_DATE) AS age_years
FROM dim_company c
WHERE c.status_code = 'REGD'
  AND c.name_record_count = 1
  AND c.reg_date < DATE '1980-01-01'
ORDER BY age_years DESC
LIMIT 20;
