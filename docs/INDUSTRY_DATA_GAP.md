# The Industry Classification Problem — A Data Reality Note

> **TL;DR:** Neither dataset in this project (ASIC name register, ABR public
> bulk extract) contains an authoritative industry classification. Any
> industry field in this database is *inferred from business names* via
> keyword rules, not ground truth. Real industry↔ACN/ABN data exists but is
> not in the free public data — it requires a paid ABR product or restricted
> research access. This document explains why, and what the options are.

## Background

Two questions a user reasonably wants answered from this data:

1. *Which industry is company X in?*
2. *How stable/growing is industry Y?*

Both require a reliable **industry ↔ business** mapping. This section explains
why that mapping is **not present** in the source data and documents the gap
so downstream users don't mistake inferred classifications for fact.

## What the source data actually contains

### ASIC Company Name Register (our `5c3914e6-…json`)
- Fields: ACN, company name (current + historical), type/class/subclass/status
  codes, registration/deregistration dates, state registration number.
- **Industry field:** none. The `type_code` (APTY/APUB/FNOS/…) describes the
  *legal structure* (Pty Ltd, public, foreign), not the industry.

### ABR Public Bulk Extract (our `public_split_1_10` + `_11_20`)
- Fields: ABN, entity type, legal/trading/business names, state, postcode,
  ACN, GST status, DGR (deductible gift recipient) status.
- **Industry field:** **not included in the public extract.** The ABN
  registration form *does* collect an industry answer (see below), but it is
  stripped from the free `public_split_*` files.

### What "industry" looks like when it IS authoritative: ANZSIC
The standard is **ANZSIC** (Australia and New Zealand Standard Industry
Classification) — ~500 codes across 19 divisions (e.g. `B` Mining, `K`
Financial Services, `G` Retail Trade, sub-divisions like `6321` Insurance).
When a business registers for an ABN, the form asks:

> *"What is the main industry your business operates in?"*

This is **self-reported ground truth by the business owner**, coded to ANZSIC.
It is collected — but the public extract redacts it.

## Why our industry classification is only inference

The `fact_company_industry` table in `asic.duckdb` assigns each company to one
of ~14 buckets (Mining, Financial Services, Property, Construction, …) based on
**keyword matching over company name + trading names** (`analytics_v2.sql`).

This approach has hard limits:

| Limitation | Consequence |
|------------|-------------|
| Names are not industry descriptions | "POWERFORM HOLDINGS PTY LTD" says nothing definitive about its industry — it trades as "VARLEY TRANSPORT GROUP", but keyword rules can't reason about that |
| ~65% of names carry no signal | Most Pty Ltds are named "SMITH PTY LTD" or similar — they land in "Other / Unclassified" regardless of the rule quality |
| Shell/trading vehicles dominate | Many "HOLDINGS" companies are investment shells, not active in a single industry |
| No verification possible | We cannot check inferred classifications against truth, because truth is not in the data |
| Structural codes ≠ industry | ASIC `type_code` and ABR `entity_type_code` (PRV/PUB/IND/TRT) describe legal form, not business activity |

An LLM/NLP model would improve the *ambiguous* cases (turning ~65% "Other" into
perhaps ~50%) but it remains **prediction, not measurement** — and would still
be unverifiable and wrong/unmeasurable for millions of shell entities.

## Where authoritative industry↔ABN/ACN data actually lives

Ranked by authority. None are in this project's source data.

### 1. ABR Dataramp API (paid, per-ABN lookup)
- Returns the full ABR record **including the ANZSIC `industryCode`** for a
  given ABN.
- Authoritative (self-reported at registration).
- Cost: paid subscription; per-request pricing.
- Scale problem: 20.4M ABNs in this dataset → bulk enrichment via API is slow
  and expensive. Practical for targeted subsets (e.g. the 3.66M GST-active
  companies), not the full register.
- https://data.gov.au/dataset/abn-business-names

### 2. ABR commercial bulk extract (paid, separate product)
- Same XML schema as our `public_split_*` files **plus an ANZSIC industry
  column**.
- This is the product the free public extract is redacted *from*.
- Paid; license-gated; not downloadable via data.gov.au.

### 3. ABS Integrated Business Register (restricted research access)
- Maintained by the Australian Bureau of Statistics; built from ABR + ATO tax
  data + ABS surveys, with ANZSIC assigned and curated per ABN.
- This is the source behind official ABS industry statistics.
- **Not public.** Access is via **DATALab** (secure on-site or remote
  environment), approved researchers only, **no data export** — you run
  analysis inside the secure environment, you cannot take rows out.
- https://www.abs.gov.au/statistics/microdata

### 4. ATO tax data (not public)
- Business Activity Statements and income tax returns carry industry codes.
- Strictly ATO-held; not accessible outside tax administration.

## Pragmatic recommendations

| Goal | Recommended approach |
|------|----------------------|
| Rough industry signals on the full 20M for free | Keep the keyword inference; treat all `industry` values as **low-confidence** in any analysis or dashboard |
| Accurate industry for a meaningful subset (e.g. active businesses) | Enrich the GST-active ABNs via **ABR Dataramp API** — write a client to pull ANZSIC for a target list |
| Academic / statistical-grade analysis | Apply for **ABS DATALab** access to the Integrated Business Register |
| Just the legal structure (not industry) | Use `entity_type_code` from ABR (PRV/PUB/IND/TRT/…) — this *is* authoritative and already in the data |

## What this means for the dashboards

Every view/table prefixed with an industry breakdown in `asic.duckdb`
(`v_industry_stability`, `v_industry_trends`, `v_industry_coverage`,
`fact_company_industry`) is built on **inferred** classification. Treat the
relative *rankings* (e.g. "Agriculture more stable than Transport") as
directional signals, and **do not cite absolute industry counts as fact** —
they reflect naming patterns, not measured economic activity.

The **state**, **GST status**, **entity type**, and **survival** metrics are
authoritative (they come directly from ABR/ASIC fields). The only soft field
is industry.

## If we later obtain authoritative ANZSIC data

The schema is ready to accept it cleanly:

```sql
-- hypothetical: load an ANZSIC-enriched table (abn, anzsic_code)
CREATE TABLE fact_abr_industry AS
SELECT abn, anzsic_code FROM read_parquet('abr/abr_industry.parquet');

-- then join through ABN -> ACN for authoritative per-company industry
CREATE VIEW v_company_industry_official AS
SELECT c.acn, c.company_name, i.anzsic_code, a.text AS anzsic_text
FROM dim_company c
JOIN fact_abr_entity e ON c.acn = e.asic_number
JOIN fact_abr_industry i ON e.abn = i.abn;
```

Until then, `fact_company_industry` (keyword-inferred) is the best available,
and the `industry` column should always be read as **inferred, not measured**.
