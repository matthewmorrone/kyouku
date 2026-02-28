# Karaoke Alignment Evaluation Harness

This harness provides offline benchmark metrics for karaoke alignment quality.

## Inputs
- Gold fixture: `data/karaoke_eval/gold.sample.json`
- Prediction fixture: `data/karaoke_eval/pred.sample.json`
- Schema: `data/karaoke_eval/README.md`

The evaluator pairs cases by `id` and compares units by index.

## Metrics
- Boundary MAE (ms): median of per-unit average absolute boundary error.
- Coverage (%): share of predicted units with confidence `>= 0.15` (proxy for non-fallback anchors).
- Confidence calibration:
  - Brier score
  - ECE (Expected Calibration Error)
- Boundary jump p95 (ms): p95 of adjacent start-error deltas (jitter proxy).

## Usage

```bash
python scripts/karaoke_eval.py \
  --gold data/karaoke_eval/gold.sample.json \
  --pred data/karaoke_eval/pred.sample.json
```

Optional JSON report:

```bash
python scripts/karaoke_eval.py \
  --gold data/karaoke_eval/gold.sample.json \
  --pred data/karaoke_eval/pred.sample.json \
  --out-json data/karaoke_eval/report.sample.json
```

## Notes
- This harness is intentionally offline and deterministic.
- It does not call ASR or app runtime code.
- Add new benchmark clips by appending to fixture files with unique `id` values.
