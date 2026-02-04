#!/usr/bin/env python3
"""Build a compact JSON trie from UniDic CSV sources.

Usage (run beside the `unidic-cwj-3.1.0` directory):
    python build_unidic_trie.py --src unidic-cwj-3.1.0 --out unidic_trie.json.gz

The resulting gzip'd JSON contains two arrays:
- "readings": list of unique hiragana readings.
- "nodes": each node has {"reading": int|None, "children": [["char", child_index], ...]}.

You can memory-map this data on the client and walk the trie entirely in Swift.
"""
from __future__ import annotations

import argparse
import csv
import gzip
import json
import pathlib
from dataclasses import dataclass, field
from typing import Dict, Iterable, List, Optional, Tuple


@dataclass
class TrieNode:
    children: Dict[str, int] = field(default_factory=dict)
    reading_index: Optional[int] = None


def to_hiragana(text: str) -> str:
    result_chars: List[str] = []
    for ch in text:
        # Katakana block
        if "ァ" <= ch <= "ヶ":
            result_chars.append(chr(ord(ch) - 0x60))
        else:
            result_chars.append(ch)
    return "".join(result_chars)


def load_entries(lex_path: pathlib.Path) -> Iterable[Tuple[str, str]]:
    with lex_path.open("r", encoding="utf-8", newline="") as fh:
        reader = csv.reader(fh)
        for row in reader:
            if not row:
                continue
            surface = row[0].strip()
            reading = row[7].strip() if len(row) > 7 else ""
            if not surface:
                continue
            if not any("\u4e00" <= c <= "\u9fff" or "\u3040" <= c <= "\u30ff" for c in surface):
                continue
            yield surface, to_hiragana(reading) if reading else ""


def build_trie(entries: Iterable[Tuple[str, str]]):
    nodes: List[TrieNode] = [TrieNode()]
    reading_to_index: Dict[str, int] = {}
    readings: List[str] = []

    def intern_reading(reading: str) -> Optional[int]:
        if not reading:
            return None
        idx = reading_to_index.get(reading)
        if idx is None:
            idx = len(readings)
            readings.append(reading)
            reading_to_index[reading] = idx
        return idx

    surfaces_seen: set[str] = set()
    for surface, reading in entries:
        if surface in surfaces_seen:
            continue
        surfaces_seen.add(surface)
        node_idx = 0
        for ch in surface:
            node = nodes[node_idx]
            next_idx = node.children.get(ch)
            if next_idx is None:
                next_idx = len(nodes)
                node.children[ch] = next_idx
                nodes.append(TrieNode())
            node_idx = next_idx
        nodes[node_idx].reading_index = intern_reading(reading)

    return nodes, readings


def serialize(nodes: List[TrieNode], readings: List[str], out_path: pathlib.Path) -> None:
    payload_nodes = []
    for node in nodes:
        payload_nodes.append(
            {
                "reading": node.reading_index,
                "children": sorted([[ch, idx] for ch, idx in node.children.items()], key=lambda item: item[0]),
            }
        )

    payload = {
        "format": "unidic-trie-v1",
        "readings": readings,
        "nodes": payload_nodes,
    }

    with gzip.open(out_path, "wt", encoding="utf-8") as gz:
        json.dump(payload, gz, ensure_ascii=False, separators=(",", ":"))


def main() -> None:
    parser = argparse.ArgumentParser(description="Build a compact trie JSON from UniDic CSV data.")
    parser.add_argument("--src", type=str, default="unidic-cwj-3.1.0", help="Path to the UniDic directory (default: %(default)s)")
    parser.add_argument("--lex", type=str, default=None, help="Name of the lexicon CSV inside --src (auto-detects lex*.csv if omitted)")
    parser.add_argument("--out", type=str, default="unidic_trie.json.gz", help="Output gzip'd JSON path (default: %(default)s)")
    args = parser.parse_args()

    src_dir = pathlib.Path(args.src)

    def resolve_lex_path() -> pathlib.Path:
        if args.lex:
            candidate = pathlib.Path(args.lex)
            if not candidate.is_absolute():
                candidate = src_dir / candidate
            if candidate.is_file():
                return candidate
            raise SystemExit(f"Could not find explicit lex file: {candidate}")

        preferred = ["lex.csv", "lex_3_1.csv", "lex-3.1.csv"]
        for name in preferred:
            candidate = src_dir / name
            if candidate.is_file():
                return candidate

        dynamic = sorted(src_dir.glob("lex*.csv"))
        if dynamic:
            return dynamic[0]
        raise SystemExit(f"Could not locate any lex*.csv inside {src_dir}")

    lex_path = resolve_lex_path()

    print(f"Reading entries from {lex_path}...")
    entries = list(load_entries(lex_path))
    print(f"Loaded {len(entries):,} entries")

    print("Building trie...")
    nodes, readings = build_trie(entries)
    print(f"Trie nodes: {len(nodes):,}; unique readings: {len(readings):,}")

    out_path = pathlib.Path(args.out)
    print(f"Writing {out_path}...")
    serialize(nodes, readings, out_path)
    print("Done.")


if __name__ == "__main__":
    main()
