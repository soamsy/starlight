# Tier model

How the skill tray decides whether a cell is skill 1, 2 or 3, and how to retrain it.

## What it does

`SinColor.classify_cell/10` first picks the sin from hue windows, then builds the tier mask for that sin (`tier_raw_mask`). `TierModel` turns that mask into a tier:

- Features: `tier_pct`, `flame`, a one-hot of the detected sin, and the raw mask resized to 24x24 with `INTER_AREA` (576 values). 585 in total.
- Model: multiclass ridge regression on standardized features with one-hot tier targets, solved in closed form (`Evision.solve`, Cholesky), the same way the enemy target trainer does it.
- File: `priv/vision/tier_model.f32` holds the feature means, the standard deviations and a 586x3 weight matrix (bias row last) as native f32.
- Fallback: when the file is missing, `classify_cell` returns the hand-tuned threshold tier (`rule_tier`). The thresholds in `@tier_thresholds` and `@flame_thresholds` are still computed for every cell because `tier_pct` and `flame` are model inputs.

The old rule that made the bottom tier inherit from the top tier (and `next_best_tier`) is gone. The model gets bottom tiers right without it. Held out by hour, adding a pair constraint (same sin means same tier, different sin means different tier) made no difference (15 errors either way), so it was dropped.

## Retraining

```sh
mix tier_model.train --cv          # cross validation only
mix tier_model.train --cv --write  # also fit on every suite cell and write the model
```

Rows come from every `in_suite?` chain tray capture and its labels (truth file, or the recorded detection when unlabeled). `--cv` reports tier errors for the hand-tuned thresholds and for several lambdas, with the folds split by capture hour so near-duplicate frames never sit on both sides. Retrain after adding or relabeling suite captures, and after any change to the sin windows, the wedge, the tier colour mask or the background handling, since those change the features.

On the 51 captures (666 cells) in the suite on 2026-11-11: hand-tuned thresholds 69 raw tier errors (31 after the old inheritance rule); the model 15 held out by hour (lambda 500).

## What did not work

- A random forest on hue histograms for sin: 3 errors under leave-one-capture-out but 87 when held out by hour. The suite spans too few sessions and backgrounds.
- Edge-orientation (shape) features for sin: 148 errors. The frame outline is shared by every sin, so shape carries no sin identity.
- Gradient boosting and logistic regression on the same tier grid: within noise of ridge. Restricting the grid to the wedge was much worse (28 errors): the mask outside the wedge carries tier information.
- Binary hue windows on raw colours versus alpha unmixing for sin: unmixing (`fg = (pixel - (1 - a) * bg) / a`, a = 0.7, bg = median of the tray background strip) cut a hue-histogram classifier from about 55 held-out errors to about 10, which supports the semi-transparent tray model. It still did not beat the hand-tuned rules (8 errors on the suite), so it was not shipped.
- Moving the bottom row hue scan up (`@bottom_hue_scan_offset` 45 to 34) fixed most gluttony called gloom errors: the old window caught a cyan glow along the tray's lower edge.
