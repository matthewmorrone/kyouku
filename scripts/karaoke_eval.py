#!/usr/bin/env python3

import argparse
import json
import math
import statistics
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


@dataclass
class Unit:
    text: str
    start: float
    end: float
    confidence: Optional[float]


@dataclass
class Case:
    case_id: str
    locale_identifier: str
    audio_duration_seconds: float
    units: List[Unit]


@dataclass
class Point:
    confidence: float
    is_correct: float


@dataclass
class CaseResult:
    case_id: str
    locale_identifier: str
    unit_count: int
    matched_count: int
    boundary_mae_ms: float
    coverage: float
    boundary_jump_p95_ms: float


def clamp(value: float, lo: float, hi: float) -> float:
    return max(lo, min(value, hi))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Evaluate karaoke alignment predictions against gold fixtures."
    )
    parser.add_argument("--gold", required=True, type=Path, help="Path to gold JSON fixture")
    parser.add_argument("--pred", required=True, type=Path, help="Path to predicted JSON fixture")
    parser.add_argument(
        "--out-json",
        type=Path,
        help="Optional output path for metrics JSON report",
    )
    parser.add_argument(
        "--correct-threshold-ms",
        type=float,
        default=150.0,
        help="Boundary absolute error threshold for confidence calibration correctness",
    )
    parser.add_argument(
        "--coverage-confidence-threshold",
        type=float,
        default=0.15,
        help="Confidence threshold to count unit as anchored (non-fallback)",
    )
    parser.add_argument(
        "--ece-bins",
        type=int,
        default=10,
        help="Number of bins for ECE",
    )
    return parser.parse_args()


def load_json(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def parse_case(raw_case: Dict[str, Any]) -> Case:
    case_id = str(raw_case["id"])
    locale_identifier = str(raw_case.get("localeIdentifier", "unknown"))
    audio_duration_seconds = float(raw_case.get("audioDurationSeconds", 0.0))

    raw_units = raw_case.get("units", [])
    units: List[Unit] = []
    for raw_unit in raw_units:
        start = float(raw_unit["startSeconds"])
        end = float(raw_unit["endSeconds"])
        confidence = raw_unit.get("confidence")
        if confidence is not None:
            confidence = clamp(float(confidence), 0.0, 1.0)
        units.append(
            Unit(
                text=str(raw_unit.get("text", "")),
                start=max(0.0, start),
                end=max(start, end),
                confidence=confidence,
            )
        )

    return Case(
        case_id=case_id,
        locale_identifier=locale_identifier,
        audio_duration_seconds=max(0.0, audio_duration_seconds),
        units=units,
    )


def index_cases(payload: Dict[str, Any]) -> Dict[str, Case]:
    cases = payload.get("cases", [])
    indexed: Dict[str, Case] = {}
    for raw_case in cases:
        case = parse_case(raw_case)
        indexed[case.case_id] = case
    return indexed


def safe_median(values: List[float]) -> float:
    if not values:
        return 0.0
    return float(statistics.median(values))


def percentile(values: List[float], p: float) -> float:
    if not values:
        return 0.0
    sorted_values = sorted(values)
    if len(sorted_values) == 1:
        return sorted_values[0]
    rank = (len(sorted_values) - 1) * p
    lower = int(math.floor(rank))
    upper = int(math.ceil(rank))
    if lower == upper:
        return sorted_values[lower]
    weight = rank - lower
    return sorted_values[lower] * (1 - weight) + sorted_values[upper] * weight


def evaluate_case(
    gold_case: Case,
    pred_case: Case,
    correct_threshold_ms: float,
    coverage_confidence_threshold: float,
) -> Tuple[CaseResult, List[Point], List[float]]:
    count = min(len(gold_case.units), len(pred_case.units))
    if count == 0:
        return (
            CaseResult(
                case_id=gold_case.case_id,
                locale_identifier=gold_case.locale_identifier,
                unit_count=0,
                matched_count=0,
                boundary_mae_ms=0.0,
                coverage=0.0,
                boundary_jump_p95_ms=0.0,
            ),
            [],
            [],
        )

    abs_boundary_errors_ms: List[float] = []
    start_errors_ms: List[float] = []
    coverage_flags: List[float] = []
    points: List[Point] = []

    for index in range(count):
        gold = gold_case.units[index]
        pred = pred_case.units[index]

        start_err_ms = abs(pred.start - gold.start) * 1000.0
        end_err_ms = abs(pred.end - gold.end) * 1000.0
        mean_err_ms = (start_err_ms + end_err_ms) / 2.0

        abs_boundary_errors_ms.append(mean_err_ms)
        start_errors_ms.append(start_err_ms)

        confidence = pred.confidence if pred.confidence is not None else 0.0
        coverage_flags.append(1.0 if confidence >= coverage_confidence_threshold else 0.0)

        is_correct = 1.0 if (start_err_ms <= correct_threshold_ms and end_err_ms <= correct_threshold_ms) else 0.0
        points.append(Point(confidence=confidence, is_correct=is_correct))

    jump_errors_ms: List[float] = []
    if len(start_errors_ms) > 1:
        for index in range(1, len(start_errors_ms)):
            jump_errors_ms.append(abs(start_errors_ms[index] - start_errors_ms[index - 1]))

    result = CaseResult(
        case_id=gold_case.case_id,
        locale_identifier=gold_case.locale_identifier,
        unit_count=len(gold_case.units),
        matched_count=count,
        boundary_mae_ms=safe_median(abs_boundary_errors_ms),
        coverage=sum(coverage_flags) / float(len(coverage_flags)),
        boundary_jump_p95_ms=percentile(jump_errors_ms, 0.95),
    )

    return result, points, abs_boundary_errors_ms


def compute_brier(points: List[Point]) -> float:
    if not points:
        return 0.0
    total = 0.0
    for point in points:
        total += (point.confidence - point.is_correct) ** 2
    return total / float(len(points))


def compute_ece(points: List[Point], bins: int) -> float:
    if not points:
        return 0.0
    bins = max(1, bins)
    grouped: List[List[Point]] = [[] for _ in range(bins)]

    for point in points:
        bin_index = min(bins - 1, int(point.confidence * bins))
        grouped[bin_index].append(point)

    total = float(len(points))
    ece = 0.0
    for bucket in grouped:
        if not bucket:
            continue
        avg_conf = sum(p.confidence for p in bucket) / float(len(bucket))
        avg_acc = sum(p.is_correct for p in bucket) / float(len(bucket))
        ece += abs(avg_conf - avg_acc) * (len(bucket) / total)

    return ece


def locale_breakdown(results: List[CaseResult]) -> Dict[str, Dict[str, float]]:
    grouped: Dict[str, List[CaseResult]] = {}
    for result in results:
        grouped.setdefault(result.locale_identifier, []).append(result)

    output: Dict[str, Dict[str, float]] = {}
    for locale, items in grouped.items():
        output[locale] = {
            "cases": float(len(items)),
            "boundary_mae_ms_median": safe_median([x.boundary_mae_ms for x in items]),
            "coverage_mean": sum(x.coverage for x in items) / float(len(items)),
            "boundary_jump_p95_ms_median": safe_median([x.boundary_jump_p95_ms for x in items]),
        }
    return output


def print_summary(
    case_results: List[CaseResult],
    mae_values: List[float],
    points: List[Point],
    ece_bins: int,
) -> None:
    overall_mae = safe_median(mae_values)
    overall_coverage = (
        sum(case.coverage for case in case_results) / float(len(case_results))
        if case_results
        else 0.0
    )
    overall_jump_p95 = safe_median([case.boundary_jump_p95_ms for case in case_results])
    brier = compute_brier(points)
    ece = compute_ece(points, bins=ece_bins)

    print("Karaoke alignment evaluation summary")
    print("----------------------------------")
    print(f"Cases evaluated: {len(case_results)}")
    print(f"Boundary MAE (median): {overall_mae:.2f} ms")
    print(f"Coverage (mean): {overall_coverage * 100.0:.2f}%")
    print(f"Confidence calibration: Brier={brier:.4f}, ECE={ece:.4f}")
    print(f"Boundary jump p95 (median across cases): {overall_jump_p95:.2f} ms")

    print("\nPer-case")
    for case in case_results:
        print(
            f"- {case.case_id} [{case.locale_identifier}] "
            f"units={case.matched_count}/{case.unit_count} "
            f"mae={case.boundary_mae_ms:.2f}ms "
            f"coverage={case.coverage * 100.0:.2f}% "
            f"jump_p95={case.boundary_jump_p95_ms:.2f}ms"
        )


def main() -> None:
    args = parse_args()

    gold_cases = index_cases(load_json(args.gold))
    pred_cases = index_cases(load_json(args.pred))

    shared_case_ids = sorted(set(gold_cases.keys()) & set(pred_cases.keys()))
    if not shared_case_ids:
        raise SystemExit("No overlapping case ids between gold and prediction fixtures")

    case_results: List[CaseResult] = []
    calibration_points: List[Point] = []
    mae_values: List[float] = []

    for case_id in shared_case_ids:
        case_result, points, case_mae_values = evaluate_case(
            gold_cases[case_id],
            pred_cases[case_id],
            correct_threshold_ms=args.correct_threshold_ms,
            coverage_confidence_threshold=args.coverage_confidence_threshold,
        )
        case_results.append(case_result)
        calibration_points.extend(points)
        mae_values.extend(case_mae_values)

    print_summary(case_results, mae_values, calibration_points, ece_bins=args.ece_bins)

    if args.out_json is not None:
        payload = {
            "casesEvaluated": len(case_results),
            "boundaryMAEMedianMs": safe_median(mae_values),
            "coverageMean": (
                sum(case.coverage for case in case_results) / float(len(case_results))
                if case_results
                else 0.0
            ),
            "brier": compute_brier(calibration_points),
            "ece": compute_ece(calibration_points, bins=args.ece_bins),
            "boundaryJumpP95MedianMs": safe_median(
                [case.boundary_jump_p95_ms for case in case_results]
            ),
            "perLocale": locale_breakdown(case_results),
            "perCase": [
                {
                    "id": case.case_id,
                    "localeIdentifier": case.locale_identifier,
                    "unitCount": case.unit_count,
                    "matchedCount": case.matched_count,
                    "boundaryMAEMs": case.boundary_mae_ms,
                    "coverage": case.coverage,
                    "boundaryJumpP95Ms": case.boundary_jump_p95_ms,
                }
                for case in case_results
            ],
        }
        args.out_json.parent.mkdir(parents=True, exist_ok=True)
        with args.out_json.open("w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2)
            handle.write("\n")


if __name__ == "__main__":
    main()
