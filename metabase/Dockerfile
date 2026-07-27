# Metabase with DuckDB driver.
# IMPORTANT: must be Debian-based (eclipse-temurin). The stock Alpine
# metabase/metabase image breaks the DuckDB native library (musl vs glibc).
# Driver version must match the Metabase major version exactly.
FROM eclipse-temurin:21-jre-jammy

ARG METABASE_VERSION=v0.58.9
ARG METABASE_DUCKDB_DRIVER_VERSION=1.4.3.1
ENV MB_PLUGINS_DIR=/home/metabase/plugins/
ENV MB_DB_FILE=/home/metabase/metabase.db
ENV MB_JETTY_PORT=3000

RUN groupadd -r metabase && useradd -r -g metabase metabase
RUN apt-get update && apt-get install -y ca-certificates curl && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /home/metabase/plugins /home/metabase/data && \
    chown -R metabase:metabase /home/metabase

WORKDIR /home/metabase

# Metabase core
ADD --chown=metabase:metabase https://downloads.metabase.com/${METABASE_VERSION}/metabase.jar /home/metabase/metabase.jar
# DuckDB driver (must match Metabase version — see repo tags)
ADD --chown=metabase:metabase https://github.com/motherduckdb/metabase_duckdb_driver/releases/download/${METABASE_DUCKDB_DRIVER_VERSION}/duckdb.metabase-driver.jar /home/metabase/plugins/

RUN chmod 755 /home/metabase/metabase.jar && \
    chmod 755 /home/metabase/plugins/duckdb.metabase-driver.jar

EXPOSE 3000
USER metabase
CMD ["java", "-jar", "/home/metabase/metabase.jar"]
