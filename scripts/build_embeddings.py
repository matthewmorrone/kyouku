#!/usr/bin/env python3

import argparse
import struct
import sys
from array import array
from pathlib import Path


def load_keep_vocab(path: Path) -> list[str]:
    words: list[str] = []
    seen: set[str] = set()
    with path.open("r", encoding="utf-8") as f:
        for raw in f:
            word = raw.strip()
            if not word:
                continue
            if word in seen:
                continue
            seen.add(word)
            words.append(word)
    return words


def parse_vec_header(path: Path) -> tuple[int, int]:
    with path.open("r", encoding="utf-8", newline="") as f:
        header = f.readline().strip().split()
    if len(header) != 2:
        raise ValueError(f"Invalid fastText .vec header in {path}: expected '<n_words> <dim>'")
    try:
        n_words = int(header[0])
        dim = int(header[1])
    except ValueError as exc:
        raise ValueError(f"Invalid fastText .vec header values in {path}: {header}") from exc
    if n_words <= 0 or dim <= 0:
        raise ValueError(f"Invalid fastText .vec header in {path}: n_words={n_words} dim={dim}")
    return n_words, dim


def build_pruned_binary(
    vec_path: Path,
    keep_vocab_path: Path,
    output_path: Path,
    expected_dim: int | None,
) -> tuple[int, int, int]:
    keep_words = load_keep_vocab(keep_vocab_path)
    if not keep_words:
        raise ValueError(f"Keep vocab is empty: {keep_vocab_path}")

    keep_index = {word: idx for idx, word in enumerate(keep_words)}

    vec_n_words, vec_dim = parse_vec_header(vec_path)
    _ = vec_n_words

    if expected_dim is not None and vec_dim != expected_dim:
        raise ValueError(f"Dimension mismatch: vec={vec_dim} expected={expected_dim}")

    found: dict[str, bytes] = {}
    malformed = 0

    with vec_path.open("r", encoding="utf-8", newline="") as f:
        _ = f.readline()

        for line_no, raw in enumerate(f, start=2):
            row = raw.strip()
            if not row:
                continue

            parts = row.split()
            if len(parts) != vec_dim + 1:
                malformed += 1
                continue

            word = parts[0]
            if word not in keep_index:
                continue

            try:
                values = [float(x) for x in parts[1:]]
            except ValueError:
                malformed += 1
                continue

            vec = array("f", values)
            if sys.byteorder != "little":
                vec.byteswap()

            found[word] = vec.tobytes()

    missing = [word for word in keep_words if word not in found]

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("wb") as out:
        out.write(struct.pack("<II", len(keep_words), vec_dim))

        for word in keep_words:
            word_bytes = word.encode("utf-8")
            if len(word_bytes) > 0xFFFF:
                raise ValueError(f"Word too long for uint16 length field: {word[:64]}...")

            vec_bytes = found.get(word)
            if vec_bytes is None:
                vec_bytes = b"\x00" * (vec_dim * 4)

            out.write(struct.pack("<H", len(word_bytes)))
            out.write(word_bytes)
            out.write(vec_bytes)

    return len(keep_words), len(missing), malformed


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Build cc.ja.300.pruned.f32 from fastText .vec + keep-vocab list",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--vec-file",
        required=True,
        help="Path to fastText .vec file (e.g. cc.ja.300.vec)",
    )
    parser.add_argument(
        "--keep-vocab",
        required=True,
        help="Path to newline-delimited keep-vocab list (desired output order)",
    )
    parser.add_argument(
        "--output",
        default="data/cc.ja.300.pruned.f32",
        help="Output .f32 file path",
    )
    parser.add_argument(
        "--expected-dim",
        type=int,
        default=300,
        help="Expected embedding dimension (set 0 to disable check)",
    )

    args = parser.parse_args()

    vec_path = Path(args.vec_file).resolve()
    keep_vocab_path = Path(args.keep_vocab).resolve()
    output_path = Path(args.output).resolve()

    if not vec_path.exists():
        raise FileNotFoundError(f"Missing --vec-file: {vec_path}")
    if not keep_vocab_path.exists():
        raise FileNotFoundError(f"Missing --keep-vocab: {keep_vocab_path}")

    expected_dim = None if args.expected_dim == 0 else args.expected_dim

    written, missing, malformed = build_pruned_binary(
        vec_path=vec_path,
        keep_vocab_path=keep_vocab_path,
        output_path=output_path,
        expected_dim=expected_dim,
    )

    print(f"Wrote: {output_path}")
    print(f"Rows written: {written}")
    print(f"Missing vectors filled with zeros: {missing}")
    print(f"Malformed .vec rows skipped: {malformed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
