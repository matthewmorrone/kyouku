# Data resources (required + attribution)

This document is the canonical inventory of **data resources** used by Kyouku.

Goals:
- Make it obvious which files are **required to build/run** the app.
- Record **where each dataset came from** and what **attribution** is needed.
- Separate **runtime-bundled** data from **dev-only** downloads under `data/`.

> Scope note: this doc focuses on **data** (datasets, DBs, dictionaries, rule files). It is not a full dependency/license inventory for code.

## 1) Runtime-bundled assets (must be present in the app bundle)

### 1.1 `kyouku/Resources/dictionary.sqlite3`

**What it is**
- A unified SQLite database used for:
  - JMdict-derived dictionary lookup (entries/readings/glosses + indexes)
  - optional example sentence pairs
  - optional word embeddings

**Where it’s loaded**
- Many call sites load `dictionary.sqlite3` from the main bundle via `Bundle.main.url(forResource: "dictionary", withExtension: "sqlite3")`.

**Schema (high level)**
- Dictionary tables/indexes:
  - `entries`, `kanji`, `kana_forms`, `senses`, `glosses`
  - `english_index`, `surface_index`, `glosses_fts`
- Optional feature tables:
  - `sentence_pairs` (example JP/EN sentence pairs)
  - `embeddings` (word → float32 vector blob)

**Current bundle contents (for sanity checks)**
- Table counts (as of the current bundled DB):
  - `entries`: 214,926
  - `kanji`: 227,372
  - `kana_forms`: 260,600
  - `glosses`: 431,063
  - `sentence_pairs`: 279,538
  - `embeddings`: 30,000
- Embedding vector blob size: 1,200 bytes (suggests 300-dim float32 vectors)

**How it’s built / updated**
- Preferred generator: `scripts/generate-db.py`.
  - Input: a JMdict JSON file (expected names include `jmdict-eng-3.6.1.json`, `jmdict-eng-3.6.2.json`).
  - Optional inputs:
    - `--jmnedict-json`: JMnedict JSON (names / proper nouns; expected names include `jmnedict-all-3.6.2.json`)
    - `--sentences-tsv`: TSV containing `jp_id<TAB>jp_text<TAB>en_id<TAB>en_text`
    - `--embeddings-bin`: binary embeddings file (script default name: `cc.ja.300.pruned.f32`)
  - Output: a `dictionary.sqlite3` with the schema above.

**Upstream data sources & attribution**
- **JMdict** (dictionary entries and tags)
  - Source: Electronic Dictionary Research and Development Group (EDRDG)
  - Project/info: http://www.edrdg.org/jmdict/j_jmdict.html
  - Attribution expectation: JMdict/EDICT-style credit to EDRDG (exact wording depends on your UI/legal preference).
- **JMnedict** (names / proper nouns)
  - Source: Electronic Dictionary Research and Development Group (EDRDG)
  - Project/info: http://www.edrdg.org/enamdict/enamdict_doc.html
  - Attribution expectation: JMnedict/ENAMDICT-style credit to EDRDG.
- **Example sentence pairs** (`sentence_pairs` table)
  - The ID ranges + formatting strongly resemble the **Tatoeba Project** sentence corpus.
  - Project: https://tatoeba.org/
  - Licensing: varies by sentence/contributor; verify the exact license terms for the dataset you imported.
  - Action item: record which export you used (date, URL, license notes) and preserve the source TSV or generation steps.
- **Embeddings** (`embeddings` table)
  - Upstream source: fastText pretrained “Word vectors for 157 languages” (Common Crawl + Wikipedia), Japanese model `cc.ja.300`.
    - Project page: https://fasttext.cc/docs/en/crawl-vectors.html
    - Download URLs (compressed):
      - https://dl.fbaipublicfiles.com/fasttext/vectors-crawl/cc.ja.300.bin.gz
      - https://dl.fbaipublicfiles.com/fasttext/vectors-crawl/cc.ja.300.vec.gz
    - License (per fastText docs): Creative Commons Attribution-Share-Alike 3.0
      - https://creativecommons.org/licenses/by-sa/3.0/
    - Citation (per fastText docs):
      - E. Grave, P. Bojanowski, P. Gupta, A. Joulin, T. Mikolov, “Learning Word Vectors for 157 Languages” (LREC 2018)
      - https://arxiv.org/abs/1802.06893
  - Local artifacts (dev-only) currently present under `data/embeddings/`:
    - `cc.ja.300.bin` (SHA256: `217faf8282042e912612da78cf0002ec4fcde716643ae093058f6274c80d93b3`)
    - `cc.ja.300.vec` (SHA256: `6aeddf072d66bf1242a62c9db1fc26db03032db1b6f2859382198b5398ae4adb`)
    - `cc.ja.300.pruned.vec` (header: `30000 300`; SHA256: `c513c0c9880bceb23383438250aee5a4125e619db6d8cfef3219554ac340ab83`)
    - `cc.ja.300.pruned.f32` (binary float32 vectors; expected header: `n_words=30000`, `dim=300`; SHA256: `6bee3d826b16486b1b1f2626ade2448db05ec567de5ee865a2d33f2e425bb81a`)
    - Pruning helper lists (e.g. `keep_vocab.top30k.txt`, plus other vocab/debug files)
  - How it’s imported into the bundle DB:
    - `scripts/generate-db.py --embeddings-bin data/embeddings/cc.ja.300.pruned.f32`
  - Note: the bundled `dictionary.sqlite3` does not store upstream provenance metadata; treat this document as the record of source/license/citation.

### 1.2 `kyouku/Resources/deinflect.min.json`

**What it is**
- A small set of Japanese deinflection (deconjugation) rules used to turn inflected surfaces into lemma candidates.

**Where it’s loaded**
- Loaded via `Deinflector.loadBundled(...)` which looks for `deinflect.json` first, then falls back to `deinflect.min.json`.

**Upstream & attribution**
- The rule file format is **Yomichan-compatible** (see the reference in `kyouku/Deinflector.swift`).
- Action item: preserve provenance for how `deinflect.min.json` was produced (whether copied/derived from Yomichan rule data, manually curated, etc.) and credit the upstream source accordingly.

## 2) Dependency-bundled datasets (not stored in this repo as files)

### 2.1 IPADic dictionary (via Swift Package)

**What it is**
- The app uses MeCab tokenization + POS tags + readings via the Swift package `Mecab_Swift` and its `IPADic` target.
- `IPADic` includes dictionary files as a package resource bundle at build time.

**Why it matters**
- This dataset is required for “Stage 2” reading attachment and some boundary/morphology logic.

**Attribution**
- IPADic / MeCab dictionaries have their own license/attribution requirements.
- Action item: in your final Credits/About UI, include an entry for the MeCab/IPADic dictionary source referenced by the `Mecab_Swift` package.

## 3) Dev-only / optional datasets (NOT required to build/run)

Everything under `data/` is currently treated as **developer scratch space** / optional corpora.

This folder may contain large datasets that could power **future features** (pitch accent, kanji metadata, names, etymology, audio examples, etc.), but these are not required unless/until you explicitly add them to the app bundle or generator pipeline.

Important:
- `data/` and `data/maybe/` are not a canonical inventory; they are local scratch/triage areas.
- Only add a dataset to this document with a concrete plan to keep it long-term and/or ship it.

Common examples of dev-only datasets:
- Pitch accent sources (TSV/CSV/XLSX)
- Kanji metadata (KANJIDIC2, radicals)
- Names dictionaries (JMnedict/enamdict)
- Wiktionary dumps for etymology/usage mining
- Wadoku dumps
- UniDic distributions and derived tries
- Extra sentence corpora / audio metadata

If you later choose to ship any of these inside the app bundle, add them to section 1 with explicit attribution.

## 4) On-device user data files (generated at runtime)

These are not bundled; they are created in the app’s Documents directory:
- `notes.json`
- `words.json`
- `word-lists.json`
- `reading-overrides.json`
- `token-spans.json`

Backups are exported/imported via a single `AppDataBackup` JSON.

## 5) Practical credit checklist

When you’re preparing a public build:
1. List every shipped dataset in section 1 (and any dependency-bundled datasets in section 2).
2. For each dataset, record:
   - canonical upstream project URL
   - license URL and version
   - the exact dump/version/date you used
   - any required attribution text
3. Add a Settings → About/Credits screen that includes those attributions.

---

If you update `dictionary.sqlite3`, also update the “Current bundle contents” counts above (or replace with a small script/command you run during release prep).
