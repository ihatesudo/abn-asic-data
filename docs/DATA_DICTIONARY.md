# Data Dictionary — `asic.duckdb`

A complete reference to every table and view in this database: what it is,
whether it's **raw** (straight from source) or **derived** (computed), how many
rows it has, and the real-world question it answers.

---

## What this database is for

This repo joins two authoritative Australian business datasets so you can ask
questions no single source answers:

- **"Which state is most entrepreneurial?"** → needs state (ABR) + registration dates (ASIC)
- **"How long do companies in each industry survive?"** → needs registration + deregistration (ASIC) + classification
- **"Which big brands are secretly one company?"** → needs trading names (ABR)
- **"Which states are growing or declining?"** → needs state (ABR) + time trends (ASIC)
- **"Was this Aussie brand acquired by a foreign owner?"** → needs name-change history (ASIC)

No single government dataset answers all of these. Joining them does.

### The two source datasets

| Source | What it brings | Rows | Field you can't get elsewhere |
|--------|----------------|------|-------------------------------|
| **ASIC company name register** | ACN, registration/deregistration dates, name-change history, status codes | 4.41M name records → 3.98M companies | When a company was founded, when it died, what it used to be called |
| **ABR bulk extract** | ABN, state, postcode, GST status, trading/business names, entity type | 20.38M entities + 18.6M names | Where a business actually operates, what it trades as, whether it's actively trading |

They join on **ACN = ASICNumber** (the company number). 59.4% of ASIC companies
match an ABN record.

---

## Table classification — Raw vs Derived

| Type | Meaning |
|------|---------|
| **raw** | Loaded directly from source data, untransformed except for type casting |
| **dim** | Small lookup/dimension table (codes → human descriptions) |
| **fact** | Large event/measurement table (the grain of analysis) |
| **bridge** | Links two tables (e.g. company → its industry) |
| **derived** | Computed from other tables — the "answers" layer |
| **view** | Virtual table, recomputed on query (not stored) |

---

## Tables

### Core ASIC layer (company register)

#### `fact_name_record` — `raw` · 4,412,174 rows
**The grain: one row per name record.** A company with 3 prior names + 1
current name = 4 rows. Start here for any trend over time.

| Column | Type | Meaning |
|--------|------|---------|
| record_id | BIGINT | Source row ID |
| acn | VARCHAR | Australian Company Number (join key) |
| company_name | VARCHAR | Name on this record (may be historical) |
| type_code | VARCHAR | Legal structure (APTY/APUB/FNOS/…) |
| class_code | VARCHAR | Liability class (LMSH/LMGT/…) |
| subclass_code | VARCHAR | Sub-class (PROP/PSTC/…) |
| status_code | VARCHAR | REGD / DRGD / SOFF / EXAD / … |
| state_code | VARCHAR | ⚠️ Mostly empty (95%) — use ABR `abr_state` instead |
| reg_date | DATE | Registration date |
| dereg_date | DATE | Deregistration date (null if still active) |
| abn | VARCHAR | ABN if reported on the ASIC record |
| is_current | BOOLEAN | True if this is the company's current name |
| current_name | VARCHAR | The current name (populated on historical rows) |
| current_name_start_date | DATE | When the current name took effect |
| modified_since_last | BOOLEAN | Changed since last ASIC report |

#### `dim_company` — `derived` · 3,978,184 rows
**One row per ACN** — the company entity, de-duplicated to its current name.
Use this for "how many companies exist?" questions.

| Column | Type | Meaning |
|--------|------|---------|
| acn | VARCHAR | PK |
| company_name | VARCHAR | Current canonical name |
| reg_date | DATE | When incorporated |
| dereg_date | DATE | When deregistered (null = active) |
| type_code | VARCHAR | Legal structure |
| status_code | VARCHAR | Current status |
| state_code | VARCHAR | ⚠️ Sparse (5% coverage) |
| abn | VARCHAR | ABN |
| name_record_count | BIGINT | How many name records this company has (proxy for history length) |

#### `name_history` — `derived` · 434,029 rows
**The M&A / restructuring trail.** One row per genuine name change
(previous ≠ current). This is the closest thing to an ownership-transfer signal.

| Column | Type | Meaning |
|--------|------|---------|
| acn | VARCHAR | Company |
| previous_name | VARCHAR | Old name |
| current_name | VARCHAR | New name |
| previous_name_start | DATE | When the old name began |
| current_name_start | DATE | When the new name took effect |

#### `stg_name_record` — `raw` · 4,412,174 rows
Staging table (raw JSON values before typing). Kept for traceability; you
normally query `fact_name_record` instead.

---

### ABR layer (business register)

#### `fact_abr_entity` — `raw` · 20,384,062 rows
**One row per ABN.** The richest single table — state, GST, trading status.

| Column | Type | Meaning |
|--------|------|---------|
| abn | VARCHAR | PK |
| abn_status | VARCHAR | ACT (active) / CAN (cancelled) |
| abn_status_date | DATE | When status changed |
| entity_type_code | VARCHAR | **Authoritative** legal type (PRV/PUB/IND/TRT/SMF/…) — see `dim_abr_entity_type` |
| entity_type_text | VARCHAR | Human-readable type |
| legal_name | VARCHAR | Registered name (or "SURNAME Given" for individuals) |
| is_individual | BOOLEAN | True = sole trader / individual (11M of 20M) |
| abr_state | VARCHAR | **State — 99.7% coverage** (the big fix vs ASIC) |
| postcode | VARCHAR | Postcode of main business location |
| asic_number | VARCHAR | ACN if the entity is a company (join key to ASIC) |
| gst_status | VARCHAR | ACT (registered for GST) / CAN / NON |
| gst_status_date | DATE | When GST status changed |
| dgr_status | VARCHAR | Deductible Gift Recipient status (charities) |
| dgr_status_date | DATE | When DGR status changed |
| record_last_updated | DATE | Last ABR update |
| replaced | VARCHAR | Y/N — superseded by a newer record |

#### `fact_abr_name` — `raw` · 18,609,632 rows
**The umbrella table.** One row per trading/business name. Reveals that one
legal entity often operates dozens of consumer-facing brands.

| Column | Type | Meaning |
|--------|------|---------|
| abn | VARCHAR | FK → fact_abr_entity |
| name_type | VARCHAR | MN (main) / TRD (trading) / OTN (other trading) / BN (business name) / LGL (individual) |
| name_text | VARCHAR | The actual name consumers see |

#### `dim_abr_entity_type` — `derived` · 85 rows
Authoritative lookup of the 85 entity-type codes that actually appear in the
data (PRV→Australian Private Company, IND→Individual/Sole Trader, …).

#### `dim_asic_to_abr_type` — `dim` · 5 rows
Hand-curated cross-walk between ASIC's 5 codes and ABR's taxonomy, with a
confidence flag. Documents that ASIC's `APTY` = ABR's `PRV` (both = Pty Ltd).

---

### Analytics layer (derived answers)

#### `fact_company_industry` — `derived` · 3,978,184 rows
⚠️ **Inferred, not authoritative.** Each company classified to an industry
bucket by keyword matching over legal + trading names. See
[`INDUSTRY_DATA_GAP.md`](INDUSTRY_DATA_GAP.md).

| Column | Type | Meaning |
|--------|------|---------|
| acn | VARCHAR | FK → dim_company |
| company_name | VARCHAR | Name |
| industry | VARCHAR | One of 14 buckets (Mining, Financial Services, …) or "Other / Unclassified" |

#### `fact_cohort_survival` — `derived` · 30,924 rows
**The stability metric.** For each (registration_year × state × industry)
cohort, how many companies were still active at +1/+3/+5/+10 years.

| Column | Type | Meaning |
|--------|------|---------|
| reg_year | INTEGER | Year of registration |
| state_code | VARCHAR | ABR state |
| industry | VARCHAR | Inferred industry |
| cohort_n | BIGINT | Companies registered that year |
| survival_year | INTEGER | 1, 3, 5, or 10 |
| survived_n | HUGEINT | How many survived to that year |
| survival_pct | DOUBLE | % survived |

#### `dim_industry_rule` — `dim` · 91 rows
The editable keyword rules behind industry classification (auditable).
Priority column controls evaluation order.

#### `dim_industry`, `dim_type`, `dim_class`, `dim_subclass`, `dim_status`, `dim_state` — `dim`
Small lookup tables mapping codes to human-readable descriptions.

#### `dim_foreign_keyword` — `dim` · 14 rows
Country-detection keywords (JAPAN, CHINA, USA, …) for the foreign-acquisition lead view.

#### `dim_survival_milestone` — `dim` · 4 rows
The survival checkpoints (1, 3, 5, 10 years).

#### `db_stats` — `derived` · 10 rows
A handy summary table of headline metrics (total companies, ABR match rate,
GST-active count, etc.). Query this first to orient yourself.

---

## Views (the "answers" layer)

All views are virtual — they recompute on query, always current.

| View | English question it answers |
|------|----------------------------|
| **`v_company_full`** | "Show me everything about this company — state, GST, industry, all in one row" |
| **`v_brand_umbrellas`** | "Which single companies secretly own hundreds of consumer brands?" |
| **`v_active_traders_by_state`** | "Where do the real, GST-active businesses cluster?" |
| **`v_state_stability`** | "Which state's companies survive longest?" |
| **`v_state_growth`** | "Which states are growing or shrinking, year by year?" |
| **`v_industry_stability`** | "Which industries have the most durable companies?" |
| **`v_industry_trends`** | "How has each industry's new-company count changed over time?" |
| **`v_industry_coverage`** | "How well did our industry inference work? (bucket sizes)" |
| **`v_industry_concentration`** | "How concentrated is each industry? (top-5 share)" |
| **`v_entity_mix_by_state`** | "What's the legal-structure mix of each state's economy?" |
| **`v_abr_join_coverage`** | "What % of ASIC companies have a matching ABN record?" |
| **`v_foreign_acquisition_leads`** | "Which companies renamed to a foreign-sounding name? (investigation leads)" |
| **`v_name_change_trail`** | "What was this company called before, and when did it change?" |
| **`v_name_change_frequency`** | "Which companies have changed names the most?" |
| **`v_current_companies`** | "Give me the clean list of currently-registered companies" |
| **`v_lifespan`** | "How long did deregistered companies live?" |
| **`v_companies_by_state_year`** | "Registration cohorts by state and year" |
| **`v_type_mix_by_year`** | "Has the entity-type mix shifted over time?" |

---

## Schema relationships (how it all joins)

```
                         ASIC layer                              ABR layer
                         ──────────                              ─────────

  fact_name_record ──┐                              ┌── fact_abr_entity  (20.4M, state/GST)
   (4.4M, history)   │   acn                        │      │ asic_number
                     ▼                              │      ▼
                 dim_company ──────acn=asic_number──▶ fact_abr_entity
                  (3.98M)                          (the join: 59.4% match)
                     │                                  │ abn
                     │ acn                              ▼
                     ▼                              fact_abr_name  (18.6M, the umbrella)
              fact_company_industry
               (inferred industry)
                     │
                     │  industry + state
                     ▼
              fact_cohort_survival  ◀── answers "which industry/state is stable"

  Dimensions (small lookups, join by code):
    dim_type, dim_class, dim_subclass, dim_status, dim_state  (ASIC codes)
    dim_abr_entity_type, dim_asic_to_abr_type                 (ABR codes)
    dim_industry, dim_industry_rule                           (industry buckets)
```

**Key join:** `dim_company.acn = fact_abr_entity.asic_number` — this is what
fuses the two datasets. Everything in `v_company_full` flows from it.

---

## Basic queries (in plain English → SQL)

### "How big is this dataset?"
```sql
SELECT * FROM db_stats;
```

### "Show me a company with all its details"
```sql
SELECT * FROM v_company_full WHERE company_name ILIKE '%FORTESCUE%';
```

### "What brands does one company secretly operate?"
```sql
-- e.g. who's behind all those 7-Eleven stores?
SELECT * FROM v_brand_umbrellas WHERE legal_name ILIKE '%CONVENIENCE%' LIMIT 1;
```

### "Which states have the most active businesses?"
```sql
SELECT * FROM v_active_traders_by_state;
```

### "Which industry's companies survive longest?"
```sql
SELECT * FROM v_industry_stability;  -- ranked by 5-yr survival %
```

### "How has each state grown over the last 5 years?"
```sql
SELECT * FROM v_state_growth
WHERE reg_year >= 2021 AND state_code IN ('NSW','VIC','QLD','WA')
ORDER BY state_code, reg_year;
```

### "Was this Aussie brand renamed to something foreign?"
```sql
SELECT * FROM v_foreign_acquisition_leads
WHERE current_name ILIKE '%CHINA%' OR current_name ILIKE '%JAPAN%'
ORDER BY first_foreign_name_date DESC;
```

### "What was this company called before?"
```sql
SELECT previous_name, current_name, current_name_start
FROM name_history WHERE acn = '000000019';
```

### "Which single companies own the most consumer brands?"
```sql
SELECT legal_name, trading_name_count, name_sample
FROM v_brand_umbrellas ORDER BY trading_name_count DESC LIMIT 20;
```

### "How many ASIC companies match an ABR record?"
```sql
SELECT * FROM v_abr_join_coverage;
```

---

## What's authoritative vs inferred (read this before trusting any number)

| Metric | Trust level | Why |
|--------|-------------|-----|
| State / postcode | ✅ Authoritative | Direct from ABR (99.7% coverage) |
| GST status / active trader | ✅ Authoritative | Direct from ABR |
| Entity type (Pty Ltd, sole trader, trust) | ✅ Authoritative | Direct from ABR/ASIC |
| Registration / deregistration dates | ✅ Authoritative | Direct from ASIC |
| Name-change history | ✅ Authoritative | Direct from ASIC |
| Survival rates | ✅ Authoritative | Computed from the above, math is sound |
| **Industry classification** | ⚠️ **Inferred** | Keyword-matched from names — see [`INDUSTRY_DATA_GAP.md`](INDUSTRY_DATA_GAP.md) |
| **Foreign acquisition** | ⚠️ **Lead only** | Keyword hint from name changes, not confirmed ownership |
| **Corporate ownership/umbrella** | ⚠️ **Partial** | Shows one entity behind many *trading names*, not subsidiary structures |

When in doubt: **state, GST, dates, entity type, and survival are real;
industry and ownership are signals to investigate, not facts.**
