#!/usr/bin/env python3

import argparse
import csv
import io
import re
import zipfile
from pathlib import Path


def find_lex_csv_path(zf: zipfile.ZipFile) -> str:
    candidates = [name for name in zf.namelist() if name.endswith("lex.csv")]
    if not candidates:
        raise FileNotFoundError("No lex.csv found inside UniDic archive")
    return candidates[0]


def parse_accent(value: str) -> int | None:
    if not value or value == "*":
        return None
    match = re.search(r"\d+", value)
    if not match:
        return None
    return int(match.group(0))


def sanitize_reading(value: str) -> str:
    if not value:
        return ""
    allowed = []
    for char in value:
        code = ord(char)
        is_hiragana = 0x3040 <= code <= 0x309F
        is_katakana = 0x30A0 <= code <= 0x30FF
        if is_hiragana or is_katakana or char == "ー":
            allowed.append(char)
    return "".join(allowed)


def count_mora(reading: str) -> int:
    if not reading:
        return 0
    non_mora_small = set("ャュョァィゥェォヮゃゅょぁぃぅぇぉゎゕゖヵヶ")
    mora = 0
    for char in reading:
        if char in non_mora_small:
            continue
        mora += 1
    return mora


def convert_unidic(
    unidic_zip: Path,
    output_tsv: Path,
    lex_csv_path: str | None,
    max_rows: int | None,
) -> tuple[int, int]:
    output_tsv.parent.mkdir(parents=True, exist_ok=True)

    emitted = 0
    skipped = 0
    seen: set[tuple[str, str, int, int, str]] = set()

    with zipfile.ZipFile(unidic_zip) as zf:
        target = lex_csv_path or find_lex_csv_path(zf)
        raw = zf.read(target).decode("utf-8", "replace")
        reader = csv.reader(io.StringIO(raw))

        with output_tsv.open("w", encoding="utf-8", newline="") as out:
            writer = csv.writer(out, delimiter="\t")
            writer.writerow(["id", "word", "kana", "kind", "accent", "morae"])

            row_id = 1
            for row in reader:
                if len(row) < 30:
                    skipped += 1
                    continue

                surface = row[0].strip()
                pos1 = row[4].strip()
                pos2 = row[5].strip()
                pron_base = row[15].strip()
                a_type_raw = row[27].strip()

                if not surface or pos1 in {"補助記号", "空白"}:
                    skipped += 1
                    continue

                accent = parse_accent(a_type_raw)
                if accent is None:
                    skipped += 1
                    continue

                kana = sanitize_reading(pron_base)
                if not kana:
                    skipped += 1
                    continue

                morae = count_mora(kana)
                if morae <= 0 or accent > morae:
                    skipped += 1
                    continue

                kind = pos2 if pos2 and pos2 != "*" else pos1

                key = (surface, kana, accent, morae, kind)
                if key in seen:
                    continue
                seen.add(key)

                writer.writerow([row_id, surface, kana, kind, accent, morae])
                row_id += 1
                emitted += 1

                if max_rows is not None and emitted >= max_rows:
                    break

    return emitted, skipped


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Convert UniDic kana-accent lex.csv into pitch_accent.tsv (id, word, kana, kind, accent, morae)",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--unidic-zip",
        required=True,
        help="Path to UniDic archive containing lex.csv (e.g. unidic-mecab_kana-accent-2.1.2_src.zip)",
    )
    parser.add_argument(
        "--lex-csv-path",
        default=None,
        help="Optional explicit path to lex.csv inside the zip",
    )
    parser.add_argument(
        "--output",
        default="data/pitch_accent.tsv",
        help="Output TSV path",
    )
    parser.add_argument(
        "--max-rows",
        type=int,
        default=None,
        help="Optional cap for emitted rows (debugging)",
    )

    args = parser.parse_args()

    unidic_zip = Path(args.unidic_zip).resolve()
    output_tsv = Path(args.output).resolve()

    if not unidic_zip.exists():
        raise FileNotFoundError(f"UniDic archive not found: {unidic_zip}")

    emitted, skipped = convert_unidic(
        unidic_zip=unidic_zip,
        output_tsv=output_tsv,
        lex_csv_path=args.lex_csv_path,
        max_rows=args.max_rows,
    )

    print(f"Wrote: {output_tsv}")
    print(f"Rows emitted: {emitted}")
    print(f"Rows skipped: {skipped}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
