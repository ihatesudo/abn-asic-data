# ASIC + ABR Company Data — DuckDB Analytics DB

A normalized, analytics-ready DuckDB database joining the **ASIC company name
register** with the **ABR (Australian Business Register) bulk extract**.

and bit of HSC test enrolment data 2025.

## What's in here

Since i have crunched the data for ya, you can inspect and play with data source in DuckDB, or BYO

If use free Data Visisulisation / BI tool **metabase** to load up dataset (this repo is about) to answer questions like:

- What is the oldest business in australia:
  Westpac opened in 1813, and guess who else ?
- How long Costco register first abn then wait and scale to get the first GST paid:
  2y (probably realistic Australian speed for get supply chain and infra done)
- Where we are in oversea business M&A and purchase records:
  Recently MLC, David Jones is no longer national owned, guess who bought them ?
- Umbrella company stats:
  Which franchise is most successful in this country ? (indication of dominance).
  Is this anytime fitness or plus fitness.
  
- Which industry experience lowest death rate (ABN got de-registration and ASIC has outline news for bankruptcy and insolvency).
  
- What happened to specific well known business:
  e.g. BORAL (L G C) (AUST) LTD ->  ORIGIN (LGC) (AUST) PTY LIMITED
  
- Where does the restaurant goes ? which suburb is suitable for retail success and (eventually sale of the business) ?
  BUTCHERS BUFFET EASTWOOD PTY LTD (was) -> BUTCHERS BUFFET CASTLE HILL PTY LTD

## side track

HSC course distribution 2025, "Which course is most subscribed and sort of competitive analysis"

<img width="1638" height="1638" alt="image" src="https://github.com/user-attachments/assets/5d4cb697-4428-4569-a0a5-fbf2363dfcbd" />

## Visual

<img width="1884" height="800" alt="image" src="https://github.com/user-attachments/assets/50c1988d-2cdc-48f5-be46-030ef38b7ad8" />

<img width="3040" height="1666" alt="image" src="https://github.com/user-attachments/assets/903d22a0-f26f-466e-be61-ea366673bdc1" />



Two authoritative Australian business datasets, joined on ACN:
- **ASIC** (4.4M name records → 3.98M companies) — registration history, name changes, status
- **ABR** (20.4M entities, 18.6M trading names) — state, postcode, GST status, trading/business names

The join gives each ASIC company its real-world **state** (99.7% coverage vs
ASIC's 5%), **GST-active trading status**, and the full set of **trading names**
that reveal hidden ownership structures.

## Files

| File | Purpose |
|------|---------|
| `5c3914e6-…json` | Original ASIC source (607 MB) |
| `asic.duckdb` | **The database** — query this |
| `schema.sql` | Base ASIC schema (fact + dims) |
| `analytics.sql` | Industry inference, concentration, foreign-acq leads, cohort survival |
| `analytics_v2.sql` | **v2**: industry via trading names, ABR-state analytics, fixed survival |
| `abr_schema.sql` | ABR layer: load Parquet + ASIC⟕ABR join + brand umbrellas |
| `abr/parse_abr.py` | Streaming XML→Parquet parser for ABR bulk extract |
| `abr/*.parquet` | Parsed ABR data (915 MB, from 11.6 GB XML) |
| `queries.sql` | Example queries |
| **`docs/DATA_DICTIONARY.md`** | **Every table & view explained — raw vs derived, columns, the English question each answers** |
| `docs/INDUSTRY_DATA_GAP.md` | Why industry classification is inferred, not authoritative |

## Data sources

This database is built from two free public datasets published on
**data.gov.au** (Australian Government open data portal). Both are
authoritative government registers; we only transform and join them.

| Source | Dataset | Local file | What it contributes | License |
|--------|---------|------------|---------------------|---------|
| **ASIC** | [ASIC - Company Dataset](https://data.gov.au/data/dataset/asic-companies) (National Companies Register) | `5c3914e6-413e-4a2c-b890-bf8efe3eabf2.json` | ACN, company names (current + historical), legal type/class, status, registration & deregistration dates, name-change history | Crown © — freely usable with attribution |
| **ABR** | [ABN Bulk Extract](https://data.gov.au/data/dataset/abn-bulk-extract) (Australian Business Register) | `~/Downloads/public_split_1_10/`, `~/Downloads/public_split_11_20/` (XML) → `abr/*.parquet` | ABN, state & postcode (99.7% coverage), GST status, trading/business names, authoritative entity type | Crown © — freely usable with attribution |

**How they join:** ASIC's `ACN` ↔ ABR's `ASICNumber`. 59.4% of ASIC companies
match an ABR record. ASIC contributes *when a company was founded/died and
what it used to be called*; ABR contributes *where it operates, what it trades
as, and whether it's actively trading*.

> **Note on industry:** Neither source contains an industry/ANZSIC field.
> Industry classification in this database is inferred from business names.
> See [`docs/INDUSTRY_DATA_GAP.md`](docs/INDUSTRY_DATA_GAP.md) for why and
> where authoritative industry data actually lives.

## Quick start

```bash
duckdb asic.duckdb                      # interactive shell
duckdb asic.duckdb < queries.sql        # examples
```

```python
import duckdb
con = duckdb.connect("asic.duckdb")
df = con.execute("SELECT * FROM v_company_full LIMIT 10").df()
```

## Rebuild from source

Sources (download first, see [Data sources](#data-sources)):
- ASIC: `5c3914e6-413e-4a2c-b890-bf8efe3eabf2.json`
- ABR: `~/Downloads/public_split_1_10/`, `~/Downloads/public_split_11_20/`

```bash
# 1. ASIC layer (ASIC - Company Dataset)
python3 convert_ndjson.py                          # JSON → NDJSON
duckdb asic.duckdb < schema.sql                    # base schema
duckdb asic.duckdb < analytics.sql                 # industry + survival v1
duckdb asic.duckdb < analytics_v2.sql              # v2 (trading names + ABR state)

# 2. ABR layer (ABN Bulk Extract)
python3 abr/parse_abr.py                           # XML → Parquet (4 min)
duckdb asic.duckdb < abr_schema.sql                # load + join
```

## Schema overview

```
ASIC layer                              ABR layer
─────────────                           ─────────
fact_name_record                        fact_abr_entity    (20.4M ABNs)
dim_company ──────acn=asic_number──────▶ fact_abr_name     (18.6M trading names)
fact_company_industry                   dim_abr_entity_type (authoritative)
name_history                            dim_asic_to_abr_type (cross-walk)

Key views:
  v_company_full          ASIC ⟕ ABR enriched master (state, GST, industry)
  v_brand_umbrellas       one entity behind many trading names
  v_active_traders_by_state  GST-active businesses by state
  v_state_stability       5-yr survival by state (ABR state, 99.7% coverage)
  v_industry_stability    5-yr survival by industry
  v_state_growth          registrations/year + YoY by state
  v_industry_trends       registrations by industry × year
  v_foreign_acquisition_leads  name changes with foreign-origin signal
```

## Dataset facts

| Metric | Value |
|--------|-------|
| ASIC name records | 4,412,174 |
| ASIC unique companies | 3,978,184 |
| ABR entities | 20,384,062 |
| ABR trading/business names | 18,609,632 |
| ABR individuals (sole traders) | 11,073,527 |
| ABR state coverage | **99.7%** |
| ASIC⟕ABR match rate | 59.4% (2.36M companies) |
| GST-active traders | 3,658,174 |
| Documented name changes | 434,029 |

## Key findings

- **Brand umbrellas**: one legal entity often hides behind hundreds of consumer
  brands. E.g. AUSTRALIAN LEISURE & HOSPITALITY GROUP (439 hotel names),
  Convenience Holdings (332 7-Eleven stores), INVOCARE (294 funeral homes),
  G8 Education (349 childcare centres).
- **State analytics**: NSW leads with 1.22M active traders, VIC 1.01M, QLD 691K.
  SA/TAS/WA have the highest 5-yr survival (~98.4%); ACT lowest (97.8%).
- **Industry stability**: Agriculture & Super funds most stable (99.1% 5-yr
  survival); Transport & generic "Other" least (97.8%).
- **COVID surge**: 2021 registrations jumped +28-35% YoY across all states.

## Honest limitations

- **Industry is inferred** from name keywords (trading + legal), not official
  ANZSIC classification. ~65% of companies land in "Other" because their names
  carry no industry signal — this is real, not a bug. **See
  [`docs/INDUSTRY_DATA_GAP.md`](docs/INDUSTRY_DATA_GAP.md)** for the full
  explanation of why authoritative industry↔ACN/ABN data is not in the public
  source and where it actually lives (paid ABR products / ABS DATALab). Every
  industry-based view is directional inference, treat rankings as signals not
  facts; state/GST/entity-type/survival metrics are authoritative.
- **No ownership/parent-child field** in either dataset. The "umbrella" view
  shows one entity behind many *trading names*, not corporate subsidiaries.
  True beneficial ownership requires ASIC's separate ownership register.
- **Foreign-acquisition leads** (`v_foreign_acquisition_leads`) are keyword
  hints from name changes (e.g. a name changing to include "JAPAN"/"CHINA"),
  not confirmed ownership transfers.

## Edudata

docker cp ~/Downloads/nsw_hsc_2025.duckdb metabase_duckdb:/data/nsw_hsc_2025.duckdb

