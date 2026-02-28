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
- Preferred generator: `scripts/generate_db.py`.
  - Required input:
    - `data/jmdict-eng-3.6.2.json` (or explicit `--jmdict-json`)
  - Optional inputs (safe to omit):
    - `--jmnedict-json` (e.g. `data/jmnedict-all-3.6.2.json`)
    - `--kanjidic2-json` (default `data/kanjidic2-en-3.6.2.json`)
    - `--reading-overrides-tsv` (default `data/reading_overrides.tsv`)
    - `--pitch-tsv` (default `data/pitch_accent.tsv`)
    - `--sentences-tsv` (default `data/sentence-pairs.tsv`)
    - `--embeddings-bin` (default `data/cc.ja.300.pruned.f32`)
  - Output:
    - default `scripts/dictionary.sqlite3`
    - typical app-bundle output: `kyouku/Resources/dictionary.sqlite3`

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
  - Recovered provenance evidence (shell history):
    - `Sentence pairs in Japanese-English - 2026-01-20.tsv`
    - `Sentence pairs in English-Japanese - 2026-01-20.tsv`
  - Current canonical local file checksum:
    - `data/sentence-pairs.tsv` SHA256: `2638c4baf8cb415d99a61af3ed8ae334fcc947f56a44add6c76aeb5506421aee`
- **Pitch accents** (`pitch_accents` table)
  - Recovered provenance (2026-02-27): UniDic/NINJAL kana-accent lexicon source.
  - Source archive (verified working):
    - https://clrd.ninjal.ac.jp/unidic_archive/cwj/2.1.2/unidic-mecab_kana-accent-2.1.2_src.zip
  - Source file inside archive:
    - `unidic-mecab_kana-accent-2.1.2_src/lex.csv`
  - Conversion script in this repo:
    - `scripts/unidic_to_pitch_tsv.py`
  - Output format expected by `scripts/generate_db.py`:
    - `id<TAB>word<TAB>kana<TAB>kind<TAB>accent<TAB>morae`
  - Parsing/mapping used by converter:
    - `word` = `lex.csv` col 0 (surface)
    - `kana` = `lex.csv` col 15 (`pronBase`, normalized to kana/long-vowel marks)
    - `accent` = first integer parsed from `lex.csv` col 27 (`aType`)
    - `morae` = mora count computed from `kana`
    - `kind` = POS subtype (`pos2` fallback `pos1`)
  - Notes:
    - Symbol/blank rows are excluded.
    - Rows with missing/invalid accent or morae are excluded.
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
  - Local artifacts (dev-only) used in this repo:
    - `cc.ja.300.bin` (SHA256: `217faf8282042e912612da78cf0002ec4fcde716643ae093058f6274c80d93b3`)
    - `cc.ja.300.vec` (SHA256: `6aeddf072d66bf1242a62c9db1fc26db03032db1b6f2859382198b5398ae4adb`)
    - `cc.ja.300.pruned.vec` (header: `30000 300`; SHA256: `c513c0c9880bceb23383438250aee5a4125e619db6d8cfef3219554ac340ab83`)
    - `cc.ja.300.pruned.f32` (binary float32 vectors; expected header: `n_words=30000`, `dim=300`; current local SHA256: `9269e34e7186af3b2a5e5216354626bc1c18892db7103bf412b8d40eda793de6`)
    - Pruning helper list: `data/keep_vocab.top30k.txt`
  - How it’s imported into the bundle DB:
    - `scripts/generate_db.py --embeddings-bin data/cc.ja.300.pruned.f32`
  - Rebuild workflow in this repo:
    1. Download `cc.ja.300.vec.gz` from fastText and decompress to `data/cc.ja.300.vec`.
    2. Build keep vocab (`data/keep_vocab.top30k.txt`) from JMdict surfaces/readings.
    3. Build `data/cc.ja.300.pruned.f32` with:
      - `scripts/build_pruned_embeddings_f32.py --vec-file data/cc.ja.300.vec --keep-vocab data/keep_vocab.top30k.txt --output data/cc.ja.300.pruned.f32`
  - Note: the bundled `dictionary.sqlite3` does not store upstream provenance metadata; treat this document as the record of source/license/citation.

### 1.3 Reproducible recovery playbook (if local data is wiped)

If `data/` is deleted locally, rebuild with these steps:

1. Restore/download core source files:
   - `data/jmdict-eng-3.6.2.json`
   - optional: `data/sentence-pairs.tsv`
2. Rebuild pitch accents from UniDic kana-accent source:
   - download: `https://clrd.ninjal.ac.jp/unidic_archive/cwj/2.1.2/unidic-mecab_kana-accent-2.1.2_src.zip`
  - convert with `scripts/unidic_to_pitch_tsv.py` to `data/pitch_accent.tsv`
3. Rebuild embeddings:
   - obtain `data/cc.ja.300.vec`
   - build `data/keep_vocab.top30k.txt`
  - run `scripts/build_pruned_embeddings_f32.py` to produce `data/cc.ja.300.pruned.f32`
4. Rebuild DB:
   - `python3 scripts/generate_db.py --jmdict-json data/jmdict-eng-3.6.2.json --output kyouku/Resources/dictionary.sqlite3 --overwrite`

Supporting automation in this repo:
- `scripts/data_manifest.template.json`
- `scripts/build_sentence_pairs_tsv.py`
- `scripts/build_pruned_embeddings_f32.py`
- `scripts/unidic_to_pitch_tsv.py`

Generated artifact ownership (one script per generated file):
- `data/sentence-pairs.tsv` -> `scripts/build_sentence_pairs_tsv.py` (source lineage: Tatoeba exports)
- `data/pitch_accent.tsv` -> `scripts/unidic_to_pitch_tsv.py`
- `data/cc.ja.300.pruned.f32` -> `scripts/build_pruned_embeddings_f32.py`
- `kyouku/Resources/dictionary.sqlite3` -> `scripts/generate_db.py`

### 1.4 Current pinned artifact checksums (2026-02-27)

- `data/jmdict-eng-3.6.2.json`
  - SHA256: `1c6fb944f8e3a26d71c73bca8a024e0d5e34fea7a728842e162dc4bfc32850eb`
  - Source lineage: scriptin/jmdict-simplified 3.6.2 release family (`jmdict-eng-3.6.2+*.json.zip`)
- `data/pitch_accent.tsv`
  - SHA256: `85f0073ef6b471e2a9b1d22c1c47e08a5321dd4e530b8d89ca02f49dd663d53b`
  - Derived from UniDic kana-accent archive via `scripts/unidic_to_pitch_tsv.py`
- `data/sentence-pairs.tsv`
  - SHA256: `2638c4baf8cb415d99a61af3ed8ae334fcc947f56a44add6c76aeb5506421aee`
  - Source lineage: local exports dated 2026-01-20 (JP↔EN pair files; see above)
- `data/keep_vocab.top30k.txt`
  - SHA256: `fa7f13be088ba66ab06c3eeaea6757a5a032b4da72be71f4e68efa47b675fce1`
  - Derived from JMdict kanji/kana set
- `data/cc.ja.300.pruned.f32`
  - SHA256: `9269e34e7186af3b2a5e5216354626bc1c18892db7103bf412b8d40eda793de6`
  - Derived from fastText `cc.ja.300.vec` + keep vocab
- `kyouku/Resources/dictionary.sqlite3`
  - SHA256: `59ac3eccd25f33860fd082a1d0ba4dede9e6d2c3b7c61458794141cbdc6991c6`
  - Built by `scripts/generate_db.py` with currently available optional inputs

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
