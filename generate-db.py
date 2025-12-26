#!/usr/bin/env python3
# Build a unified normalized SQLite dictionary database from JMdict

import os
import sys
import json
import time
import sqlite3

# -----------------------------
# CONFIG
# -----------------------------
JSON_PATH = "jmdict-eng-3.6.1.json"
DB_PATH = "dictionary.sqlite3"
SURFACE_TOKEN_MAX_LEN = 10
FNV_OFFSET_BASIS_64 = 14695981039346656037
FNV_PRIME_64 = 1099511628211

# -----------------------------
# PRECHECKS
# -----------------------------
if not os.path.exists(JSON_PATH):
    print(f"❌ JSON file not found: {JSON_PATH}")
    sys.exit(1)

if os.path.exists(DB_PATH):
    print("Removing old dictionary.sqlite3...")
    os.remove(DB_PATH)

# -----------------------------
# OPEN DATABASE (iOS SAFE)
# -----------------------------
print("Opening database...")
conn = sqlite3.connect(DB_PATH)

conn.execute("PRAGMA journal_mode = DELETE;")
conn.execute("PRAGMA synchronous = NORMAL;")
conn.execute("PRAGMA foreign_keys = ON;")

cur = conn.cursor()

# -----------------------------
# SCHEMA CREATION
# -----------------------------
print("Creating schema...")

cur.executescript(
"""
CREATE TABLE entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source TEXT NOT NULL,
    source_id TEXT NOT NULL,
    is_common INTEGER NOT NULL DEFAULT 0,
    UNIQUE(source, source_id)
);

CREATE TABLE kanji (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    text TEXT NOT NULL,
    is_common INTEGER NOT NULL DEFAULT 0,
    tags TEXT
);

CREATE TABLE readings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    text TEXT NOT NULL,
    is_common INTEGER NOT NULL DEFAULT 0,
    tags TEXT
);

CREATE TABLE senses (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    order_index INTEGER NOT NULL,
    pos TEXT,
    misc TEXT,
    field TEXT,
    dialect TEXT
);

CREATE TABLE glosses (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sense_id INTEGER NOT NULL REFERENCES senses(id) ON DELETE CASCADE,
    entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    order_index INTEGER NOT NULL,
    lang TEXT NOT NULL,
    text TEXT NOT NULL
);

CREATE TABLE english_index (
    token TEXT NOT NULL,
    entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    PRIMARY KEY (token, entry_id)
);

CREATE VIRTUAL TABLE glosses_fts USING fts5(
    text,
    entry_id UNINDEXED,
    content='glosses',
    content_rowid='id'
);

CREATE TABLE surface_index (
    token_hash INTEGER NOT NULL,
    entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    source TEXT NOT NULL CHECK(source IN ('kanji', 'reading')),
    PRIMARY KEY (token_hash, entry_id, source)
);

CREATE INDEX idx_kanji_text ON kanji(text);
CREATE INDEX idx_readings_text ON readings(text);
CREATE INDEX idx_glosses_text ON glosses(text);
CREATE INDEX idx_english_index_token ON english_index(token);
CREATE INDEX idx_surface_index_hash ON surface_index(token_hash);
"""
)

# -----------------------------
# LOAD JSON
# -----------------------------
print("Loading JSON...")
t0 = time.time()

with open(JSON_PATH, "r", encoding="utf-8") as f:
    data = json.load(f)

words = data.get("words", [])
total = len(words)

print(f"Words found: {total}")

# -----------------------------
# INSERT HELPERS
# -----------------------------
def join_or_none(lst):
    if not lst:
        return None
    return ";".join(lst)

def tokenize_english(text):
    out = []
    word = []
    for ch in text.lower():
        if "a" <= ch <= "z":
            word.append(ch)
        else:
            if word:
                out.append("".join(word))
                word = []
    if word:
        out.append("".join(word))
    return out

def surface_tokens(text, max_len=SURFACE_TOKEN_MAX_LEN):
    chars = list(text)
    n = len(chars)
    tokens = set()
    if n == 0:
        return tokens
    capped = min(max_len, n)
    for length in range(1, capped + 1):
        for start in range(0, n - length + 1):
            segment = "".join(chars[start : start + length])
            tokens.add(segment)
    return tokens

def surface_token_hash(value: str) -> int:
    h = FNV_OFFSET_BASIS_64
    for ch in value:
        h ^= ord(ch)
        h = (h * FNV_PRIME_64) & 0xFFFFFFFFFFFFFFFF
    # Convert to signed 64-bit range for SQLite storage
    if h >= (1 << 63):
        h -= 1 << 64
    return h

def insert_surface_tokens(entry_id, text, source):
    for token in surface_tokens(text):
        hashed = surface_token_hash(token)
        cur.execute(
            "INSERT OR IGNORE INTO surface_index (token_hash, entry_id, source) VALUES (?, ?, ?)",
            (hashed, entry_id, source),
        )

# -----------------------------
# INGEST LOOP
# -----------------------------
print("Beginning insert...")
conn.execute("BEGIN;")

for i, w in enumerate(words, 1):

    j_id = str(w.get("id"))

    kanji_list = w.get("kanji", [])
    kana_list = w.get("kana", [])
    sense_list = w.get("sense", [])

    # Entry common flag
    is_common = 0
    for k in kanji_list + kana_list:
        if k.get("common"):
            is_common = 1
            break

    # Insert entry
    cur.execute(
        "INSERT INTO entries (source, source_id, is_common) VALUES (?, ?, ?)",
        ("jmdict", j_id, is_common),
    )
    entry_id = cur.lastrowid

    # Insert kanji
    for k in kanji_list:
        text = k.get("text")
        if not text:
            continue
        tags = k.get("tags") or []
        cur.execute(
            "INSERT INTO kanji (entry_id, text, is_common, tags) VALUES (?, ?, ?, ?)",
            (entry_id, text, 1 if k.get("common") else 0, join_or_none(tags)),
        )
        if is_common:
            insert_surface_tokens(entry_id, text, "kanji")

    # Insert readings
    for k in kana_list:
        text = k.get("text")
        if not text:
            continue
        tags = k.get("tags") or []
        cur.execute(
            "INSERT INTO readings (entry_id, text, is_common, tags) VALUES (?, ?, ?, ?)",
            (entry_id, text, 1 if k.get("common") else 0, join_or_none(tags)),
        )
        if is_common:
            insert_surface_tokens(entry_id, text, "reading")

    # Insert senses + glosses
    for s_idx, s in enumerate(sense_list):
        pos = join_or_none(s.get("pos") or [])
        misc = join_or_none(s.get("misc") or [])
        field = join_or_none(s.get("field") or [])
        dialect = join_or_none(s.get("dialect") or [])

        cur.execute(
            "INSERT INTO senses (entry_id, order_index, pos, misc, field, dialect) VALUES (?, ?, ?, ?, ?, ?)",
            (entry_id, s_idx, pos, misc, field, dialect),
        )
        sense_id = cur.lastrowid

        for g_idx, g in enumerate(s.get("gloss") or []):
            text = g.get("text")
            if not text:
                continue
            lang = g.get("lang") or "eng"
            cur.execute(
                "INSERT INTO glosses (sense_id, entry_id, order_index, lang, text) VALUES (?, ?, ?, ?, ?)",
                (sense_id, entry_id, g_idx, lang, text),
            )
            gloss_id = cur.lastrowid
            cur.execute(
                "INSERT INTO glosses_fts(rowid, text, entry_id) VALUES (?, ?, ?)",
                (gloss_id, text, entry_id),
            )
            for token in tokenize_english(text):
                cur.execute(
                    "INSERT OR IGNORE INTO english_index (token, entry_id) VALUES (?, ?)",
                    (token, entry_id),
                )

    # Progress printing
    if i % 1000 == 0:
        conn.commit()
        conn.execute("BEGIN;")
        elapsed = time.time() - t0
        pct = (i / total) * 100
        print(f"Processed {i}/{total} entries ({pct:.1f}%) — {elapsed:.1f}s elapsed")

# -----------------------------
# FINALIZE
# -----------------------------
conn.commit()
print("Running VACUUM (this may take a while)...")
conn.execute("VACUUM;")
cur.close()
conn.close()

elapsed = time.time() - t0
print(f"✅ Done. Wrote {DB_PATH} in {elapsed:.1f}s")