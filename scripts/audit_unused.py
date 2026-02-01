#!/usr/bin/env python3

import re
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
APP_DIR = REPO_ROOT / "kyouku"
TESTS_DIR = REPO_ROOT / "kyoukuTests"
DOCS_DIR = REPO_ROOT / "docs"


@dataclass(frozen=True)
class SwiftFileInfo:
    path: Path
    file_symbol: str
    declared_types: tuple[str, ...]
    extended_types: tuple[str, ...]
    declared_type_file_refs: tuple[tuple[str, int], ...]
    extended_type_file_refs: tuple[tuple[str, int], ...]
    total_other_type_decl_count: int


def _read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def _symbol_boundary_regex(symbol: str) -> re.Pattern:
    # Swift identifiers are ASCII-ish here; keep it simple and robust.
    # Avoid matching inside larger identifiers: Foo != FooBar.
    return re.compile(rf"(?<![A-Za-z0-9_]){re.escape(symbol)}(?![A-Za-z0-9_])")


def _count_type_decls(text: str) -> int:
    # Rough heuristic: counts top-level type declarations.
    # This isn't a parser; it just helps identify multi-type files.
    return len(re.findall(r"\b(struct|class|enum|actor|protocol)\s+[A-Za-z_][A-Za-z0-9_]*\b", text))


_TYPE_DECL_RX = re.compile(r"\b(struct|class|enum|actor|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)\b")
_EXT_RX = re.compile(r"\bextension\s+([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\b")


def _declared_type_names(text: str) -> list[str]:
    return sorted({m.group(2) for m in _TYPE_DECL_RX.finditer(text)})


def _extended_type_names(text: str) -> list[str]:
    out: set[str] = set()
    for m in _EXT_RX.finditer(text):
        raw = m.group(1)
        base = raw.split(".")[-1]
        if base:
            out.add(base)
    return sorted(out)


def _count_files_referencing_symbol(symbol: str, texts: dict[Path, str], exclude: Path) -> int:
    rx = _symbol_boundary_regex(symbol)
    count = 0
    for other_path, other_text in texts.items():
        if other_path == exclude:
            continue
        if rx.search(other_text):
            count += 1
    return count


def audit_swift_symbol_usage(swift_paths: list[Path]) -> list[SwiftFileInfo]:
    texts: dict[Path, str] = {p: _read_text(p) for p in swift_paths}

    results: list[SwiftFileInfo] = []
    for path, text in texts.items():
        file_symbol = path.stem

        declared = _declared_type_names(text)
        extended = [x for x in _extended_type_names(text) if x not in declared]

        declared_type_file_refs = tuple(
            (t, _count_files_referencing_symbol(t, texts, exclude=path)) for t in declared
        )
        extended_type_file_refs = tuple(
            (t, _count_files_referencing_symbol(t, texts, exclude=path)) for t in extended
        )

        total_other_type_decl_count = _count_type_decls(text)

        results.append(
            SwiftFileInfo(
                path=path,
                file_symbol=file_symbol,
                declared_types=tuple(declared),
                extended_types=tuple(extended),
                declared_type_file_refs=declared_type_file_refs,
                extended_type_file_refs=extended_type_file_refs,
                total_other_type_decl_count=total_other_type_decl_count,
            )
        )

    def sort_key(x: SwiftFileInfo) -> tuple[int, str]:
        declared_sum = sum(c for _, c in x.declared_type_file_refs)
        extended_sum = sum(c for _, c in x.extended_type_file_refs)
        return (declared_sum + extended_sum, x.path.as_posix())

    return sorted(results, key=sort_key)


def audit_resource_references(resource_paths: list[Path], swift_paths: list[Path]) -> list[tuple[Path, int]]:
    swift_texts = [_read_text(p) for p in swift_paths]
    results: list[tuple[Path, int]] = []
    for r in resource_paths:
        # Resources are usually referenced via string literals.
        # Count files that contain either the full filename literal (rare) or the resource-name literal.
        # Example: Bundle.url(forResource: "deinflect.min", withExtension: "json")
        filename_lit = re.compile(re.escape(f'"{r.name}"'))
        resource_name_lit = re.compile(re.escape(f'"{r.stem}"'))

        filename_lit_files = 0
        resource_name_lit_files = 0
        for t in swift_texts:
            if filename_lit.search(t):
                filename_lit_files += 1
            if resource_name_lit.search(t):
                resource_name_lit_files += 1

        # Return a combined score for sorting, but keep the detail in the report.
        results.append((r, (filename_lit_files << 16) | resource_name_lit_files))
    return sorted(results, key=lambda x: (x[1], x[0].as_posix()))


def main() -> int:
    swift_app = sorted(APP_DIR.rglob("*.swift"))
    swift_tests = sorted(TESTS_DIR.rglob("*.swift")) if TESTS_DIR.exists() else []

    swift_infos = audit_swift_symbol_usage(swift_app)

    # Resources in app root (JSON/SQLite). Extend as needed.
    resources = []
    for ext in ("*.json", "*.sqlite3"):
        resources.extend(APP_DIR.glob(ext))
    resource_refs = audit_resource_references(sorted(resources), swift_app)

    DOCS_DIR.mkdir(parents=True, exist_ok=True)
    out_path = DOCS_DIR / "DeadCodeAudit.md"

    lines: list[str] = []
    lines.append("# Dead/Unused Code Audit (Heuristic)\n")
    lines.append("This is a best-effort static audit (not a Swift parser). Treat results as **candidates for manual review**, not safe deletions.\n")
    lines.append("## Scope\n")
    lines.append(f"- App Swift files: {len(swift_app)}")
    lines.append(f"- Test Swift files: {len(swift_tests)}\n")

    # 1) Candidate files where *no declared type* is referenced elsewhere.
    lines.append("## Candidates: no declared type referenced elsewhere\n")
    candidates: list[SwiftFileInfo] = []
    for i in swift_infos:
        # App entrypoints are referenced by build configuration, not by symbol name.
        text = _read_text(i.path)
        if "@main" in text:
            continue
        if i.declared_types:
            if all(c == 0 for _, c in i.declared_type_file_refs):
                candidates.append(i)

    if not candidates:
        lines.append("- None found by this heuristic.\n")
    else:
        for i in candidates:
            rel = i.path.relative_to(REPO_ROOT).as_posix()
            decls = ", ".join([f"{t}:{c}" for t, c in i.declared_type_file_refs])
            notes = []
            if i.total_other_type_decl_count > len(i.declared_types):
                notes.append(f"multi-type file (decls≈{i.total_other_type_decl_count})")
            note_str = f" ({'; '.join(notes)})" if notes else ""
            lines.append(f"- {rel}{note_str} — declared: {decls}")
        lines.append("")

    # 2) Candidate extension-only files where extended type names aren't referenced elsewhere.
    lines.append("## Candidates: extension-only file (extended types never referenced elsewhere)\n")
    ext_only: list[SwiftFileInfo] = []
    for i in swift_infos:
        if not i.declared_types and i.extended_types:
            if all(c == 0 for _, c in i.extended_type_file_refs):
                ext_only.append(i)

    if not ext_only:
        lines.append("- None found by this heuristic.\n")
    else:
        for i in ext_only:
            rel = i.path.relative_to(REPO_ROOT).as_posix()
            exts = ", ".join([f"{t}:{c}" for t, c in i.extended_type_file_refs])
            lines.append(f"- {rel} — extends: {exts}")
        lines.append("")

    # 3) Low-reference declared types (declared types referenced in exactly 1 other file)
    lines.append("## Candidates: declared types referenced in exactly 1 other file\n")
    low: list[tuple[str, str, int]] = []
    for i in swift_infos:
        for t, c in i.declared_type_file_refs:
            if c == 1:
                low.append((i.path.relative_to(REPO_ROOT).as_posix(), t, c))
    if not low:
        lines.append("- None found by this heuristic.\n")
    else:
        for rel, t, c in sorted(low):
            lines.append(f"- {rel}: {t} ({c})")
        lines.append("")

    # 4) Resource usage
    lines.append("## Bundled resources: referenced via string literals\n")
    if not resource_refs:
        lines.append("- No app-root `*.json`/`*.sqlite3` resources found.\n")
    else:
        for r, packed in resource_refs:
            filename_lit_files = (packed >> 16) & 0xFFFF
            resource_name_lit_files = packed & 0xFFFF
            rel = r.relative_to(REPO_ROOT).as_posix()
            lines.append(
                f"- {rel}: filename literal in {filename_lit_files} file(s); resource-name literal \"{r.stem}\" in {resource_name_lit_files} file(s)"
            )
        lines.append("")

    # 4) Notes / next steps
    lines.append("## Next steps (recommended)\n")
    lines.append("- For higher confidence, run a dedicated unused-code tool like Periphery against the Xcode project (it understands Swift better than regex heuristics).")
    lines.append("- Before deleting any Swift file, confirm it is not referenced via SwiftUI view construction, environment injection, reflection, string-based lookups, or previews.")

    out_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    print(f"Wrote {out_path.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
