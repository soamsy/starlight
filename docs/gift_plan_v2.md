# Gift Plan v2: Workflows

Replaces the weight-driven gift plan with explicit, user-ordered shop workflows. The shop runner executes steps top to bottom, once each, and never decides priority on its own.

## Concepts

- **Gift plan**: one row in `gift_plans` (unchanged table, `data` JSON bumped to `version: 2`). Holds plan-global settings, a library of definitions, workflows, and a floor schedule.
- **Library definition**: a reusable, named piece of config (one uptie target, one fusion target with its route tree, shopping lists, keep lists). Shared by every workflow in the plan. Editing one changes everything that references it.
- **Step**: one entry in a workflow. Either references a library definition by id, or carries its own small inline params (refresh, sell, budget, etc.). Every step has an optional condition tree.
- **Workflow**: a named, ordered list of steps plus exactly one keep list.
- **Floor schedule**: maps floor ranges to workflows, same `from_floor` pattern as `pack_plans.mode_schedule` (`PackPlans.Resolver.mode_for_floor/2`).

Rule for where config lives: if it's a list the user curates and ranks, or a single target with nontrivial config, it goes in a library tab. If it's a few scalars, it's inline on the step. Uptie and tiered fusion steps hold an ordered list of library refs, so the order of work lives on the step and each definition stays about one gift.

| Action | Where defined | Step params |
|---|---|---|
| Uptie | Library: Upties | ordered `upties` refs, `max_gifts` |
| Tiered Fusion | Library: Tiered Fusions | ordered `fusions` refs |
| Buy from list | Library: Shopping Lists | `list` ref, `max_items` |
| Fixed Fusion | Inline | `target`, `buy_missing` |
| Refresh | Inline | none |
| Affinity Refresh | Inline | `affinity` (defaults to plan affinity) |
| Sell | Inline | ordered `tiers`, `stop_at_cost`, `max_items` |
| Skill Replace | Inline | `sinner`, ordered `options` |
| Heal Sinner | Inline | `sinner` |
| Heal All | Inline | none |
| Revive | Inline | `sinner` |
| Budget | Inline | `amount` (may be negative) |

Reference data with no step:
- **Keep lists** (library). Each workflow picks one. Floor 1 and floors 2+ can share a list or use different ones.
- **Grace** picks and plan **affinity**: plan-global, not part of any workflow. Affinity is still read by `Teams.decode_affinity/1` and `MirrorDungeonRunner`.

## Schema (`data`, version 2)

```json
{
  "version": 2,
  "affinity": "burn",
  "grace_picks": [{"index": 7, "enhance": 0}],

  "library": {
    "keep_lists": [
      {"id": "kp_1", "name": "Burn core", "gifts": ["Fiery Down", "Hellterfly’s Dream", "Glimpse of Flames"]}
    ],
    "upties": [
      {"id": "up_1", "name": "Glimpse +2", "gift": "Glimpse of Flames", "target_level": 2},
      {"id": "up_2", "name": "Hellterfly +2", "gift": "Hellterfly’s Dream", "target_level": 2}
    ],
    "tiered_fusions": [
      {"id": "tf_1", "name": "Glimpse", "target": "Glimpse of Flames",
       "routes": [
         {"id": "rt_1", "combo": [3, 3, 2], "buy_up_to": 3, "leftover": {},
          "subgoals": {"3": [
            {"id": "rt_2", "combo": [2, 2, 2], "buy_up_to": null, "leftover": {"2": 1}, "subgoals": {}}
          ]}},
         {"id": "rt_3", "combo": [4, 2, 2], "buy_up_to": null, "leftover": {}, "subgoals": {}}
       ]},
      {"id": "tf_2", "name": "Hellterfly", "target": "Hellterfly’s Dream", "routes": []}
    ],
    "shopping_lists": [
      {"id": "sl_1", "name": "Burn T2 fodder", "gifts": ["Fiery Down", "Hellterfly’s Dream"]}
    ]
  },

  "workflows": [
    {"id": "wf_1", "name": "Standard", "keep": "kp_1", "steps": [
      {"id": "st_1", "kind": "budget", "amount": 300,
       "condition": {"op": "missing_gift", "gift": "Glimpse of Flames"}},
      {"id": "st_2", "kind": "buy_list", "list": "sl_1", "max_items": 2},
      {"id": "st_3", "kind": "refresh", "condition": {"op": "cost_gte", "value": 250}},
      {"id": "st_4", "kind": "buy_list", "list": "sl_1", "max_items": 2},
      {"id": "st_5", "kind": "budget", "amount": -300,
       "condition": {"op": "missing_gift", "gift": "Glimpse of Flames"}},
      {"id": "st_6", "kind": "tiered_fusion", "fusions": ["tf_1", "tf_2"]},
      {"id": "st_7", "kind": "fixed_fusion", "target": "Wholeness", "buy_missing": true},
      {"id": "st_8", "kind": "affinity_refresh", "affinity": "burn",
       "condition": {"op": "and", "children": [
         {"op": "cost_gte", "value": 300},
         {"op": "or", "children": [
           {"op": "missing_gift", "gift": "Fiery Down"},
           {"op": "missing_gift", "gift": "Hellterfly’s Dream"}
         ]}
       ]}},
      {"id": "st_9", "kind": "sell", "tiers": [1, 2], "stop_at_cost": 400, "max_items": 2},
      {"id": "st_10", "kind": "skill_replace", "sinner": "yisang", "options": ["s1_s3", "s1_s2"]},
      {"id": "st_11", "kind": "uptie", "upties": ["up_1", "up_2"], "max_gifts": 1,
       "condition": {"op": "cost_gte", "value": 180}, "enabled": false},
      {"id": "st_12", "kind": "tiered_fusion", "fusions": ["tf_1", "tf_2"]}
    ]}
  ],

  "floor_schedule": [
    {"from_floor": 1, "workflow": "wf_2"},
    {"from_floor": 2, "workflow": "wf_1"}
  ]
}
```

Every step accepts `enabled` (default true) so a step can be parked without deleting it, and `condition` (default null, meaning always run). Ids are short random strings generated by the editor; steps and workflows reference library ids, never names.

### Conditions

An optional tree evaluated once, right before the step runs. False means the step is logged as `:skipped` and the runner moves on.

| Node | Shape | True when |
|---|---|---|
| And | `{"op": "and", "children": [...]}` | every child is true |
| Or | `{"op": "or", "children": [...]}` | any child is true |
| Cost | `{"op": "cost_gte", "value": 200}` | `wallet >= value` |
| Owned | `{"op": "has_gift", "gift": "Fiery Down"}` | gift is in the inventory |
| Not owned | `{"op": "missing_gift", "gift": "Glimpse of Flames"}` | gift is not in the inventory |

Inventory is `RunMemory.ego_gifts`, as updated by the entry scan and every buy, fuse, and sell so far in this shop. A condition is permission to try, not a guarantee: a step that passes its condition and then can't afford something fails at runtime, same as a network timeout would.

Actions keep their own built-in early exits (tiered fusion stops when the target is owned, sell stops at `stop_at_cost`). Conditions are for everything else, mostly budget and refreshes.

### Cost, reserve, wallet

- `cost` = last detected in-game cost.
- `reserve` starts at 0 on every shop entry. Each budget step adds `amount` to it (negative subtracts). Leaving the shop discards it.
- `wallet` = `cost - reserve`. Used by every `cost_gte` leaf and by sell's `stop_at_cost`.
- The wallet never caps what an action spends. It only feeds conditions.

### Field semantics

**Uptie**: an uptie definition is one `gift` and a `target_level` (+1 or +2). The step walks its `upties` list in order:
- Skip a definition whose gift isn't owned or is already at `target_level`.
- Otherwise, if current cost covers the full price from the gift's current level to `target_level`, uptie it all the way. Price comes from tier + current level (`docs/uptie.md`) and is shown in the editor as an estimate.
- If current cost can't cover the full price, stop the whole step. Never uptie partway: affording +1 when the definition wants +2 counts as running out of cost, and the step does not move on to cheaper definitions further down the list.
- Stop after `max_gifts` gifts were upgraded.

There is no fallback level. A +1 definition further down the same list won't help, because the step stops at the +2 it couldn't pay for. To settle for +1 when +2 is out of reach, add a separate uptie step after this one whose list holds a +1 definition for that gift.

**Tiered Fusion step**: holds an ordered `fusions` list. Each run works on exactly one fusion: the first in the list whose `target` isn't owned. Later fusions are not evaluated, bought for, or fused toward until every earlier target is owned. When the current fusion completes, the step returns `:done` without starting the next one. The intended pattern is to put the same tiered fusion step (same list) at several points in the workflow, so each occurrence picks up where the last left off and the whole list eventually completes.

This replaces protecting partial buys. Ingredients bought toward fusion 1 can't be eaten by fusion 2, because fusion 2 doesn't run until fusion 1 is done. Every target in the list is still in the protected set (below), so finished targets aren't sold or used as fodder.

**Tiered Fusion definition**: `target` must be a T2 to T4 gift with no fixed ingredients. `routes` is an ordered list of things the fuser tries. Each route is a combo picked from the valid pool for its tier, plus customizations:
- `buy_up_to`: max tier the route will buy from the shelf to fill missing ingredients or leftovers. `null` = never buy.
- `leftover`: map of tier → count of unprotected items that must still be owned after this fusion consumes its ingredients. `{"2": 1}` on a 2+2+2 means "only fuse with 4 spare T2s". Buying counts toward leftovers too.
- `subgoals`: map of ingredient tier → its own route list, with the same customizations, nested as deep as needed. An empty or missing list means "don't fuse for that tier".
- Combos may repeat; a route can be a duplicate of an earlier one with different customizations. Duplicating copies the whole subtree.
- Combos not listed anywhere are never tried. Normal and super shops share the same tree; the runner skips routes whose combo doesn't work in the current shop (below).
- Fodder = owned gifts minus the workflow's protected set. Owned T4s count as fodder unless protected, which covers the T4 + T2 + T2 case.
- Done = `target` is owned.

**Buying for tiered fusion routes.** `buy_up_to` doesn't require that the whole combo can be bought this visit. If a shelf item fills a need of a route that's still reachable, buy it, even if the other ingredients aren't in sight yet. Before a route is allowed to buy anything, it has to pass a reachability check:

- A route is reachable if every ingredient tier it needs, plus every `leftover` tier, can be covered by at least one of:
  1. owned fodder of that tier;
  2. buying, because the tier is `<= buy_up_to`;
  3. a sub-goal list for that tier containing at least one reachable route, checked recursively with the same rules.
- If a needed tier fails all three, the route can only progress once that ingredient is already in hand. Example: `buy_up_to` 3, the combo needs a T4, no unprotected T4 is owned, and there's no T4 sub-goal. That route is skipped entirely: no buying, no sub-goal work. This keeps the runner from sinking cost into half a combo it can never finish. It's on the user to define routes that can actually be completed. The check only rules out the impossible.
- If future refreshes and buys could plausibly cover everything, the route is reachable, and the runner buys anything on the shelf that fits it. The risk of only getting halfway is accepted as part of how the route was defined.
- Combos that only work in a super shop are never invested in during a normal shop, including buying toward them and working their sub-goals. They're treated as unreachable in a normal shop, because no fusion can complete them before leaving.
- Routes are evaluated in order, and every reachable route with `buy_up_to` gets its buy pass. So route 1 and route 2 can both pick up pieces in the same visit. The reachability check is what makes that acceptable.
- Within a buy pass, scan the shelf highest tier first: T4, then T3, T2, T1. Higher tiers are rarer, and one higher-tier piece can stand in for a whole sub-goal fusion.

None of this needs new schema. It's runner behavior, implemented when tiered fusion gets automated.

**Fixed Fusion**: `target` must have `ego_gifts.ingredients`. Buy missing ingredients from the shelf if `buy_missing`, fuse if all present, else fail. Done (skipped) if the target is already owned.

**Buy from list**: buy up to `max_items` shelf gifts that appear in the list, in list order. A list entry can also be "Any T1" to "Any T4" (stored as `tier:N`), which matches every shelf gift of that tier at that position in the order. Gifts already owned are skipped. A shopping list can set `done_at`: once that many owned gifts match the list (Any-tier entries count every owned gift of that tier), buy steps on it skip as done, and until then a step buys at most the difference, even when `max_items` is higher.

**Sell**: `tiers` is an ordered multi-select. Sell unprotected gifts from the first tier in the list, then the next, until `wallet >= stop_at_cost` or `max_items` sold. Skips entirely if `wallet` already meets `stop_at_cost`. The gifts to sell are chosen up front from the entry inventory scan; within a tier, the highest `ego_gifts.selling_cost` goes first, so fewer gifts are sold to reach `stop_at_cost`. Uptie level doesn't change sell price, so the whole sale is planned from known prices: take gifts in that order until their prices cover `stop_at_cost - wallet` (capped at `max_items`), then sell them all in one popup session without re-reading cost between sales. For each gift, check the current view first, then scroll to the top and scan down. When the first non-budget step of the workflow is a sell, the entry inventory scan leaves the sell popup open for it; any other step closes it first.

**Skill Replace**: if this shop's skill-replace offer is for `sinner` (`shop_replace_<sinner>` matches the name label) and `shop_replace_purchased` isn't showing, open the offer and take the first transition in `options` that the game accepts. Options: `s1_s2` (45), `s2_s3` (75), `s1_s3` (120), ranked by preference. Works once per shop, so the same step on every floor's workflow keeps converting skills all run.

**Heal Sinner**: heal `sinner` for about 50% HP and 45 SP. Costs 100.

**Heal All**: heal every sinner for about 15% HP and 15 SP. Costs 100.

**Revive**: revive `sinner` if `shop_dead_<sinner>` is on. Costs 100.

**Budget**: `reserve += amount`.

**Refresh / Affinity Refresh**: one refresh per step. Want two? Add two steps.

### Protected set (per workflow)

The workflow's keep list ∪ every tiered fusion `target` in every enabled tiered fusion step's `fusions` list ∪ every fixed fusion `target` and its `ingredients`, for enabled steps in that workflow. Sell and tiered-fusion fodder never touch it. The editor shows the derived entries read-only next to the workflow's keep list.

## Runner semantics

```
on shop entry:
  reserve = 0
  scan inventory (existing sell-popup scan), detect cost, detect shop type
  workflow = floor_schedule lookup for RunMemory.floor
  for step in workflow.steps (enabled only):
    evaluate condition -> :skipped
    dispatch           -> :done | :partial | :failed | :not_implemented
    on :failed, recover to the shop's main screen
    log outcome, re-detect cost if anything was spent or sold
leave shop
```

Single pass, no loop-back. The user expresses retries by placing steps (buy, refresh, buy).

A failure (insufficient funds, missed popup, timeout) never aborts the workflow. The runner closes any open popup, confirms the shop main screen, and moves to the next step. Each action is responsible for leaving the shop at its main screen when it returns normally.

**Tiered fusion inner loop**, the one place the runner iterates:

```
fusion = first of step.fusions whose target is not owned
if none -> :skipped

loop:
  if fusion.target owned -> :done
  if try(fusion.routes) made progress -> loop
  else -> :partial (bought or fused something) or :failed

try(routes):
  for route in routes:
    skip if combo not allowed in this shop
    skip if not reachable(route)
    if fodder covers combo + leftover -> fuse it, return progress
    for each ingredient tier still short, try(subgoals[tier]); progress -> return progress
  for route in routes that passed the checks above, in order:
    if buy_up_to: buy shelf items filling its short ingredients/leftovers of tier <= buy_up_to,
                  highest tier first; bought -> progress
  return progress if anything was bought, else no progress

reachable(route):
  for each tier in combo + leftover that owned fodder doesn't cover:
    ok if tier <= buy_up_to
    ok if any route in subgoals[tier] is allowed in this shop and reachable
    else -> false
  true
```

Any progress restarts from the top, because the inventory changed. Fusing and sub-goals are tried before buying, so owned fodder is used before cost is spent. The loop never moves on to the next fusion in `step.fusions`, even after finishing the current one.

An off-target result (wrong gift, wrong affinity) changes the inventory, so the loop re-plans with it, e.g. the new T4 may unlock T4 + T2 + T2. Guard with a max-iteration cap so a misread inventory can't spin.

### Normal vs super shop

| | Normal | Super |
|---|---|---|
| Max fusion ingredients | 3 | 5 |
| T4 threshold | 25+ points | 22+ points |
| T3 threshold | 17 to 24 | 15 to 21 |

Workflows and route trees are identical for both. When walking routes, the runner skips any combo that doesn't work in the current shop. Valid minimal combos (no ingredient removable without dropping the tier), from `docs/fusion.md`:

| Target | Works in both | Normal only | Super only |
|---|---|---|---|
| T4 | 4+4, 4+3, 4+2+2, 3+3+3, 3+3+2 | none | 4+2+1, 3+3+1, 3+2+2, 4+1+1+1, 3+2+1+1, 2+2+2+2, 3+1+1+1+1, 2+2+2+1+1 |
| T3 | 4+2, 4+1, 3+3, 3+2+1, 2+2+2 | 3+2+2 (22 points is T4 in a super shop) | 3+2, 3+1+1, 2+2+1, 2+1+1+1, 1+1+1+1+1 |

## Editor UI (`/gift_plans`)

Plan list sidebar stays. Header row: plan name, affinity select. Tabs:

**Workflows** (default tab), three columns:
1. *Workflows + floor schedule*. List of workflows (add, rename, duplicate, delete). Selected workflow shows its keep list picker. Below the list, the schedule: rows of "From floor [n] → [workflow]", sorted by floor. Warn if floor 1 has no row (shops on floor 1 would do nothing). Delete-workflow is blocked while the schedule references it.
2. *Steps* of the selected workflow. Each step is a card: drag handle, kind badge, one-line summary, condition summary, enabled toggle, duplicate, delete, expand to edit inline params and the condition. Examples:
   - `Uptie · Glimpse +2 › Hellterfly +2` with summary `up to 1 · Glimpse of Flames +2 › Hellterfly’s Dream +2`
   - `Tiered Fusion · Glimpse › Hellterfly` with summary `Glimpse of Flames › Hellterfly’s Dream`
   - `Sell · T1 then T2 · until 400 or 2 sold`
   - `Budget +300 · if missing Glimpse of Flames`
   - Broken references (deleted library entry) render red and the runner logs them as `:failed`.
3. *Palette*. Inline kinds as "add" buttons; library definitions grouped by type. Clicking appends the step to the end of the workflow. "Copy to workflow…" on a step for cross-workflow reuse of inline steps.

Reorder via a small native HTML5 drag hook in `assets/js/app.js` (pushes the new id order), plus up/down buttons. No new JS dependency.

**Condition editor** (inside an expanded step card): nested group boxes. Each group has an AND/OR toggle, "+ condition", "+ group", and remove. A condition row is a type select (cost at least / owns / doesn't own) plus a number input or the gift picker. The collapsed card shows the tree as one line: `cost >= 200 AND (missing Glimpse OR owns Fiery Down)`.

**Upties**: list of definitions; editor with name, target level (+1/+2), and one gift picked from the gift browser. Shows the gift's tier and estimated costs (0→target, and 1→2 when the target is +2). Order and max gifts live on the uptie step, whose card has an ordered multi-select of uptie definitions (click to add, drag to rerank, ✕ to remove) and a max gifts input.

Tiered fusion step cards get the same ordered multi-select over tiered fusion definitions. Adding either step from the palette starts its list with the clicked definition.

**Tiered Fusions**: list of definitions; editor with target picker (T2 to T4, no fixed ingredients), then the route tree. Each route card shows the combo (`III III II`), points, keyword odds (2 = 60%, 3 = 90%, 4+ = 99%), a normal-only/super-only badge, Dup and delete, a "buy missing up to" select, leftover inputs for T1 to T4, and one nested sub-goal list per ingredient tier (T2+). Every list ends with an "add route" picker over that tier's valid pool. Drag ⠿ to reorder within a list. New definition defaults: 3-3-2 buying up to T3 with a T3 sub-goal of 2-2-2 needing 1 leftover T2, then 4-2-2 with no buying.

**Shopping Lists**: list of definitions; editor with ordered gift list showing tier and buying cost.

Shopping lists and keep lists have Copy gifts / Paste gifts buttons sharing one clipboard. Pasting into a keep list drops Any-tier entries. Tiered fusions have Copy routes / Paste routes, limited to targets of the same tier.

**Keep Lists**: list of definitions; editor reuses the current Keep tab's gift grid. Shows which workflows use each list.

**Grace**: unchanged.

Fixed fusion, refresh, affinity refresh, sell, skill replace, and budget have no tab; they're edited on the step card. Sell's tier picker is an ordered multi-select (click to add in priority order, drag to rerank).

## What gets deleted

**Plan data keys**: top-level `keep` (moves into `library.keep_lists`), `buy_on_sight`, `fusion_targets` (with `weight`, `ingredient_source`, `fallback_of`), `uptie_targets` (with `weight`, `scope`), `skill_targets` (with `priority`), `refresh_policy`, `type` (`custom`/`predefined`).

**`gift_plan_editor_live.ex`**: `@priorities`, `@ingredient_sources`, tabs `buy`/`fusion`/`uptie`/`skills`/`refresh` and their events (`assign_buy_weight`, `remove_buy_target`, `add_fusion_target`, `remove_fusion_target`, `set_uptie_scope`, `add_uptie_target`, `remove_uptie_target`, `add_skill_target`, `remove_skill_target`, `update_refresh_policy`), helpers `buy_weight_for`, `buy_gifts_sorted`, `sort_by_weight`, `group_by_priority`, `priority_label`, `priority_tooltip`, `ingredient_source_label`, `custom_plans` filter. Kept: grace data and events, keep gift grid (now per keep list), gift picker/filter/sort, tier roman/affinity icon helpers, uptie description viewer, uptie cost table, fusion ingredient helpers.

**`shop_buyer.ex`**: all weight-driven flow: `buy_on_sight_index`, `buy_pass`, `maybe_refresh_and_continue`, `finish_shopping`, `max_normal_refreshes`, `attempt_fusion`, `pick_fusion_target`, `resolve_fusion_target`, `run_fusion`, `ensure_ingredients`, `try_refresh_and_retry`, `run_buy_on_sight_once`, `scan_and_buy`, `build_plan`, `best_purchase_set`, `total_weight`, `score_tiered_combo`, `pick_best_tiered_combo`, `@max_purchases`.

**`run_memory.ex`**: `shop_refreshes_used/1`, `increment_shop_refreshes/1`. `shop_plan` becomes the step trace for the current shop.

**`team_editor_live.ex`**: `strategy_data("gift_strategy", …)` stops creating `type: "predefined"` rows; it creates a blank v2 plan (one empty workflow, one empty keep list, schedule `from_floor 1`) with the chosen affinity.

## What breaks in the shop runner

`ShopBuyer` is renamed `Automation.Scripts.ShopRunner` and rebuilt around the step loop. Callers that change: `MirrorDungeonRunner` (alias + call), `Automation.Scripts` registry entry, `Navigator.run_shop_buyer/1` and `run_shop_dry_run/1` (`run_shop/2` and `run_shop_dry_run/2`, both taking a `floor`), `ShopRunnerLive` (floor picker, defaulting to 1; shows the resolved workflow and per-step outcome).

Kept as primitives in `Automation.Shop.Ops`, moved out of `ShopBuyer` unchanged: inventory scan (`check_inventory` and the scroll/scan/uptie-badge helpers), `detect_and_update_cost`, shelf detection (`detect_row`, `detect_candidates`, `shelf_hooks`), `buy_item` / `await_purchase_result` (already handles insufficient funds), refresh via `Engine.run_action(:shop, :refresh_shelf, ctx)`, fusion clicking (`perform_fusion`, `select_affinity`, `select_fuse_ingredients`, `confirm_fuse`), `buy_missing_ids_from_shelf`, `buy_missing_tier_from_shelf`, point tables. New: shop type detection and a `recover_to_shop/1` that closes popups after a failure.

Each action becomes a module under `Automation.Shop.Actions` with `run(step, definition, state, ctx) :: {outcome, state}`. First cut:

| Action | Status |
|---|---|
| Budget | Implemented (pure state change) |
| Refresh | Implemented |
| Buy from list | Implemented |
| Fixed Fusion | Implemented |
| Tiered Fusion | Implemented. Pure planner in `GiftPlans.FusionPlanner` (current fusion, reachability, next fusion, wanted tiers, fodder picks); `Actions.TieredFusion` runs the loop with a 15-round cap. Fodder is picked by gift id (un-uptied and cheapest first) and selected with the strict ingredient path, so protected gifts are never clicked. |
| Sell | Implemented, untested in game |
| Affinity Refresh | Implemented, untested in game. Clicks `shop_keyword_refresh`, the keyword icon (same `shop_affinity_*` hooks as the fuse popup), then `shop_keyword_refresh_popup_confirm`. |
| Uptie | Implemented, untested in game. For each planned gift: open the uptie popup if it isn't open, find the gift, `shop_uptie_popup_confirm`, click `shop_uptie_popup_commit_uptie_<target>`, then `shop_uptie_popup_commit_confirm`. If `shop_uptie_popup_commit_cancel` is still visible after 1.5s the commit didn't go through: a +0 to +2 attempt switches to +1, and the step stops after taking it (a partial uptie counts as running out of cost). Otherwise cancel and stop. |
| Heal Sinner, Heal All | Implemented, untested in game. Bail if `shop_heal_disabled` shows (checked before and after opening). Open with `shop_heal` and wait for `shop_heal_menu`. Heal Sinner: `shop_heal_greatly_heal`, `shop_heal_<sinner>`, `shop_heal_confirm`. If `shop_heal_confirm` doesn't show within 1.5s the sinner is already full, so it tries the other sinners in roster order until one offers confirm (the menu can't be left without a heal). Heal All: `shop_heal_every_sinner`. Both then wait for `shop_heal_heal_again` and click it to get back to the menu. Consecutive heal steps share one visit; any other step (or the end of the workflow) leaves through `shop_heal_return` and re-reads cost. Each heal deducts 100 from the remembered cost in the meantime. |
| Skill Replace | Implemented, untested in game. Skips unless `shop_replace_<sinner>` matches and `shop_replace_purchased` doesn't. Clicks the sinner label, awaits `shop_replace_popup`, then per option: `shop_replace_popup_<from>_<to>`, `shop_replace_popup_confirm`, and waits 1.5s for `shop_replace_popup_are_you_sure`. If it doesn't show, the option is grayed out (cost, or no skill to convert) and the next option is tried. Once it shows, clicks `shop_replace_popup_confirm` again until `shop_replace_popup_are_you_sure` is gone, then waits for `shop_replace_popup` to close and `shop_sell` to be back. No option accepted: recover to the shop and log `:skipped`. Dry run reports whether the offer is for `sinner`. |
| Revive | Implemented, untested in game. Closes the heal menu if a previous heal step left it open, then skips unless `shop_dead_<sinner>` matches on the shop screen. Opens the heal menu (same disabled checks as heal), clicks `shop_heal_revive`, `shop_heal_<sinner>`, waits 1.5s for `shop_heal_confirm` and clicks it, then `shop_heal_heal_again`. Shares the heal visit with following heal steps and deducts 100 from the remembered cost. Dry run reports whether the sinner is dead. |

Every shop visit starts with the inventory scan: open the sell popup, scroll to the bottom while classifying gifts and reading uptie badges, close it (or leave it open when the first step is a sell). Every action plans from that inventory, kept current by buys, fuses, and sells. Gift prices come from `ego_gifts` (`buying_cost`, `selling_cost`); uptie prices from the tier table in `docs/uptie.md` (`GiftPlans.uptie_cost/3`).

Dry run = resolve the workflow for the chosen floor, detect cost, inventory, and shop type, and report per step whether its condition passes and what the action would target, with no clicks. Tiered fusion, sell, and uptie report their plan: what they would fuse (and with which gifts), which tiers they'd buy, which gifts they'd sell, and which upties they'd buy at what price.

## New pure modules (testable, no hardware)

- `StarlightBot.GiftPlans`: normalize v2 data, `workflow_for_floor/2`, `protected_set/2` (per workflow), `eval_condition/2` against `%{wallet, inventory}`, id generation, reference validation (broken refs, missing keep list, unscheduled floor 1).
- `StarlightBot.GiftPlans.Combos`: `valid_combos(target_tier)` with a per-combo `shops` tag (both / normal only / super only) producing the table above, `allowed?/3`, `shops/2`, `keyword_odds/1`.
- `StarlightBot.GiftPlans.Routes`: route construction, T4 defaults, tree edits by route id (update, delete, duplicate with fresh ids, add under a parent's sub-goal tier, reorder), validity checks at every depth, `label/1`.

## Data conversion

No Ecto migration; `data` is JSON text. One-off `mix run` script rewrites the existing rows:
- `BurnTeamGifts` (id 5, used by team "Burn"): `keep` → keep list "Burn core"; `buy_on_sight` → shopping list ordered by old weight; `Glimpse of Flames` fusion → tiered fusion def; its old 3-3-2 (buy, build T3) and 4-2-2 (no buy) recipes became routes 3-3-2 (buy ≤T3, T3 sub-goal 2-2-2 leaving 1 T2) and 4-2-2; the two uptie targets → one uptie def; one "Standard" workflow (buy, refresh, buy, refresh, buy, refresh, buy, fusion, uptie) mirroring the old implicit order with `max_normal_refreshes: 3`; schedule `from_floor 1 → Standard`. `grace_picks` carries over.
- `SinkTeamGifts` (id 10): blank v2 with grace carried over.
- `sadfasdfasdf` (id 2), `BurnTeam` (id 3): deleted.

The loader only understands v2. No v1 fallback.

Step lists conversion (second one-off script): each old uptie definition with a `gifts` list was split into one definition per gift (name = gift, same `target_level`), and each uptie step's `uptie` ref became `upties` with those ids in the old gift order, taking the old definition's `max_gifts`. `fallback_level` was dropped (MaoFaustGifts had "settle for +1"). Each tiered fusion step's `fusion` ref became a one-element `fusions` list. Existing workflows that alternate single-fusion steps still work as-is and can be merged into list steps by hand.

## Final cleanup check

After the refactor lands, grep for leftovers of the old editor (v1 tab templates, weight/priority helpers, unused heex partials, `predefined` references) and delete anything still hanging around.
