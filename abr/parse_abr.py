#!/usr/bin/env python3
"""
Streaming parser for ABR (Australian Business Register) bulk extract XML.

Input:  ~/Downloads/public_split_1_10/*.xml + public_split_11_20/*.xml
Output: abr/abr_entities.parquet  (one row per ABN — the 1:1 fields)
        abr/abr_names.parquet     (one row per name — the 1:many umbrella)

Design:
  - xml.etree.ElementTree.iterparse for streaming (low RAM on 11.6 GB).
  - Each <ABR> is a complete record (one per line in the source). We clear
    each element after processing to bound memory.
  - Handles MainEntity (companies → NonIndividualName) AND LegalEntity
    (individuals/sole traders → GivenName/FamilyName, no ASICNumber).
  - pyarrow ParquetWriter with batched writes for speed.
"""
import glob
import os
import sys
import time
import xml.etree.ElementTree as ET

import pyarrow as pa
import pyarrow.parquet as pq

SRC_DIRS = [
    os.path.expanduser("~/Downloads/public_split_1_10"),
    os.path.expanduser("~/Downloads/public_split_11_20"),
]
OUT_DIR = os.path.dirname(os.path.abspath(__file__))
ENTITIES_OUT = os.path.join(OUT_DIR, "abr_entities.parquet")
NAMES_OUT = os.path.join(OUT_DIR, "abr_names.parquet")
BATCH = 50_000  # rows buffered before each Parquet write

# ---- date helper: ABR dates are YYYYMMDD strings (or empty) -----------------
def parse_date(s):
    if not s or len(s) != 8:
        return None
    try:
        return f"{s[0:4]}-{s[4:6]}-{s[6:8]}"
    except Exception:
        return None

def text(el, tag):
    """Text of first direct-descendant tag, or None."""
    if el is None:
        return None
    child = el.find(tag)
    return child.text if child is not None else None

# ---- schema ----------------------------------------------------------------
ENTITY_SCHEMA = pa.schema([
    ("abn",              pa.string()),
    ("abn_status",       pa.string()),   # ACT / CAN
    ("abn_status_date",  pa.string()),   # YYYY-MM-DD
    ("entity_type_code", pa.string()),   # PRV / PUB / IND / TRT ...
    ("entity_type_text", pa.string()),
    ("legal_name",       pa.string()),   # company name OR "FAMILY GIVEN"
    ("is_individual",    pa.bool_()),
    ("state",            pa.string()),
    ("postcode",         pa.string()),
    ("asic_number",      pa.string()),   # null for individuals
    ("gst_status",       pa.string()),   # ACT / CAN / NON
    ("gst_status_date",  pa.string()),
    ("dgr_status",       pa.string()),   # ACT or null
    ("dgr_status_date",  pa.string()),
    ("record_last_updated", pa.string()),
    ("replaced",         pa.string()),   # Y / N
])

NAME_SCHEMA = pa.schema([
    ("abn",        pa.string()),
    ("name_type",  pa.string()),   # MN / TRD / OTN / BN / LGL
    ("name_text",  pa.string()),
])


def process_abr(elem):
    """Parse one <ABR> element into (entity_dict, [name_dicts])."""
    names = []

    abn_el = elem.find("ABN")
    abn = abn_el.text if abn_el is not None else None
    abn_status = abn_el.get("status") if abn_el is not None else None
    abn_status_date = parse_date(abn_el.get("ABNStatusFromDate")) if abn_el is not None else None

    et = elem.find("EntityType")
    entity_type_code = text(et, "EntityTypeInd")
    entity_type_text = text(et, "EntityTypeText")

    is_individual = False
    legal_name = None
    state = None
    postcode = None

    # Companies / non-individuals
    main = elem.find("MainEntity")
    if main is not None:
        for n in main.findall("NonIndividualName"):
            nt = n.get("type")
            nx = text(n, "NonIndividualNameText")
            if nt == "MN":  # Main Name — goes into entity row
                legal_name = nx
            else:
                names.append({"abn": abn, "name_type": nt, "name_text": nx})
        addr = main.find("BusinessAddress/AddressDetails")
        if addr is not None:
            state = text(addr, "State")
            postcode = text(addr, "Postcode")

    # Individuals / sole traders
    legal = elem.find("LegalEntity")
    if legal is not None:
        is_individual = True
        given = [g.text for g in legal.findall("IndividualName/GivenName") if g.text]
        family = text(legal.find("IndividualName"), "FamilyName") if legal.find("IndividualName") is not None else None
        parts = [p for p in ([family] + given) if p]
        legal_name = " ".join(parts) if parts else None
        # individuals carry their own name-type marker
        ind = legal.find("IndividualName")
        if ind is not None and legal_name:
            names.append({"abn": abn, "name_type": ind.get("type", "LGL"), "name_text": legal_name})
        addr = legal.find("BusinessAddress/AddressDetails")
        if addr is not None:
            state = text(addr, "State")
            postcode = text(addr, "Postcode")

    # ASIC number (companies only)
    asic_el = elem.find("ASICNumber")
    asic_number = asic_el.text if asic_el is not None else None

    # GST
    gst = elem.find("GST")
    gst_status = gst.get("status") if gst is not None else None
    gst_status_date = parse_date(gst.get("GSTStatusFromDate")) if gst is not None else None

    # DGR (deductible gift recipient) — may be a simple status tag or carry a name
    dgr_status = None
    dgr_status_date = None
    dgr = elem.find("DGR")
    if dgr is not None:
        dgr_status = dgr.get("status") or "ACT"
        dgr_status_date = parse_date(dgr.get("DGRStatusFromDate"))

    # OtherEntity names: TRD (trading), OTN (other trading), BN (business name)
    for oe in elem.findall("OtherEntity"):
        for n in oe.findall("NonIndividualName"):
            nt = n.get("type")
            nx = text(n, "NonIndividualNameText")
            if nt and nx:
                names.append({"abn": abn, "name_type": nt, "name_text": nx})

    entity = {
        "abn": abn,
        "abn_status": abn_status,
        "abn_status_date": abn_status_date,
        "entity_type_code": entity_type_code,
        "entity_type_text": entity_type_text,
        "legal_name": legal_name,
        "is_individual": is_individual,
        "state": state,
        "postcode": postcode,
        "asic_number": asic_number,
        "gst_status": gst_status,
        "gst_status_date": gst_status_date,
        "dgr_status": dgr_status,
        "dgr_status_date": dgr_status_date,
        "record_last_updated": parse_date(elem.get("recordLastUpdatedDate")),
        "replaced": elem.get("replaced"),
    }
    return entity, names


def main():
    files = []
    for d in SRC_DIRS:
        files.extend(sorted(glob.glob(os.path.join(d, "*.xml"))))
    if not files:
        sys.exit(f"No XML files found in {SRC_DIRS}")
    print(f"Found {len(files)} XML files to process")

    ent_buf, name_buf = [], []
    total_entities, total_names = 0, 0
    t0 = time.time()

    ent_writer = pq.ParquetWriter(ENTITIES_OUT, ENTITY_SCHEMA, compression="zstd")
    name_writer = pq.ParquetWriter(NAMES_OUT, NAME_SCHEMA, compression="zstd")

    try:
        for path in files:
            file_n = 0
            ft0 = time.time()
            # iterparse: stream tags, clear after use to bound memory
            for event, elem in ET.iterparse(path, events=("end",)):
                if elem.tag != "ABR":
                    continue
                entity, names = process_abr(elem)
                ent_buf.append(entity)
                name_buf.extend(names)
                file_n += 1
                elem.clear()  # free this element

                if len(ent_buf) >= BATCH:
                    ent_writer.write_table(pa.Table.from_pylist(ent_buf, schema=ENTITY_SCHEMA))
                    name_writer.write_table(pa.Table.from_pylist(name_buf, schema=NAME_SCHEMA))
                    total_entities += len(ent_buf)
                    total_names += len(name_buf)
                    ent_buf, name_buf = [], []
                    if total_entities % 500_000 < BATCH:
                        rate = total_entities / (time.time() - t0)
                        print(f"  {total_entities:>10,} entities, {total_names:>10,} names "
                              f"({rate:,.0f} rec/s)")

            print(f"  {os.path.basename(path)}: {file_n:,} records in {time.time()-ft0:.1f}s")

        # flush remainder
        if ent_buf:
            ent_writer.write_table(pa.Table.from_pylist(ent_buf, schema=ENTITY_SCHEMA))
            name_writer.write_table(pa.Table.from_pylist(name_buf, schema=NAME_SCHEMA))
            total_entities += len(ent_buf)
            total_names += len(name_buf)

    finally:
        ent_writer.close()
        name_writer.close()

    elapsed = time.time() - t0
    print(f"\nDONE: {total_entities:,} entities, {total_names:,} names in {elapsed:.0f}s")
    print(f"  -> {ENTITIES_OUT}")
    print(f"  -> {NAMES_OUT}")


if __name__ == "__main__":
    main()
