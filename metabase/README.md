# Metabase + DuckDB

Launches Metabase with the DuckDB driver, connected to `asic.duckdb`.

## Run

```bash
cd metabase
docker compose up --build -d     # build image, start detached
docker compose logs -f            # watch startup (look for "DuckDB driver" loaded)
```

Open http://localhost:3000 and complete the one-time setup (name/email).

## Add the DuckDB database

Admin → Databases → **Add database** → type **DuckDB**:

| Field | Value |
|-------|-------|
| Database path | `/data/asic.duckdb` |
| Read-only | ✅ on (recommended) |

All tables and views (`fact_name_record`, `v_company_full`, `v_brand_umbrellas`,
etc.) appear automatically.

## Notes

- **Debian-based image** is required — the stock `metabase/metabase` Alpine
  image breaks the DuckDB native library (musl vs glibc).
- Driver version `1.4.3.1` is pinned to Metabase `v0.58.9`. They are tightly
  coupled — changing one requires changing the other (see build args in
  Dockerfile). Repo: https://github.com/motherduckdb/metabase_duckdb_driver
- DuckDB is single-writer. Mounting read-only avoids lock conflicts with any
  rebuild of `asic.duckdb`. To load new data: stop Metabase, rebuild the DB,
  restart.
- Metabase's own config (your login, saved questions, dashboards) persists in
  `./metabase-data/`.

## Stop / remove

```bash
docker compose down              # stop, keep data
docker compose down -v           # stop and wipe Metabase config
```
