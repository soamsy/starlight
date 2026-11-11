# Enemy targeting

How the bot finds the thing to drop a skill on during a battle turn, why it works the way it does now, and how to retrain it.

## What we are aiming at

When you drag a skill over the enemy side, each enemy shows a septagon skill icon. Dropping on that icon starts the clash. Those septagons are the targets, and the boxes in the battle history test suite are drawn around them. The enemy body and the crosshair reticle on it are not targets.

`EnemyTargets.find/1` takes a full 1920x1080 frame and returns one `%EnemyTargets{}` per septagon, sorted left to right. `point` is the septagon centre, which is where the cursor goes. `icon` equals `point`, and `zone` is `nil`. The struct kept its shape so `BattlePlans.apply_ignores/2`, the aim loop in `playbook_runner.ex` and the inspector overlays did not have to change.

## Why the old pipeline failed

The previous version never looked for the septagon. It looked for small things near it: a white badge icon above, a red or brown rim fragment, eight sin-coloured backup hooks. It combined them with about twenty tuned constants (reservation zones, dedupe radii, 0.4 and 0.75 point ratios).

I ran the 8 labeled enemy captures that were in the suite at the time. Six failed. The causes:

- **Impostors from fixed places.** The skill banner at the top centre (roughly x 700 to 940, y 140 to 250) caused false targets in four captures. An ally's status clutter at the left edge of the search region (x 506 to 530) caused two more. The crop now starts at x 546 for the same reason; the labeled septagon centres span x 589 to 1360.
- **Lost anchors.** In three captures an arrow or the banner covered the badge. The septagon itself was fully visible, but the detector found the badge first and only then guessed where the septagon was.
- **No badge at all.** The 14-28 captures have no badges, so only the colour fallbacks fired, and they covered half the septagons.

Identity was also fragile. `pick_enemy` takes the Nth target by x position, so one missed or extra detection shifts every index and the bot targets the wrong enemy without any error.

## What did not work

These are worth knowing so nobody retries them.

- **Reticle detection.** The orange crosshair marks bodies, not targets. It says nothing about how high to aim, and arrows and effects fly over it.
- **Name or HP as identity.** Rejected by design.
- **Rim colour.** A brick-red ring matched with a colour map and a center-surround kernel got 9 of 15 captures perfect. The red band shrinks and disappears as the enemy loses HP, and some septagons have a bright orange rim, a dim rim, or a cyan glow. Colour is not stable across those states.
- **Edge-orientation matching.** Chamfer-style matching of the outline, with and without polarity and a second inner outline, had no usable operating point. Tight tolerance missed most targets and loose tolerance fired on foliage and text.
- **`Evision.ML.SVMSGD`.** It separated the training set perfectly in every configuration, but its scores landed on an unpredictable scale and it generalised badly.

## How it works now

A sliding-window classifier over HOG features.

1. Crop the region `{546, 112, 1180, 660}` and convert to grayscale.
2. Resize to seven scales (1.15, 1.0, 0.85, 0.76, 0.69, 0.63, 0.55) so septagons of width 50 to 105 px land near the 64 px window.
3. Run OpenCV's `HOGDescriptor` (window 64, block 16, block stride 8, cell 8, 9 bins, 1764 values per window) with a linear detector set on it, at stride 8 and a hit threshold of 0.4.
4. Map window centres back to frame coordinates and drop any candidate within 45 px of a stronger one.

The model is a single weight vector plus a bias, 1765 float32 values (7060 bytes) in `priv/vision/enemy_targets_hog.f32`. It is read once and cached in `:persistent_term`. A frame takes about 50 ms.

`StarlightBot.Vision.EnemyTargets` holds the detector. `StarlightBot.Vision.EnemyTargets.Trainer` builds the model, and `mix enemy_targets.train` drives it.

## Training

The training data is the labeled `focused_enemies` captures marked as in-suite in the battle history UI. Each truth box gives positives and every other window gives negatives.

- **Positives.** For each box, the nearest scale and its two neighbours, shifted by -4, 0 and +4 px in each direction. Positive samples carry weight 8.
- **Random negatives.** 300 windows per scale per capture, at least 38 px from any truth centre.
- **Hard negatives.** Two mining rounds. After each fit, windows scoring above -0.3 away from any truth box are added (up to 150 per scale per capture) and the model is refit.
- **Solver.** Ridge regression on labels of +1 and -1, lambda 0.3, solved in closed form from `XᵀX` and `Xᵀy` with `gemm` and a Cholesky solve. Those sums are computed once per capture and added together, so cross-validation folds and mining rounds only pay for the new rows.

## Accuracy

Five-fold cross-validation grouped by capture, so the model never sees the capture it is scored on. 32 captures, 156 targets, lambda 0.3.

| Threshold | Captures perfect | Missed | Extra |
|---|---|---|---|
| 0.1 | 21 of 32 | 0 | 14 |
| 0.2 | 27 of 32 | 2 | 4 |
| 0.3 | 28 of 32 | 2 | 3 |
| 0.4 | 31 of 32 | 2 | 0 |
| 0.5 | 29 of 32 | 6 | 0 |
| 0.6 | 28 of 32 | 8 | 0 |
| 0.8 | 16 of 32 | 27 | 0 |

The default threshold is 0.4, the best row. It is a narrow peak, not a plateau. The one capture that still fails is a 6-enemy frame where drag arrows cross several septagons. Lambda from 0.1 to 3.0 changes nothing material. The model that ships is trained on all 32 captures, so its bulk-suite score is optimistic. Judge changes by the cross-validated numbers.

Thirty-two captures is still a small sample, and I chose the threshold after seeing these results.

## Retraining

Capture frames in the battle history UI (they land outside the suite), review and fix the boxes, then add them to the suite. Then:

```sh
mix enemy_targets.train --cv            # cross-validated table, writes nothing
mix enemy_targets.train --write         # retrain on the whole suite, rewrite the model
mix enemy_targets.train --cv --write    # both
mix enemy_targets.train --cv --lambda 1.0
```

A running `mix phx.server` holds the `_build/dev` lock, so run the task with `MIX_BUILD_PATH` pointing at a copy of `_build/dev`, the same trick `AGENTS.md` describes for compiling. A running server keeps the old model in `:persistent_term` until it restarts or someone calls `EnemyTargets.reload_detector/0`.

Commit the regenerated `priv/vision/enemy_targets_hog.f32` with the captures' effect described in the commit message. It is a binary, so the diff will not show what changed.

Captures that would help the most: low-HP septagons with no red rim, fights with only 3 or 4 enemies (larger septagons, and there are few examples), dim or glowing scenes like the 14-28 ones, and frames where the drag arrow sits on a septagon.

## Things to know

- `Evision.HOGDescriptor.hogDescriptor/1` ignores its options. The generated function's first clause matches any keyword list and forwards underscore-prefixed names that the NIF does not read, so the working second clause is never reached. `new_hog/0` calls `:evision_nif.hogDescriptor_HOGDescriptor/1` directly. Check this again after an Evision upgrade.
- `playbook_runner.ex` `creep/3` stops when `y - step < icon_y`. With `icon == point` that is always true, so creeping is now a no-op. It does no harm and I left it.
- `zone` is `nil`, so the inspector no longer draws the blue "reserved" boxes.
- The `enemy_target_part_icon_*` hooks in `base.db` are no longer read by targeting. They are still in the table.
- `hitThreshold` is applied inside OpenCV against the detector's bias term, so scores are on the ridge scale (negatives near -1, positives near +1), not an SVM margin.

## Not verified

I have not run the new detector in a live battle. All the numbers above come from saved captures. The hover check in `aim/5` still confirms that some enemy highlighted near the point, not that it was the intended one.

One idea for a hover signal that does not depend on the top-right portrait: when the cursor is on a target, a second skill banner (the enemy's) appears next to the player's own banner at the top centre. Earlier frames show only one. It is untested.
