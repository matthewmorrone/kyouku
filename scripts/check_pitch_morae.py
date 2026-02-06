#!/usr/bin/env python3
from __future__ import annotations

"""Sanity-check pitch mora counts in data/pitch_accent.tsv.

This file is expected to have 6 columns after stripping `image`:
  id\tword\tkana\tkind\taccent\tmorae

We validate that:
- `morae` matches a computed mora count from `kana`
- show how often `morae` differs from plain character length of `kana`

Notes on mora counting:
- Small kana (ゃゅょぁぃぅぇぉ etc.) usually combine with the previous kana.
- Sokuon (っ/ッ) counts as a mora.
- Prolonged sound mark (ー) counts as a mora.
- Middle dots/spaces are ignored.
"""

from dataclasses import dataclass
from pathlib import Path

TSV_PATH = Path("data/pitch_accent.tsv")

SMALL_Y = set("ゃゅょゎャュョヮ")
SMALL_VOWELS = set("ぁぃぅぇぉァィゥェォ")
SMALL_OTHER = set("ゕゖヵヶ")
SOKUON = set("っッ")
PROLONG = "ー"
IGNORE = set(" ・･\u00b7◦")


def is_kana(ch: str) -> bool:
    o = ord(ch)
    return (0x3040 <= o <= 0x309F) or (0x30A0 <= o <= 0x30FF)


def mora_count_phonological(reading: str) -> int:
    count = 0
    saw_base = False

    for ch in reading:
        if ch in IGNORE:
            continue

        if ch == PROLONG:
            count += 1
            saw_base = False
            continue

        if ch in SOKUON:
            count += 1
            saw_base = False
            continue

        if ch in SMALL_Y or ch in SMALL_VOWELS or ch in SMALL_OTHER:
            # Phonological-ish: all small kana combine with previous base kana.
            if not saw_base:
                count += 1
            saw_base = False
            continue

        if is_kana(ch):
            count += 1
            saw_base = True
            continue

        # Non-kana: treat as separator; do not guess.
        saw_base = False

    return count


def mora_count_tsv_style(reading: str) -> int:
    """Mora counting that matches the TSV more closely.

    Empirically, the TSV's `morae` behaves like "kana units" where:
    - small ya/yu/yo/wa combine with the previous kana
    - small vowels (ァィゥェォ/ぁぃぅぇぉ) count as their own unit

    This makes loanword sequences like ティ count as 2.
    """

    count = 0
    saw_base = False

    for ch in reading:
        if ch in IGNORE:
            continue

        if ch == PROLONG:
            count += 1
            saw_base = False
            continue

        if ch in SOKUON:
            count += 1
            saw_base = False
            continue

        if ch in SMALL_Y:
            if not saw_base:
                count += 1
            saw_base = False
            continue

        if ch in SMALL_VOWELS:
            count += 1
            saw_base = False
            continue

        if is_kana(ch):
            count += 1
            saw_base = True
            continue

        saw_base = False

    return count


@dataclass
class Mismatch:
    line_no: int
    word: str
    kana: str
    morae_file: int
    morae_calc: int


def main() -> None:
    if not TSV_PATH.exists():
        raise SystemExit(f"Missing: {TSV_PATH}")

    rows = 0
    rows_with_morae = 0
    missing_morae = 0
    missing_accent = 0
    mismatches: list[Mismatch] = []
    mismatch_count = 0
    mismatch_tsv_style_count = 0
    mismatch_tsv_style_samples: list[Mismatch] = []
    morae_ne_len_count = 0

    with TSV_PATH.open("r", encoding="utf-8", newline="") as f:
        header = f.readline().rstrip("\n").split("\t")
        if len(header) != 6:
            raise SystemExit(f"Unexpected header columns ({len(header)}): {header}")

        for line_no, line in enumerate(f, start=2):
            line = line.rstrip("\n")
            if not line:
                continue

            parts = line.split("\t")
            if len(parts) != 6:
                raise SystemExit(f"Unexpected col count at line {line_no}: {len(parts)}")

            _id, word, kana, kind, accent_s, morae_s = parts
            if not accent_s:
                missing_accent += 1
                rows += 1
                continue

            if not morae_s:
                missing_morae += 1
                rows += 1
                continue

            try:
                morae_file = int(morae_s)
            except ValueError:
                # Treat non-integers as missing instead of hard failing so we can
                # get useful overall stats.
                missing_morae += 1
                rows += 1
                continue

            morae_calc = mora_count_phonological(kana)
            morae_calc_tsv = mora_count_tsv_style(kana)
            if morae_calc != morae_file:
                mismatch_count += 1
                if len(mismatches) < 25:
                    mismatches.append(
                        Mismatch(
                            line_no=line_no,
                            word=word,
                            kana=kana,
                            morae_file=morae_file,
                            morae_calc=morae_calc,
                        )
                    )

            if morae_calc_tsv != morae_file:
                mismatch_tsv_style_count += 1
                if len(mismatch_tsv_style_samples) < 10:
                    mismatch_tsv_style_samples.append(
                        Mismatch(
                            line_no=line_no,
                            word=word,
                            kana=kana,
                            morae_file=morae_file,
                            morae_calc=morae_calc_tsv,
                        )
                    )

            if len(kana) != morae_file:
                morae_ne_len_count += 1

            rows_with_morae += 1

            rows += 1

    print(f"Rows checked (excluding header): {rows}")
    print(f"Rows with usable morae: {rows_with_morae}")
    print(f"Rows missing accent: {missing_accent}")
    print(f"Rows missing/invalid morae: {missing_morae}")
    print(f"Morae mismatches (computed vs file): {mismatch_count}")
    print(f"Morae mismatches (tsv-style vs file): {mismatch_tsv_style_count}")
    print(f"Rows where morae != len(kana): {morae_ne_len_count}")

    if mismatches:
        print("\nFirst mismatches (line_no\tword\tkana\tmorae_file\tmorae_calc):")
        for m in mismatches:
            print(f"{m.line_no}\t{m.word}\t{m.kana}\t{m.morae_file}\t{m.morae_calc}")

    if mismatch_tsv_style_samples:
        print("\nTSV-style mismatches (line_no\tword\tkana\tmorae_file\tmorae_calc_tsv):")
        for m in mismatch_tsv_style_samples:
            print(f"{m.line_no}\t{m.word}\t{m.kana}\t{m.morae_file}\t{m.morae_calc}")


if __name__ == "__main__":
    main()
