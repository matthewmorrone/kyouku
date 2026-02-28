#!/usr/bin/env python3

import argparse
from pathlib import Path


def parse_int(value: str) -> int | None:
    try:
        return int(value)
    except ValueError:
        return None


def parse_line(parts: list[str], single_format: str | None) -> tuple[int, str, int, str] | None:
    if len(parts) >= 4:
        jp_id = parse_int(parts[0].strip())
        en_id = parse_int(parts[2].strip())
        if jp_id is None or en_id is None:
            return None
        return jp_id, parts[1], en_id, parts[3]

    if len(parts) >= 3 and single_format:
        id_a = parse_int(parts[0].strip())
        id_b = parse_int(parts[1].strip())
        if id_a is None or id_b is None:
            return None

        text = parts[2]
        if single_format == "jp-en":
            return id_a, text, id_b, ""
        return id_b, "", id_a, text

    return None


def ingest_file(path: Path, single_format: str | None) -> list[tuple[int, str, int, str]]:
    rows: list[tuple[int, str, int, str]] = []
    with path.open("r", encoding="utf-8-sig", newline="") as file_obj:
        for raw in file_obj:
            line = raw.rstrip("\r\n")
            if not line:
                continue
            parts = line.split("\t")
            parsed = parse_line(parts, single_format)
            if parsed is None:
                continue
            rows.append(parsed)
    return rows


def build_pairs(
    canonical_input: Path | None,
    jp_en_input: Path | None,
    en_jp_input: Path | None,
    output_path: Path,
):
    merged: dict[tuple[int, int], tuple[str, str]] = {}

    if canonical_input:
        for jp_id, jp_text, en_id, en_text in ingest_file(canonical_input, None):
            merged[(jp_id, en_id)] = (jp_text, en_text)

    if jp_en_input:
        for jp_id, jp_text, en_id, _ in ingest_file(jp_en_input, "jp-en"):
            old = merged.get((jp_id, en_id), ("", ""))
            merged[(jp_id, en_id)] = (jp_text or old[0], old[1])

    if en_jp_input:
        for jp_id, _, en_id, en_text in ingest_file(en_jp_input, "en-jp"):
            old = merged.get((jp_id, en_id), ("", ""))
            merged[(jp_id, en_id)] = (old[0], en_text or old[1])

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8", newline="") as out:
        for (jp_id, en_id), (jp_text, en_text) in merged.items():
            if not jp_text or not en_text:
                continue
            out.write(f"{jp_id}\t{jp_text}\t{en_id}\t{en_text}\n")

    print(f"Wrote: {output_path}")
    print(f"Pairs: {len(merged)}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Build canonical sentence-pairs.tsv (jp_id<TAB>jp_text<TAB>en_id<TAB>en_text)",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--canonical-input", default=None, help="Existing canonical 4-column TSV")
    parser.add_argument("--jp-en-input", default=None, help="3-column JP->EN export: jp_id<TAB>en_id<TAB>jp_text")
    parser.add_argument("--en-jp-input", default=None, help="3-column EN->JP export: en_id<TAB>jp_id<TAB>en_text")
    parser.add_argument("--output", default="data/sentence-pairs.tsv")

    args = parser.parse_args()

    canonical_input = Path(args.canonical_input).resolve() if args.canonical_input else None
    jp_en_input = Path(args.jp_en_input).resolve() if args.jp_en_input else None
    en_jp_input = Path(args.en_jp_input).resolve() if args.en_jp_input else None
    output = Path(args.output).resolve()

    if not canonical_input and not jp_en_input and not en_jp_input:
        raise ValueError("Provide at least one input via --canonical-input and/or --jp-en-input/--en-jp-input")

    for candidate in [canonical_input, jp_en_input, en_jp_input]:
        if candidate and not candidate.exists():
            raise FileNotFoundError(f"Input not found: {candidate}")

    build_pairs(canonical_input, jp_en_input, en_jp_input, output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
