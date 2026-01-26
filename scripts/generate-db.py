#!/usr/bin/env python3
# Build a unified normalized SQLite dictionary database from JMdict.
#
# Key behaviors:
# - Uses the same schema as the app's bundled dictionary.sqlite3.
# - Writes to a temp DB and only replaces the old DB on success.
# - Optionally imports example sentence pairs from a TSV into sentence_pairs.

import argparse
import json
import os
import sqlite3
import struct
import sys
import time
from pathlib import Path


FNV_OFFSET_BASIS_64 = 14695981039346656037
FNV_PRIME_64 = 1099511628211


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


def surface_tokens(text, max_len):
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


def insert_surface_tokens(cur, entry_id, text, source, surface_token_max_len):
    for token in surface_tokens(text, max_len=surface_token_max_len):
        hashed = surface_token_hash(token)
        cur.execute(
            "INSERT OR IGNORE INTO surface_index (token_hash, entry_id, source) VALUES (?, ?, ?)",
            (hashed, entry_id, source),
        )


def open_db(db_path: Path) -> sqlite3.Connection:
    # "iOS safe" pragmas for the final on-device bundle.
    conn = sqlite3.connect(str(db_path))
    conn.execute("PRAGMA journal_mode = DELETE;")
    conn.execute("PRAGMA synchronous = NORMAL;")
    conn.execute("PRAGMA foreign_keys = ON;")
    return conn


def create_schema(cur: sqlite3.Cursor):
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

CREATE TABLE kana_forms (
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
    source TEXT NOT NULL CHECK(source IN ('kanji', 'kana')),
    PRIMARY KEY (token_hash, entry_id, source)
);

-- Example sentence pairs (optional ingestion).
CREATE TABLE sentence_pairs (
    jp_id INTEGER NOT NULL,
    en_id INTEGER NOT NULL,
    jp_text TEXT NOT NULL,
    en_text TEXT NOT NULL,
    PRIMARY KEY (jp_id, en_id)
);

CREATE INDEX idx_kanji_text ON kanji(text);
CREATE INDEX idx_kana_forms_text ON kana_forms(text);
CREATE INDEX idx_glosses_text ON glosses(text);
CREATE INDEX idx_english_index_token ON english_index(token);
CREATE INDEX idx_surface_index_hash ON surface_index(token_hash);
CREATE INDEX idx_sentence_pairs_jp_id ON sentence_pairs(jp_id);
CREATE INDEX idx_sentence_pairs_en_id ON sentence_pairs(en_id);

CREATE TABLE embeddings (
  word TEXT PRIMARY KEY,
  vec  BLOB
);
"""
    )


def import_embeddings(conn: sqlite3.Connection, cur: sqlite3.Cursor, bin_path: Path, batch_size: int = 1000):
    if not bin_path.exists():
        raise FileNotFoundError(f"Embeddings file not found: {bin_path}")

    def read_exact(f, n: int) -> bytes:
        data = f.read(n)
        if len(data) != n:
            raise EOFError(f"Unexpected EOF while reading {n} bytes from {bin_path}")
        return data

    inserted = 0
    batch: list[tuple[str, sqlite3.Binary]] = []
    batch_reserve = max(1, batch_size)

    with bin_path.open("rb") as f:
        header = read_exact(f, 8)
        n_words, dim = struct.unpack("<II", header)
        if n_words == 0 or dim == 0:
            raise ValueError(f"Invalid embeddings header: n_words={n_words} dim={dim}")

        vec_nbytes = dim * 4

        for _ in range(n_words):
            raw_len = read_exact(f, 2)
            (word_len,) = struct.unpack("<H", raw_len)
            word_bytes = read_exact(f, word_len)
            word = word_bytes.decode("utf-8")
            vec = read_exact(f, vec_nbytes)

            batch.append((word, sqlite3.Binary(vec)))
            if len(batch) >= batch_reserve:
                cur.executemany("INSERT INTO embeddings (word, vec) VALUES (?, ?)", batch)
                inserted += len(batch)
                batch.clear()

        if batch:
            cur.executemany("INSERT INTO embeddings (word, vec) VALUES (?, ?)", batch)
            inserted += len(batch)
            batch.clear()

    cur.execute("SELECT COUNT(*) FROM embeddings")
    row_count = cur.fetchone()[0]
    if inserted != n_words or row_count != n_words:
        raise RuntimeError(f"Embeddings import count mismatch: header={n_words} inserted={inserted} table_count={row_count}")

    return n_words, dim


def import_sentence_pairs(cur: sqlite3.Cursor, tsv_path: Path):
    if not tsv_path.exists():
        raise FileNotFoundError(f"Sentence TSV not found: {tsv_path}")

    inserted = 0
    skipped = 0
    bad = 0

    # utf-8-sig handles optional BOM.
    with tsv_path.open("r", encoding="utf-8-sig", newline="") as f:
        for line in f:
            # Support both LF and CRLF without leaving a stray '\r' in the text.
            line = line.rstrip("\n\r")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) < 4:
                bad += 1
                continue

            jp_id_s, jp_text, en_id_s, en_text = parts[0], parts[1], parts[2], parts[3]
            try:
                jp_id = int(jp_id_s)
                en_id = int(en_id_s)
            except ValueError:
                bad += 1
                continue

            # Don't overwrite on conflict; sentence corpora can be large and duplicates are expected.
            cur.execute(
                "INSERT OR IGNORE INTO sentence_pairs (jp_id, en_id, jp_text, en_text) VALUES (?, ?, ?, ?)",
                (jp_id, en_id, jp_text, en_text),
            )
            if cur.rowcount == 1:
                inserted += 1
            else:
                skipped += 1

    return inserted, skipped, bad


def print_db_summary(conn: sqlite3.Connection):
    cur = conn.cursor()
    tables = [
        "entries",
        "kanji",
        "kana_forms",
        "senses",
        "glosses",
        "english_index",
        "surface_index",
        "sentence_pairs",
        "embeddings",
    ]

    print("\nSummary:")
    for name in tables:
        cur.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?", (name,))
        exists = cur.fetchone()[0] == 1
        if not exists:
            print(f"  {name}: (missing)")
            continue
        cur.execute(f"SELECT COUNT(*) FROM {name}")
        count = cur.fetchone()[0]
        print(f"  {name}: {count}")
    cur.close()


def resolve_default_paths(repo_root: Path, script_dir: Path):
    # Prefer colocated inputs in scripts/ (common for this repo), then fall back.
    json_candidates = [
        script_dir / "jmdict-eng-3.6.2.json",
        script_dir / "jmdict-eng-3.6.1.json",
        repo_root / "jmdict-eng-3.6.2.json",
        repo_root / "jmdict-eng-3.6.1.json",
        Path.cwd() / "jmdict-eng-3.6.2.json",
        Path.cwd() / "jmdict-eng-3.6.1.json",
    ]

    json_path = next((p for p in json_candidates if p.exists()), json_candidates[0])
    # Default output should be safe and local to the generator script, to avoid
    # accidentally overwriting the app-bundled DB.
    db_path = script_dir / "dictionary.sqlite3"
    return json_path, db_path, json_candidates


def main(argv: list[str]) -> int:
    repo_root = Path(__file__).resolve().parents[1]
    script_dir = Path(__file__).resolve().parent
    default_json, default_db, json_candidates = resolve_default_paths(repo_root, script_dir)
    default_sentences_tsv = (script_dir / "sentence-pairs.tsv").resolve()
    default_embeddings_bin = (script_dir / "cc.ja.300.pruned.f32").resolve()

    parser = argparse.ArgumentParser(
        description="Build dictionary.sqlite3 from JMdict JSON",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--jmdict-json", default=str(default_json), help="Path to JMdict JSON")
    parser.add_argument(
        "--output",
        default=str(default_db),
        help="Output DB path",
    )
    parser.add_argument(
        "--output-next-to-script",
        action="store_true",
        help="Force output DB to be written next to this script (scripts/) using the basename of --output",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Allow overwriting an existing output DB",
    )
    parser.add_argument(
        "--sentences-tsv",
        default=str(default_sentences_tsv) if default_sentences_tsv.exists() else None,
        help="Optional TSV file with columns: jp_id<TAB>jp_text<TAB>en_id<TAB>en_text",
    )
    parser.add_argument(
        "--no-sentences",
        action="store_true",
        help="Disable importing example sentence pairs",
    )
    parser.add_argument(
        "--embeddings-bin",
        default=str(default_embeddings_bin) if default_embeddings_bin.exists() else None,
        help="Optional embeddings binary file (cc.ja.300.pruned.f32)",
    )
    parser.add_argument(
        "--no-embeddings",
        action="store_true",
        help="Disable importing embeddings",
    )
    parser.add_argument(
        "--surface-token-max-len",
        type=int,
        default=10,
        help="Max length for generated surface substring tokens",
    )
    parser.add_argument(
        "--progress-every",
        type=int,
        default=1000,
        help="Print progress every N entries",
    )
    args = parser.parse_args(argv)

    if args.no_sentences:
        args.sentences_tsv = None
    if args.no_embeddings:
        args.embeddings_bin = None

    json_path = Path(args.jmdict_json)
    if not json_path.is_absolute():
        json_path = (repo_root / json_path).resolve()

    output_path = Path(args.output)
    if args.output_next_to_script:
        output_path = (script_dir / output_path.name).resolve()
    else:
        if not output_path.is_absolute():
            output_path = (Path.cwd() / output_path).resolve()

    output_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = output_path.with_name(output_path.name + ".tmp")

    if output_path.exists() and not args.overwrite:
        print(f"Refusing to overwrite existing DB: {output_path}")
        print("Re-run with --overwrite to replace it, or pass a different --output path.")
        return 1

    if not json_path.exists():
        print(f"JSON file not found: {json_path}")
        print("Tried (in order):")
        for cand in json_candidates:
            suffix = " (exists)" if cand.exists() else ""
            print(f"  - {cand}{suffix}")
        print("\nTip: pass an explicit path via --jmdict-json, e.g. --jmdict-json scripts/jmdict-eng-3.6.2.json")
        return 1

    if tmp_path.exists():
        tmp_path.unlink()

    print(f"Building DB from: {json_path}")
    print(f"Temp output DB:  {tmp_path}")
    print(f"Final output DB: {output_path}")

    t0 = time.time()

    conn = None
    cur = None
    try:
        print("Opening temp database...")
        conn = open_db(tmp_path)
        cur = conn.cursor()

        print("Creating schema...")
        create_schema(cur)

        print("Loading JSON...")
        with json_path.open("r", encoding="utf-8") as f:
            data = json.load(f)

        words = data.get("words", [])
        total = len(words)
        print(f"Words found: {total}")

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
                    insert_surface_tokens(
                        cur,
                        entry_id,
                        text,
                        "kanji",
                        surface_token_max_len=args.surface_token_max_len,
                    )

            # Insert kana forms
            for k in kana_list:
                text = k.get("text")
                if not text:
                    continue
                tags = k.get("tags") or []
                cur.execute(
                    "INSERT INTO kana_forms (entry_id, text, is_common, tags) VALUES (?, ?, ?, ?)",
                    (entry_id, text, 1 if k.get("common") else 0, join_or_none(tags)),
                )
                if is_common:
                    insert_surface_tokens(
                        cur,
                        entry_id,
                        text,
                        "kana",
                        surface_token_max_len=args.surface_token_max_len,
                    )

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

            if args.progress_every and (i % args.progress_every == 0):
                conn.commit()
                conn.execute("BEGIN;")
                elapsed = time.time() - t0
                pct = (i / total) * 100 if total else 100
                print(f"Processed {i}/{total} entries ({pct:.1f}%) — {elapsed:.1f}s elapsed")

        conn.commit()

        if args.sentences_tsv:
            sentences_path = Path(args.sentences_tsv)
            if not sentences_path.is_absolute():
                sentences_path = (repo_root / sentences_path).resolve()
            print(f"Importing sentence pairs from: {sentences_path}")
            conn.execute("BEGIN;")
            inserted, skipped, bad = import_sentence_pairs(cur, sentences_path)
            conn.commit()
            print(f"Sentence pairs imported: inserted={inserted} skipped={skipped} bad_lines={bad}")

        if args.embeddings_bin:
            embeddings_path = Path(args.embeddings_bin)
            if not embeddings_path.is_absolute():
                embeddings_path = (repo_root / embeddings_path).resolve()
            print(f"Importing embeddings from: {embeddings_path}")
            conn.execute("BEGIN;")
            n_words, dim = import_embeddings(conn, cur, embeddings_path)
            conn.commit()
            print(f"Embeddings imported: {n_words} rows, dim={dim}")

        # Print a quick sanity summary before VACUUM/replace.
        print_db_summary(conn)

        print("Running VACUUM (this may take a while)...")
        conn.execute("VACUUM;")

        cur.close()
        conn.close()
        cur = None
        conn = None

        # Atomic replacement: only now do we touch the old DB.
        os.replace(str(tmp_path), str(output_path))

        elapsed = time.time() - t0
        print(f"Done. Wrote {output_path} in {elapsed:.1f}s")
        return 0

    except Exception as e:
        print(f"ERROR: {e}")
        return 1

    finally:
        try:
            if cur is not None:
                cur.close()
        except Exception:
            pass
        try:
            if conn is not None:
                conn.close()
        except Exception:
            pass
        # If we failed, keep the existing DB untouched. Clean up temp.
        if tmp_path.exists():
            try:
                tmp_path.unlink()
            except Exception:
                pass


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))