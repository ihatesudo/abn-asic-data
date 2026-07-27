#!/usr/bin/env python3
"""Stream-convert ASIC JSON {fields, records:[[...]]} -> NDJSON, one record-array per line."""
import json, time, mmap

src = "5c3914e6-413e-4a2c-b890-bf8efe3eabf2.json"
dst = "records.ndjson"
t0 = time.time()

with open(src, "rb") as f:
    mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    rec_key = mm.find(b'"records"')
    arr_start = mm.find(b"[", rec_key)
    pos = arr_start + 1
    depth = 0
    rec_start = None
    n = 0
    with open(dst, "w") as o:
        while pos < len(mm):
            c = mm[pos]
            if c == 91:  # '['  (inner arrays)
                if depth == 0:
                    rec_start = pos
                depth += 1
            elif c == 93:  # ']'
                if depth > 0:
                    depth -= 1
                    if depth == 0 and rec_start is not None:
                        chunk = mm[rec_start:pos + 1].decode("utf-8")
                        o.write(chunk + "\n")
                        n += 1
                        rec_start = None
                        if n % 500000 == 0:
                            print(f"  wrote {n:,} records... ({time.time()-t0:.1f}s)")
            pos += 1
print(f"DONE: {n:,} records in {time.time()-t0:.1f}s")
