defmodule StarlightBot.Automation.PlaybookRunner do
  alias StarlightBot.Automation.{ActiveSkillsWatch, BattleChain, RunMemory, SlotPlan, TrayWatch}
  alias StarlightBot.{BattleDebug, BattlePlans, Conditions, Ctx, FailureShot, SinnerProfiles}
  alias StarlightBot.BattlePlans.Resolver
  alias StarlightBot.Input.{Leeway, Mouse}
  alias StarlightBot.Navigation.{DSL, Runner}
  alias StarlightBot.Vision.{Capture, EnemyTargets, HookRegistry, Matcher, SinColor, SinnerLocator, SkillTray}

  @key_gap_ms 50
  @poll_ms 100
  @turn_start_timeout_ms 2_000
  @combat_ready_timeout_ms 3_000
  @mode_cycle_settle_ms 300
  @mode_cleared_timeout_ms 500
  @focused_key_tries 3
  @slot_click_settle_ms 150
  @ego_menu_timeout_ms 2_000
  @ego_menu_settle_ms 300
  @ego_card_timeout_ms 1_500
  @ego_card_poll_ms 50
  @ego_card_still_px 2
  @overclock_timeout_ms 3_000
  @overclock_release_settle_ms 50
  @ego_close_timeout_ms 1_500
  @ego_reclick_wait_ms 100
  @target_tries 2
  @bad_target_radius_px 50
  @drop_ready_timeout_ms 1_000
  @skill_hover_ms 200
  @screen_mid_x 960
  @skill_grab_inward_pct 0.1
  @skill_grab_depth_pct 0.6
  @bottom_skill_grab_drop_px 30
  @target_pan_settle_ms 600
  @highlight_timeout_ms 400
  @creep_step_px 18
  @creep_step_ms 30
  @redetect_drop_px 120
  @redetect_settle_ms 400
  @chosen_settle_ms 200
  @target_release_settle_ms 300
  @target_found_hold_ms 150
  @preview_alt_tab_ms 2_000
  @hover_label_min_dy 100
  @hover_label_max_dy 650
  @hover_label_max_dx 250

  @turn_started DSL.any_of([:battle_pause_button, DSL.not_hook(:battle_turn)])
  @ego_menu :battle_ego_resistances
  @ego_warning :battle_ego_warning
  @overclocked DSL.any_of([@ego_warning, :battle_ego_overclock])
  @bottom_chosen :battle_skill_tray_bottom_white_while_ready
  @hover_label :enemy_target_hovering_label
  @hover_corner :enemy_target_hovering_corner

  def play_chain_turn(_last_frame, ctx), do: start_turn("chain", ctx)

  def play_focused_turn(_last_frame, ctx) do
    dismiss_stray_overlay(ctx)
    start_turn("focused", ctx)
  end

  def preview_target(enemy_pick, ctx) do
    with_preview_memory(ctx, &do_preview_target(enemy_pick, &1))
  end

  defp do_preview_target(enemy_pick, ctx) do
    Process.sleep(@preview_alt_tab_ms)

    with {:ok, _frame, tray} <- scan(ctx),
         {:ok, grab} <- skill_point(tray, 0, :bottom, ctx) do
      Ctx.log(ctx, :info, "playbook: previewing slot 1 (bottom skill) to the #{enemy_pick} enemy")
      {:ok, drag_to_enemy(grab, %{"pick" => enemy_pick}, ctx)}
    else
      :skip -> {:error, :skill_tray_not_readable}
    end
  end

  def preview_target_everyone(ctx), do: with_preview_memory(ctx, &do_preview_target_everyone/1)

  defp with_preview_memory(%Ctx{run_memory: nil} = ctx, fun) do
    {:ok, memory} = RunMemory.start_link()

    try do
      fun.(%{ctx | run_memory: memory})
    after
      Agent.stop(memory)
    end
  end

  defp with_preview_memory(ctx, fun), do: fun.(ctx)

  defp do_preview_target_everyone(ctx) do
    Process.sleep(@preview_alt_tab_ms)

    with {:ok, _frame, %SkillTray{sinner_of_slot: [_ | _] = sinner_of_slot} = tray} <- scan(ctx) do
      results =
        sinner_of_slot
        |> Enum.with_index()
        |> Enum.map(fn {sinner, column} -> target_in_order(tray, sinner, column, column, ctx) end)

      {outcome, _attempts} = List.last(results)
      {:ok, {outcome, Enum.flat_map(results, &elem(&1, 1))}}
    else
      _ -> {:error, :skill_tray_not_readable}
    end
  end

  defp target_in_order(tray, sinner, column, enemy_offset, ctx) do
    row = Enum.random([:top, :bottom])

    case skill_point(tray, column, row, ctx) do
      {:ok, grab} ->
        Ctx.log(ctx, :info, "playbook: sinner #{sinner + 1}: slot #{column + 1} (#{row} skill) to enemy #{enemy_offset + 1} from the left")
        {outcome, attempts} = drag_to_enemy(grab, %{"pick" => "first", "offset" => enemy_offset}, ctx)
        Ctx.log(ctx, :info, "playbook: sinner #{sinner + 1}: #{inspect(outcome)}")
        {outcome, attempts}

      :skip ->
        {{:error, :slot_not_on_screen}, []}
    end
  end

  def battle_confirmed(last_frame, ctx) do
    RunMemory.put(ctx, :battle_confirmed, true)
    {:ok, last_frame}
  end

  def new_battle(last_frame, ctx) do
    RunMemory.put_battle_turn(ctx, 1)
    {:ok, last_frame}
  end

  defp dismiss_stray_overlay(ctx) do
    if await(:battle_safe_click_spot, 0) do
      Runner.run_steps([DSL.click(:battle_safe_click_spot), DSL.sleep(@key_gap_ms)], ctx)
    end
  end

  defp start_turn(kind, ctx) do
    turn = RunMemory.battle_turn(ctx)
    track = RunMemory.battle_track(ctx, kind)
    floor = if BattlePlans.lux_track?(track), do: 1, else: RunMemory.floor(ctx)
    playbook = playbook(ctx, track, floor, kind)
    actions = playbook |> Resolver.actions_for(turn) |> order_actions()

    Ctx.log(
      ctx,
      :info,
      "playbook: #{track} F#{floor} turn #{turn} -> #{playbook["name"]} [#{Enum.map_join(actions, ", ", & &1["type"])}]"
    )

    scan = if Enum.any?(BattlePlans.flatten_actions(actions), &needs_tray?/1), do: scan(ctx), else: :skip
    RunMemory.put(ctx, :target_panned?, false)
    RunMemory.put(ctx, :bad_targets, [])
    RunMemory.put(ctx, :battle_max_retries, BattlePlans.max_retries(playbook))

    turn_state = %{kind: kind, scan: scan, number: turn}
    {:steps, [run_actions(actions |> merge_keys() |> commit_trailing_rate(), turn_state)]}
  end

  def run_actions([], turn, _frame, _ctx), do: {:steps, [DSL.call(__MODULE__, :finish_turn, [:pending, turn])]}

  def run_actions([action | rest], turn, _frame, ctx) do
    if action["who"], do: Ctx.log(ctx, :info, "playbook: #{action["type"]} for #{who_text(action)} (#{skill_text(action["skill"])} skill)")

    case run_action(action, turn, ctx) do
      :pending ->
        {:steps, [run_actions(rest, turn)]}

      {:then, actions} ->
        {:steps, [run_actions(actions ++ rest, turn)]}

      {:steps, steps} ->
        {:steps, steps ++ [run_actions(rest, turn)]}

      :started ->
        if rest != [], do: Ctx.log(ctx, :info, "playbook: turn started, skipping #{length(rest)} remaining action(s)")
        {:steps, [DSL.call(__MODULE__, :finish_turn, [:started, turn])]}

      {:error, _} = error ->
        error
    end
  end

  def finish_turn(state, turn, _frame, ctx) do
    with :ok <- ensure_started(state, turn.kind, ctx) do
      RunMemory.put_battle_turn(ctx, turn.number + 1)
      {:ok, nil}
    end
  end

  def after_retry({:ok, _}, _frame, _ctx), do: {:error, :battle_left}
  def after_retry({:error, _} = error, _frame, _ctx), do: error

  def dodge_column(action, tray, column, _frame, ctx) do
    dodge(action["enemy"], tray, column, ctx)
    {:ok, nil}
  end

  def ego_column(action, tray, column, _frame, ctx) do
    with {:ok, point} <- slot_point(tray, column, ctx) do
      Ctx.log(ctx, :info, "playbook: #{action["grade"]} EGO#{if action["corrode"], do: " (corroded)"} on slot #{column + 1}")
      use_ego(point, action, ctx)
      target_after_ego(tray, column, action, ctx)
    end

    {:ok, nil}
  end

  def target_column(action, row, tray, column, _frame, ctx) do
    target_or_dodge(row, action, tray, column, ctx)
    {:ok, nil}
  end

  defp run_actions(actions, turn), do: DSL.call(__MODULE__, :run_actions, [actions, turn])

  defp playbook(ctx, track, floor, kind) do
    case RunMemory.battle_plan(ctx) |> Resolver.playbook_for(track, floor) do
      %{} = playbook ->
        playbook

      nil ->
        Ctx.log(ctx, :info, "playbook: nothing assigned to #{track} F#{floor}, using the #{kind} default")
        BattlePlans.new_playbook(kind, "Default")
    end
  end

  defp needs_tray?(%{"type" => "if"} = block), do: Enum.any?(BattlePlans.branch_conditions(block), fn tree -> Enum.any?(Conditions.leaves(tree), &(BattlePlans.sinner_leaf?(&1) or BattlePlans.tray_leaf?(&1) or BattlePlans.position_leaf?(&1))) end)
  defp needs_tray?(%{"type" => type}), do: type in ~w(dodge ego target nothing chain)

  defp order_actions(actions) do
    {terminal, rest} = Enum.split_with(actions, &BattlePlans.terminal?/1)
    rest ++ Enum.take(terminal, 1)
  end

  defp merge_keys([%{"type" => "win_rate"}, %{"type" => "commit"} | rest]),
    do: [%{"type" => "win_rate_commit"} | merge_keys(rest)]

  defp merge_keys([%{"type" => "damage_rate"}, %{"type" => "commit"} | rest]),
    do: [%{"type" => "damage_rate_commit"} | merge_keys(rest)]

  defp merge_keys([action | rest]), do: [action | merge_keys(rest)]
  defp merge_keys([]), do: []

  defp commit_trailing_rate(actions) do
    case List.last(actions) do
      %{"type" => "win_rate"} -> List.replace_at(actions, -1, %{"type" => "win_rate_commit"})
      %{"type" => "damage_rate"} -> List.replace_at(actions, -1, %{"type" => "damage_rate_commit"})
      _ -> actions
    end
  end

  defp run_action(%{"type" => "if"} = block, turn, ctx) do
    {label, branch_actions} = chosen_branch(block, turn, ctx)
    actions = branch_actions |> order_actions() |> merge_keys()

    Ctx.log(ctx, :info, "playbook: #{label} [#{Enum.map_join(actions, ", ", & &1["type"])}]")

    {:then, actions}
  end

  defp run_action(%{"type" => "retry"}, _turn, ctx) do
    target =
      case RunMemory.claim_battle_retry(ctx) do
        {:retry, retry, max_retries} ->
          Ctx.log(ctx, :info, "playbook: retrying the battle (#{retry}/#{max_retries})")
          :battle_retried

        :give_up ->
          Ctx.log(ctx, :error, "playbook: retry asked for, giving up instead (#{inspect(RunMemory.give_up(ctx))})")
          :battle_given_up
      end

    {:steps, [DSL.goto(:battle_turn, target, then: {__MODULE__, :after_retry, []})]}
  end

  defp run_action(%{"type" => "win_rate_commit"}, %{kind: kind}, ctx) do
    if press_until([:p, :enter], @turn_started, @turn_start_timeout_ms, kind, ctx), do: :started, else: :pending
  end

  defp run_action(%{"type" => "damage_rate_commit"}, turn, ctx) do
    with {:ok, _} <- press([:p, :p, :enter], ctx),
         true <- await(@turn_started, @turn_start_timeout_ms) do
      :started
    else
      _ ->
        Ctx.log(ctx, :info, "playbook: quick p p enter didn't start the turn, falling back to cycling damage")
        run_action(%{"type" => "damage_rate"}, turn, ctx)
        run_action(%{"type" => "commit"}, turn, ctx)
    end
  end

  defp run_action(%{"type" => "win_rate"}, %{kind: kind}, ctx) do
    press_until([:p], :battle_combat_ready, @combat_ready_timeout_ms, kind, ctx)
    :pending
  end

  defp run_action(%{"type" => "damage_rate"}, %{kind: kind}, ctx) do
    if press_until([:p], :battle_combat_ready, @combat_ready_timeout_ms, kind, ctx) do
      press([:p], ctx)
      Process.sleep(@mode_cycle_settle_ms)

      if await(:battle_combat_not_ready, @mode_cleared_timeout_ms) do
        Ctx.log(ctx, :info, "playbook: p cleared the selection (was already on damage), cycling back to damage")
        press_until([:p], :battle_combat_ready, @combat_ready_timeout_ms, kind, ctx) and match?({:ok, _}, press([:p], ctx))
      end
    end

    :pending
  end

  defp run_action(%{"type" => "commit"}, _turn, ctx) do
    press([:enter], ctx)
    if await(@turn_started, @turn_start_timeout_ms), do: :started, else: log_pending(ctx, "enter didn't start the turn")
  end

  defp run_action(%{"type" => type} = action, turn, ctx) when type in ~w(dodge ego target nothing) do
    with {:ok, frame, tray} <- turn.scan,
         [_ | _] = steps <- plan_steps(action, frame, tray, profiles(ctx), ctx) do
      {:steps, steps |> Enum.reject(&(&1.action == "nothing")) |> Enum.map(&slot_step(&1, frame, tray))}
    else
      _ -> :pending
    end
  end

  defp run_action(%{"type" => "chain"} = action, turn, ctx) do
    mode = action["mode"] || "fast"
    with {:ok, frame, tray} <- turn.scan,
         {:ok, gear_rect} <- find_gear(frame, ctx),
         forced = forced_rows(action["pins"] || [], frame, tray, ctx),
         forced = apply_forced(forced, tray, ctx),
         :ok <- BattleChain.drag(frame, tray, gear_rect, mode, forced, ctx, chain_opts(mode, action, frame, tray, ctx)) do
      if await(@turn_started, @turn_start_timeout_ms), do: :started, else: log_pending(ctx, "chain drag didn't start the turn")
    else
      {:error, reason} -> log_pending(ctx, "chain drag failed: #{inspect(reason)}")
      :skip -> :pending
    end
  end

  defp run_action(%{"type" => type}, _turn, ctx), do: log_pending(ctx, "unknown action #{inspect(type)}, skipping")

  defp slot_step(%{action: "dodge"} = step, _frame, tray), do: DSL.call(__MODULE__, :dodge_column, [step.holder, tray, step.column])
  defp slot_step(%{action: "ego"} = step, _frame, tray), do: DSL.call(__MODULE__, :ego_column, [step.holder, tray, step.column])
  defp slot_step(%{action: "target"} = step, _frame, tray), do: DSL.call(__MODULE__, :target_column, [step.holder, step.row, tray, step.column])

  defp target_or_dodge(:dodge, action, tray, column, ctx), do: dodge(action["enemy"], tray, column, ctx)

  defp target_or_dodge(row, %{"enemy" => %{"pick" => "none"}}, tray, column, ctx) do
    with {:ok, {sx, sy}} <- skill_point(tray, column, row, ctx) do
      Ctx.log(ctx, :info, "playbook: choosing the #{row} skill on slot #{column + 1} without a target")
      Mouse.click(sx, sy)
      Process.sleep(@slot_click_settle_ms)
    end
  end

  defp target_or_dodge(row, action, tray, column, ctx) do
    with {:ok, grab} <- skill_point(tray, column, row, ctx) do
      Ctx.log(ctx, :info, "playbook: targeting enemy #{pick_text(action["enemy"])} with slot #{column + 1} (#{row} skill)")
      drag_to_enemy(grab, action["enemy"], ctx)
    end
  end

  defp dodge(%{"pick" => pick} = enemy, tray, column, ctx) when pick != "none" do
    click_dodge(tray, column, ctx)

    with {:ok, grab} <- skill_point(tray, column, :bottom, ctx) do
      Ctx.log(ctx, :info, "playbook: dragging the dodge on slot #{column + 1} onto enemy #{pick_text(enemy)}")
      drag_to_enemy(grab, enemy, ctx)
    end
  end

  defp dodge(_enemy, tray, column, ctx), do: click_dodge(tray, column, ctx)

  defp click_dodge(tray, column, ctx) do
    with {:ok, {sx, sy}} <- slot_point(tray, column, ctx) do
      Ctx.log(ctx, :info, "playbook: dodge on slot #{column + 1}")
      Mouse.click(sx, sy)
      Process.sleep(@slot_click_settle_ms)
    end
  end

  defp ensure_started(:started, _kind, _ctx), do: :ok

  defp ensure_started(:pending, kind, ctx) do
    if await(@turn_started, 0) do
      :ok
    else
      Ctx.log(ctx, :info, "playbook: turn not started yet, trying enter")

      if match?({:ok, _}, press([:enter], ctx)) and await(@turn_started, @turn_start_timeout_ms) do
        :ok
      else
        Ctx.log(ctx, :info, "playbook: enter didn't start the turn, falling back to p + enter")

        if press_until([:p, :enter], @turn_started, @turn_start_timeout_ms, kind, ctx),
          do: :ok,
          else: {:error, :turn_not_started}
      end
    end
  end

  defp press_until(keys, condition, timeout_ms, kind, ctx, attempt \\ 1) do
    with {:ok, _} <- press(keys, ctx) do
      cond do
        await(condition, timeout_ms) ->
          true

        kind == "focused" and attempt < @focused_key_tries ->
          spot = if attempt + 1 == @focused_key_tries, do: :safe_corner, else: :battle_safe_click_spot
          Ctx.log(ctx, :info, "playbook: #{inspect(condition)} not reached, clicking #{spot} and retrying")

          case Runner.run_steps([DSL.click(spot), DSL.sleep(@key_gap_ms)], ctx) do
            {:ok, _} -> press_until(keys, condition, timeout_ms, kind, ctx, attempt + 1)
            {:error, _} -> false
          end

        true ->
          Ctx.log(ctx, :info, "playbook: #{inspect(condition)} not reached after #{attempt} attempt(s)")
          false
      end
    else
      {:error, _} -> false
    end
  end

  defp press(keys, ctx) do
    keys
    |> Enum.map(&DSL.key/1)
    |> Enum.intersperse(DSL.sleep(@key_gap_ms))
    |> Runner.run_steps(ctx)
  end

  defp target_after_ego(tray, column, %{"enemy" => %{"pick" => pick} = enemy}, ctx) when pick != "none" do
    with {:ok, grab} <- skill_point(tray, column, :bottom, ctx) do
      Ctx.log(ctx, :info, "playbook: targeting enemy #{pick_text(enemy)} with the EGO")
      drag_to_enemy(grab, enemy, ctx)
    end
  end

  defp target_after_ego(_tray, _column, _action, _ctx), do: :ok

  defp use_ego({sx, sy} = point, action, ctx, retry? \\ true) do
    Mouse.move_to(sx, sy)
    Mouse.mouse_down()
    opened? = await(@ego_menu, @ego_menu_timeout_ms)
    Mouse.mouse_up()

    cond do
      opened? ->
        pick_ego_card(action, ctx)

      retry? ->
        Ctx.log(ctx, :info, "playbook: EGO menu didn't open, clicking battle_safe_click_spot and trying again")

        case Runner.run_steps([DSL.click(:battle_safe_click_spot), DSL.sleep(@key_gap_ms)], ctx) do
          {:ok, _} -> use_ego(point, action, ctx, false)
          {:error, _} -> Ctx.log(ctx, :error, "playbook: EGO menu didn't open, skipping")
        end

      true ->
        Ctx.log(ctx, :error, "playbook: EGO menu didn't open, skipping")
    end
  end

  defp pick_ego_card(action, ctx) do
    hook = :"battle_ego_#{action["grade"]}"

    deadline = System.monotonic_time(:millisecond) + @ego_card_timeout_ms

    with {:ok, {x, _y, w, _h}} <- await_still_card(hook, nil, deadline),
         {:ok, %{region: {_wx, wy, _ww, wh}}} <- HookRegistry.find(@ego_warning),
         {:ok, card_point} <- Runner.to_screen_point({x + w / 2, wy + wh / 2}),
         {cx, cy} = Leeway.click(card_point) do
      if action["corrode"], do: overclock(cx, cy, ctx)

      Mouse.click(cx, cy)
      Process.sleep(@ego_reclick_wait_ms)

      unless await(DSL.not_hook(@ego_menu), 0), do: Mouse.click(cx, cy)

      unless await(DSL.not_hook(@ego_menu), @ego_close_timeout_ms) do
        close_ego_menu(ctx, "EGO choice didn't take (not enough resources?)")
      end
    else
      :not_found -> close_ego_menu(ctx, "no #{action["grade"]} EGO card found")
      {:error, reason} -> close_ego_menu(ctx, "EGO card pick failed: #{inspect(reason)}")
    end
  end

  defp await_still_card(hook, previous, deadline) do
    card =
      case Capture.grab_frame() do
        {:ok, frame} -> frame |> Matcher.find_all(hook) |> Enum.min_by(&elem(&1, 0), fn -> nil end)
        {:error, _} -> nil
      end

    cond do
      card && previous && card_still?(card, previous) -> {:ok, card}
      System.monotonic_time(:millisecond) >= deadline -> if card, do: {:ok, card}, else: :not_found
      true ->
        Process.sleep(@ego_card_poll_ms)
        await_still_card(hook, card, deadline)
    end
  end

  defp card_still?({x, y, _w, _h}, {px, py, _pw, _ph}), do: abs(x - px) <= @ego_card_still_px and abs(y - py) <= @ego_card_still_px

  defp overclock(cx, cy, ctx) do
    Mouse.move_to(cx, cy)
    Mouse.mouse_down()
    warned? = await(@overclocked, @overclock_timeout_ms)
    Mouse.mouse_up()
    Process.sleep(@overclock_release_settle_ms)

    if warned?,
      do: Ctx.log(ctx, :info, "playbook: overclock applied, confirming"),
      else: Ctx.log(ctx, :error, "playbook: no overclock warning after #{@overclock_timeout_ms}ms, confirming anyway")
  end

  defp close_ego_menu(ctx, reason) do
    Ctx.log(ctx, :error, "playbook: #{reason}, closing the EGO menu")
    Runner.run_steps([DSL.click(@ego_menu), DSL.sleep(@ego_menu_settle_ms)], ctx)
  end

  defp chosen_branch(block, turn, ctx) do
    names = sinner_names()

    candidates =
      [{"if", block["condition"], block["then"]}] ++
        Enum.map(BattlePlans.elifs(block), &{"else if", &1["condition"], &1["actions"]})

    case Enum.find(candidates, fn {_word, condition, _actions} -> condition_met?(condition, turn.scan, ctx) end) do
      {word, condition, actions} -> {"#{word} #{BattlePlans.condition_label(condition, names)} -> then", actions}
      nil -> {"if #{BattlePlans.condition_label(block["condition"], names)} -> else", block["else"] || []}
    end
  end

  defp condition_met?(nil, _scan, _ctx), do: true

  defp condition_met?(tree, scan, ctx) do
    case Capture.grab_frame() do
      {:ok, frame} ->
        leaves = Conditions.leaves(tree)
        sinners = if Enum.any?(leaves, &BattlePlans.sinner_leaf?/1), do: sinner_count(scan, ctx)
        classified = if Enum.any?(leaves, &BattlePlans.tray_leaf?/1), do: classify_scan(scan, ctx)
        Conditions.eval(tree, &condition_leaf(&1, frame, %{sinners: sinners, classified: classified, scan: scan}, ctx))

      {:error, reason} ->
        Ctx.log(ctx, :error, "playbook: couldn't grab a frame for the condition (#{inspect(reason)}), treating it as false")
        false
    end
  end

  defp sinner_count({:ok, _frame, %SkillTray{sinner_of_slot: [_ | _] = sinner_of_slot}}, ctx) do
    count = List.last(sinner_of_slot) + 1
    Ctx.log(ctx, :info, "playbook: #{count} sinner(s) in the skill tray")
    count
  end

  defp sinner_count(_scan, _ctx), do: nil

  defp classify_scan({:ok, frame, tray}, ctx) do
    {top, bottom} = classified = SinColor.classify_tray(frame.mat, tray)
    Ctx.log(ctx, :info, "playbook: tray sins top #{Enum.map_join(top, " ", & &1.sin)}, bottom #{Enum.map_join(bottom, " ", & &1.sin)}")
    classified
  end

  defp classify_scan(_scan, _ctx), do: nil

  defp condition_leaf(leaf, frame, tray_info, ctx) do
    case eval_leaf(leaf, frame, tray_info, ctx) do
      :unknown -> false
      result -> result != (leaf["not"] == true)
    end
  end

  defp eval_leaf(leaf, frame, tray_info, ctx) do
    cond do
      BattlePlans.tray_leaf?(leaf) -> tray_count_leaf(leaf, tray_info, ctx)
      BattlePlans.position_leaf?(leaf) -> position_leaf(leaf, tray_info, ctx)
      BattlePlans.fight_leaf?(leaf) -> fight_leaf(leaf, ctx)
      BattlePlans.enemy_leaf?(leaf) -> enemy_count_leaf(leaf, frame, ctx)
      not BattlePlans.sinner_leaf?(leaf) -> hook_leaf(leaf, frame, ctx)
      is_nil(tray_info.sinners) -> :unknown
      true -> BattlePlans.sinner_count_matches?(leaf, tray_info.sinners)
    end
  end

  defp tray_count_leaf(_leaf, %{classified: nil}, _ctx), do: :unknown

  defp tray_count_leaf(leaf, %{classified: classified, scan: {:ok, frame, tray}}, ctx) do
    columns =
      case leaf["sinners"] do
        [_ | _] = sinners ->
          %{"who" => "only", "sinners" => sinners, "skill" => %{"pick" => "all"}}
          |> holder_slots(frame, tray, profiles(ctx), ctx)
          |> Enum.flat_map(fn {_holder, taken} -> taken end)

        _anyone ->
          :all
      end

    count = BattlePlans.tray_count(leaf, classified, columns)
    Ctx.log(ctx, :info, "playbook: #{BattlePlans.condition_label(leaf, sinner_names())} (counted #{count})")
    BattlePlans.tray_count_matches?(leaf, count)
  end

  defp position_leaf(%{"sinners" => [_ | _] = sinners} = leaf, %{scan: {:ok, frame, %SkillTray{sinner_of_slot: [_ | _] = sinner_of_slot} = tray}}, ctx) do
    count = List.last(sinner_of_slot) + 1

    located =
      Enum.map(sinners, fn sinner ->
        with {:ok, profile} <- fetch_profile(profiles(ctx), sinner, ctx),
             {:ok, hooks} <- locator_hooks(profile, ctx),
             {:ok, column} <- locate(frame, tray, hooks, profile, ctx) do
          {profile.name, Enum.at(sinner_of_slot, column)}
        end
      end)

    if Enum.member?(located, :skip) do
      Ctx.log(ctx, :info, "playbook: #{BattlePlans.condition_label(leaf, sinner_names())} can't be checked, treating it as false")
      :unknown
    else
      found = Enum.map_join(located, ", ", fn {name, index} -> "#{name} is sinner #{index + 1}" end)
      Ctx.log(ctx, :info, "playbook: #{BattlePlans.condition_label(leaf, sinner_names())} (#{found} of #{count})")
      BattlePlans.position_matches?(leaf, Enum.map(located, &elem(&1, 1)), count)
    end
  end

  defp position_leaf(_leaf, _tray_info, _ctx), do: :unknown

  defp enemy_count_leaf(leaf, frame, ctx) do
    count = frame |> EnemyTargets.find() |> length()
    Ctx.log(ctx, :info, "playbook: #{count} enemy target(s) detected, #{BattlePlans.condition_label(leaf)}")
    BattlePlans.enemy_count_matches?(leaf, count)
  end

  defp fight_leaf(_leaf, ctx) do
    boss? = RunMemory.venue(ctx) == "md_boss"
    Ctx.log(ctx, :info, "playbook: #{if boss?, do: "boss fight", else: "not a boss fight"} (venue #{RunMemory.venue(ctx)})")
    boss?
  end

  defp hook_leaf(%{"hook" => name}, frame, ctx) do
    case Enum.find(HookRegistry.all_names(), &(Atom.to_string(&1) == name)) do
      nil ->
        Ctx.log(ctx, :error, "playbook: condition hook #{inspect(name)} isn't loaded, treating it as false")
        :unknown

      hook ->
        Runner.hook_matches?(frame, hook)
    end
  end

  defp drag_to_enemy(grab, enemy, ctx) do
    case drag_once(grab, enemy, ctx) do
      {:gave_up, attempts} = failed ->
        remember_bad_targets(attempts, ctx)

        if await(:battle_combat_ready, @drop_ready_timeout_ms) do
          failed
        else
          Ctx.log(ctx, :info, "playbook: battle_combat_ready is off after the failed drop, grabbing the skill again for another target")
          FailureShot.record("battle_combat_ready_off_after_drop", ctx)
          {outcome, retry_attempts} = drag_once(grab, enemy, ctx)
          if outcome == :gave_up, do: remember_bad_targets(retry_attempts, ctx)
          {outcome, attempts ++ retry_attempts}
        end

      result ->
        result
    end
  end

  defp remember_bad_targets(attempts, ctx) do
    points = for %{chosen: %{point: point}} <- attempts, do: point
    RunMemory.update(ctx, :bad_targets, [], &(points ++ &1))
  end

  defp avoid_bad_targets(targets, ctx) do
    bad = RunMemory.get(ctx, :bad_targets, [])

    case Enum.reject(targets, fn target -> Enum.any?(bad, &near?(&1, target.point)) end) do
      [] -> targets
      good -> good
    end
  end

  defp near?({bx, by}, {x, y}), do: (bx - x) ** 2 + (by - y) ** 2 <= @bad_target_radius_px ** 2

  defp drag_once({gx, gy}, enemy, ctx) do
    Mouse.move_to(gx, gy)
    Process.sleep(@skill_hover_ms)
    Mouse.mouse_down()

    settle = if RunMemory.get(ctx, :target_panned?, false), do: [], else: [DSL.sleep(@target_pan_settle_ms)]

    try do
      case Runner.run_steps([DSL.move_to(:battle_drag_checkpoint) | settle], ctx) do
        {:ok, _} ->
          RunMemory.put(ctx, :target_panned?, true)
          aim(enemy, 1, nil, [], ctx)

        {:error, reason} -> {{:error, reason}, []}
      end
    after
      Mouse.mouse_up()
      Process.sleep(@target_release_settle_ms)
    end
  end

  defp aim(_enemy, attempt, nil, attempts, ctx) when attempt > @target_tries do
    Ctx.log(ctx, :error, "playbook: no enemy detected after #{@target_tries} tries, releasing at battle_drag_checkpoint")
    Runner.run_steps([DSL.move_to(:battle_drag_checkpoint)], ctx)
    {:gave_up, Enum.reverse(attempts)}
  end

  defp aim(_enemy, attempt, last_point, attempts, ctx) when attempt > @target_tries do
    Ctx.log(ctx, :error, "playbook: no enemy highlighted after #{@target_tries} tries, releasing at last detected target #{inspect(last_point)}")
    move_held(last_point)
    {:gave_up, Enum.reverse(attempts)}
  end

  defp aim(enemy, attempt, last_point, attempts, ctx) do
    if last_point do
      {x, y} = last_point
      move_held({x, y + @redetect_drop_px})
      Process.sleep(@redetect_settle_ms)
    end

    with :ok <- guard(ctx),
         {:ok, frame} <- Capture.grab_frame() do
      targets = EnemyTargets.find(frame)
      BattleDebug.record_enemies(frame, targets, ctx)

      case pick_enemy(targets |> BattlePlans.apply_ignores(enemy["ignore"]) |> avoid_bad_targets(ctx), enemy, attempt, ctx) do
        {:ok, target} ->
          attempts = [%{frame: frame, targets: targets, chosen: target} | attempts]
          move_held(target.point)
          hovered = if hovering?(target.point, @highlight_timeout_ms, ctx), do: target.point, else: creep(target.point, target.icon, ctx)

          cond do
            is_nil(hovered) ->
              Ctx.log(ctx, :info, "playbook: enemy at #{inspect(target.point)} didn't show its hover label (try #{attempt})")
              aim(enemy, attempt + 1, target.point, attempts, ctx)

            still_hovering?(hovered, ctx) ->
              Ctx.log(ctx, :info, "playbook: enemy hover label confirmed at #{inspect(hovered)} on try #{attempt}, releasing")
              {{:highlighted, attempt}, Enum.reverse(attempts)}

            true ->
              Ctx.log(ctx, :info, "playbook: enemy highlight dropped during the #{@target_found_hold_ms}ms hold (try #{attempt})")
              aim(enemy, attempt + 1, target.point, attempts, ctx)
          end

        :skip ->
          aim(enemy, attempt + 1, last_point, [%{frame: frame, targets: targets, chosen: nil} | attempts], ctx)
      end
    else
      {:error, :window_not_focused} = error -> {error, Enum.reverse(attempts)}
      {:error, _} -> aim(enemy, attempt + 1, last_point, attempts, ctx)
    end
  end

  defp still_hovering?(point, ctx) do
    Process.sleep(@target_found_hold_ms)
    hovering?(point, 0, ctx)
  end

  defp creep({_x, y}, {_ix, icon_y}, _ctx) when y - @creep_step_px < icon_y, do: nil

  defp creep({x, y}, icon, ctx) do
    point = {x, y - @creep_step_px}
    move_held(point)
    Process.sleep(@creep_step_ms)
    if hovering?(point, 0, ctx), do: point, else: creep(point, icon, ctx)
  end

  defp hovering?(point, timeout_ms, ctx), do: poll_hover(point, System.monotonic_time(:millisecond) + timeout_ms, ctx)

  defp poll_hover(point, deadline, ctx) do
    hover =
      case Capture.grab_frame() do
        {:ok, frame} ->
          if Matcher.check(frame, @hover_corner) do
            :corner
          else
            frame |> Matcher.find_all(@hover_label) |> Enum.find(&hover_label_for?(&1, point))
          end

        {:error, _} ->
          nil
      end

    cond do
      hover == :corner ->
        Ctx.log(ctx, :info, "playbook: hover corner on under cursor #{inspect(point)}")
        true

      hover ->
        Ctx.log(ctx, :info, "playbook: hover label #{inspect(hover)} under cursor #{inspect(point)}")
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(@poll_ms)
        poll_hover(point, deadline, ctx)
    end
  end

  def hover_label_for?({x, y, w, h}, {cx, cy}) do
    dx = x + w / 2 - cx
    dy = y + h / 2 - cy
    dy >= @hover_label_min_dy and dy <= @hover_label_max_dy and abs(dx) <= @hover_label_max_dx
  end

  defp move_held(point) do
    case Runner.to_screen_point(point) do
      {:ok, {sx, sy}} -> Mouse.move_to(sx, sy)
      {:error, _} -> :ok
    end
  end

  defp pick_enemy([], _enemy, attempt, ctx) do
    Ctx.log(ctx, :info, "playbook: no enemy targets detected (try #{attempt})")
    :skip
  end

  defp pick_enemy(targets, enemy, _attempt, _ctx), do: {:ok, Enum.at(targets, BattlePlans.target_index(length(targets), enemy))}

  defp who_text(%{"who" => who} = action) do
    names = sinner_names()

    case action["sinners"] || [] do
      [] -> who
      sinners -> "#{who} #{Enum.map_join(sinners, ", ", &Map.get(names, &1, inspect(&1)))}"
    end
  end

  defp skill_text(%{} = skill), do: BattlePlans.skill_label(skill)
  defp skill_text(_skill), do: "any"

  defp pick_text(enemy), do: BattlePlans.enemy_label(enemy)


  defp skill_point(tray, column, row, ctx) do
    %{y: y, h: h} = skill_row = if row == :top, do: tray.top_row, else: tray.bottom_row
    {x0, x1} = skill_row |> SkillTray.row_columns() |> Enum.at(column)
    center_x = (x0 + x1) / 2
    toward_middle = if center_x < @screen_mid_x, do: 1, else: -1
    drop = if row == :top, do: 0, else: @bottom_skill_grab_drop_px
    point = {center_x + toward_middle * (x1 - x0) * @skill_grab_inward_pct, y + h * @skill_grab_depth_pct + drop}

    case Runner.to_screen_point(point) do
      {:ok, point} ->
        {:ok, Leeway.click(point)}

      {:error, reason} ->
        Ctx.log(ctx, :error, "playbook: can't map slot #{column + 1} to the screen: #{inspect(reason)}")
        :skip
    end
  end

  defp scan(ctx) do
    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, tray} <- SkillTray.scan(frame) do
      TrayWatch.record(frame)
      BattleDebug.record_tray(frame, tray, ctx)
      Ctx.log(ctx, :info, "playbook: skill tray read, sinner per slot [#{Enum.map_join(tray.sinner_of_slot || [], " ", &(&1 + 1))}]")
      {:ok, frame, tray}
    else
      other ->
        Ctx.log(ctx, :error, "playbook: skill tray not readable (#{inspect(other)}), skipping tray actions and sinner conditions this turn")
        :skip
    end
  end

  defp find_gear(frame, ctx) do
    case Matcher.find(frame, :battle_chain) do
      {:ok, rect} ->
        {:ok, rect}

      :not_found ->
        Ctx.log(ctx, :error, "playbook: chain gear not found, skipping chain action")
        :skip
    end
  end

  defp slot_point(tray, column, ctx) do
    case Runner.to_screen_point({SkillTray.slot_x(tray, column), tray.sinner_action_y}) do
      {:ok, point} ->
        {:ok, Leeway.click(point)}

      {:error, reason} ->
        Ctx.log(ctx, :error, "playbook: can't map slot #{column + 1} to the screen: #{inspect(reason)}")
        :skip
    end
  end

  defp chain_opts("a_res_def", action, frame, tray, ctx) do
    [
      defense_sins: defense_sins(frame, tray, ctx),
      max_defenses: action["max_defenses"],
      click_defense: fn column -> click_dodge(tray, column, ctx) end
    ]
  end

  defp chain_opts(_mode, _action, _frame, _tray, _ctx), do: []

  defp defense_sins(frame, tray, ctx) do
    found = SinnerLocator.locate(frame, tray, defense_candidates(ctx))

    sins =
      Enum.reduce(found, List.duplicate(nil, length(tray.sinner_of_slot)), fn claim, acc ->
        sin = String.to_existing_atom(claim.profile.defense_affinity)
        Ctx.log(ctx, :info, "playbook: #{claim.profile.name} (#{claim.hook}) found at slot #{claim.column + 1}, defense is #{sin}")
        Enum.reduce(claim.columns, acc, &List.replace_at(&2, &1, sin))
      end)

    if found == [], do: Ctx.log(ctx, :info, "playbook: no sinner profiles found in the skill tray, chaining without defense")
    sins
  end

  defp defense_candidates(ctx) do
    planned = BattlePlans.profiles(RunMemory.battle_plan(ctx))

    SinnerProfiles.list()
    |> Enum.filter(&(&1.defense_affinity in SinnerProfiles.sins()))
    |> Enum.group_by(& &1.sinner)
    |> Enum.flat_map(fn {sinner, all} ->
      case Enum.filter(all, &(&1.id in Map.get(planned, sinner, []))) do
        [] -> all
        chosen -> chosen
      end
    end)
  end

  defp profiles(ctx) do
    all = SinnerProfiles.list()
    by_id = Map.new(all, &{&1.id, &1})

    planned =
      for {sinner, ids} <- BattlePlans.profiles(RunMemory.battle_plan(ctx)),
          [_ | _] = chosen <- [Enum.flat_map(ids, &List.wrap(by_id[&1]))],
          into: %{},
          do: {sinner, merged_profile(sinner, chosen)}

    fallback =
      all
      |> Enum.group_by(& &1.sinner)
      |> Map.reject(fn {sinner, _} -> Map.has_key?(planned, sinner) end)
      |> Map.new(fn {sinner, chosen} -> {sinner, merged_profile(sinner, chosen)} end)

    Map.merge(fallback, planned)
  end

  defp merged_profile(sinner, [first | _] = chosen) do
    first
    |> Map.put(:name, SinnerProfiles.label(sinner))
    |> Map.put(:hook_names, chosen |> Enum.flat_map(&SinnerProfiles.locator_hooks/1) |> Enum.uniq())
  end

  defp sinner_names, do: Map.new(SinnerProfiles.sinners(), &{&1, SinnerProfiles.label(&1)})

  defp forced_rows(pins, frame, tray, ctx) do
    profiles = profiles(ctx)
    classified = if Enum.any?(pins, &BattlePlans.uses_priority?/1), do: SinColor.classify_tray(frame.mat, tray)

    Enum.reduce(pins, %{}, fn pin, acc ->
      rows =
        pin
        |> holder_slots(frame, tray, profiles, ctx)
        |> Enum.map(fn {holder, taken} -> pin_rows(holder, taken, classified, ctx) end)
        |> Enum.reduce(%{}, &Map.merge/2)

      Map.merge(rows, acc)
    end)
  end

  defp apply_forced(forced, tray, ctx) do
    Map.new(forced, fn
      {column, :dodge} ->
        click_dodge(tray, column, ctx)
        {column, :bottom}

      {column, {:ego, holder}} ->
        ego_column(Map.delete(holder, "enemy"), tray, column, nil, ctx)
        {column, :bottom}

      entry ->
        entry
    end)
  end

  defp pin_rows(%{"type" => "dodge"}, columns, _classified, _ctx), do: Map.new(columns, &{&1, :dodge})
  defp pin_rows(%{"type" => "ego"} = holder, columns, _classified, _ctx), do: Map.new(columns, &{&1, {:ego, holder}})

  defp pin_rows(%{"row" => "priority"} = pin, columns, {top, bottom}, ctx) do
    Map.new(columns, fn column ->
      top_cell = Enum.at(top, column)
      bottom_cell = Enum.at(bottom, column)
      row = BattlePlans.pick_row(pin, top_cell, bottom_cell)

      Ctx.log(
        ctx,
        :info,
        "playbook: slot #{column + 1} #{BattlePlans.row_label(pin)}: top #{BattlePlans.cell_label(top_cell)}, bottom #{BattlePlans.cell_label(bottom_cell)} -> #{row}"
      )

      {column, row}
    end)
  end

  defp pin_rows(%{"row" => "top"}, columns, _classified, _ctx), do: Map.new(columns, &{&1, :top})
  defp pin_rows(_pin, columns, _classified, _ctx), do: Map.new(columns, &{&1, :bottom})

  defp holder_slots(holder, frame, tray, profiles, ctx) do
    {assigned, notes} = SlotPlan.assign(holder, slot_env(holder, frame, tray, profiles, ctx))
    log_notes(notes, ctx)
    assigned
  end

  defp plan_steps(holder, frame, tray, profiles, ctx) do
    {steps, notes} = SlotPlan.plan(holder, slot_env(holder, frame, tray, profiles, ctx))
    log_notes(notes, ctx)
    steps
  end

  defp slot_env(holder, frame, tray, profiles, ctx) do
    %{
      columns: all_columns(tray),
      tray_groups: tray_groups(tray),
      classified: if(SlotPlan.needs_classified?(holder), do: SinColor.classify_tray(frame.mat, tray)),
      bottom_columns: fn -> bottom_chosen_columns(tray, ctx) end,
      defense_sins: fn -> defense_sins(frame, tray, ctx) end,
      sinner_groups: fn sinner_holder -> sinner_groups(sinner_holder["who"], sinner_holder["sinners"] || [], frame, tray, profiles, ctx) end
    }
  end

  defp log_notes(notes, ctx), do: Enum.each(notes, &Ctx.log(ctx, :info, "playbook: #{&1}"))

  defp all_columns(tray), do: Enum.to_list(0..(length(tray.sinner_of_slot) - 1)//1)

  defp settle(ms), do: Process.sleep(ms)

  def used_rows(frame, tray) do
    with {:ok, hook} <- HookRegistry.find(@bottom_chosen) do
      rects = Matcher.find_all(frame, @bottom_chosen)
      bottom = SkillTray.columns_under(tray, rects)
      rows = Enum.map(all_columns(tray), &{&1, if(&1 in bottom, do: :bottom, else: :top)})
      {:ok, %{rows: rows, rects: rects, region: hook.region}}
    end
  end

  defp bottom_chosen_columns(tray, ctx) do
    with {:ok, _hook} <- HookRegistry.find(@bottom_chosen),
         :ok <- settle(@chosen_settle_ms),
         {:ok, fresh} <- Capture.grab_frame(),
         {:ok, detail} <- used_rows(fresh, tray) do
      ActiveSkillsWatch.record(fresh, tray, detail)
      {:ok, for({column, :bottom} <- detail.rows, do: column)}
    else
      error ->
        Ctx.log(ctx, :error, "playbook: can't read which slots use a bottom skill (#{inspect(error)}), skipping")
        :skip
    end
  end

  defp sinner_groups("except", ids, frame, tray, profiles, ctx) do
    with {:ok, excluded} <- located_groups(ids, frame, tray, profiles, "so everyone counts as not", ctx) do
      names = Enum.map_join(ids, ", ", &SinnerProfiles.label/1)
      who = %{name: if(ids == [], do: "everyone", else: "everyone but #{names}")}
      {:ok, tray |> tray_groups() |> Enum.reject(&(&1 in excluded)) |> Enum.map(&{&1, who})}
    end
  end

  defp sinner_groups(side, ids, frame, tray, profiles, ctx) when side in ["after", "before"] do
    with {:ok, anchors} <- located_groups(ids, frame, tray, profiles, "so it can't anchor", ctx) do
      case List.flatten(anchors) do
        [] ->
          Ctx.log(ctx, :info, "playbook: none of the #{side} sinners are in the skill tray, skipping")
          :skip

        anchor_columns ->
          names = Enum.map_join(ids, ", ", &SinnerProfiles.label/1)
          who = %{name: "everyone #{side} #{names}"}
          {:ok, tray |> tray_groups() |> Enum.filter(&on_side?(side, &1, anchor_columns)) |> Enum.map(&{&1, who})}
      end
    end
  end

  defp sinner_groups(_only, [], _frame, _tray, _profiles, ctx) do
    Ctx.log(ctx, :info, "playbook: no sinners picked, skipping")
    :skip
  end

  defp sinner_groups(_only, ids, frame, tray, profiles, ctx) do
    groups =
      Enum.flat_map(ids, fn id ->
        with {:ok, profile} <- fetch_profile(profiles, id, ctx),
             {:ok, hooks} <- locator_hooks(profile, ctx),
             {:ok, column} <- locate(frame, tray, hooks, profile, ctx) do
          [{SkillTray.owned_columns(tray, column), profile}]
        else
          :skip -> []
        end
      end)

    if groups == [], do: :skip, else: {:ok, groups}
  end

  defp on_side?("after", columns, anchor_columns), do: Enum.min(columns) > Enum.max(anchor_columns)
  defp on_side?("before", columns, anchor_columns), do: Enum.max(columns) < Enum.min(anchor_columns)

  defp located_groups(ids, frame, tray, profiles, missing_note, ctx) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      with {:ok, profile} <- fetch_profile(profiles, id, ctx),
           {:ok, hooks} <- locator_hooks(profile, ctx) do
        case find_locator(frame, hooks) do
          nil ->
            Ctx.log(ctx, :info, "playbook: #{profile.name} (#{hook_names(hooks)}) not found in the skill tray, #{missing_note} #{profile.name}")
            save_tray_miss(frame, hooks, ctx)
            {:cont, {:ok, acc}}

          {hook, rects} ->
            {x, _y, w, _h} = Enum.min_by(rects, &elem(&1, 0))
            column = SkillTray.column_at(tray, x + w / 2)
            Ctx.log(ctx, :info, "playbook: #{profile.name} (#{hook}) found at slot #{column + 1}")
            {:cont, {:ok, [SkillTray.owned_columns(tray, column) | acc]}}
        end
      else
        :skip -> {:halt, :skip}
      end
    end)
  end

  defp save_tray_miss(frame, hooks, ctx) do
    if Application.get_env(:starlight_bot, :save_timeout_frames, false) do
      stamp = NaiveDateTime.local_now() |> NaiveDateTime.to_string() |> String.replace([" ", ":", "."], "_")
      dir = Path.join(StarlightBot.Data.log_dir(), "timeouts")
      File.mkdir_p!(dir)
      path = Path.expand(Path.join(dir, "#{stamp}_tray_miss_#{hook_names(hooks, "_")}.png"))
      Evision.imwrite(path, frame.mat)
      Ctx.log(ctx, :info, "saved the screen at the tray miss to #{path}")
    end
  end

  defp tray_groups(tray) do
    tray.sinner_of_slot
    |> Enum.with_index()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  defp fetch_profile(_profiles, nil, ctx) do
    Ctx.log(ctx, :error, "playbook: no sinner picked, skipping")
    :skip
  end

  defp fetch_profile(profiles, sinner, ctx) do
    case Map.fetch(profiles, sinner) do
      {:ok, profile} ->
        {:ok, profile}

      :error ->
        Ctx.log(ctx, :error, "playbook: #{SinnerProfiles.label(sinner)} has no sinner profile in this battle plan, skipping")
        :skip
    end
  end

  defp locator_hooks(profile, ctx) do
    names = profile.hook_names
    loaded = Map.new(HookRegistry.all_names(), &{Atom.to_string(&1), &1})

    case Enum.flat_map(names, &List.wrap(loaded[&1])) do
      [] ->
        Ctx.log(ctx, :error, "playbook: #{profile.name} locator hooks #{inspect(names)} aren't loaded, skipping")
        :skip

      hooks ->
        {:ok, hooks}
    end
  end

  defp find_locator(frame, hooks), do: Matcher.find_any(frame, hooks)

  defp hook_names(hooks, joiner \\ "/"), do: Enum.map_join(hooks, joiner, &Atom.to_string/1)

  defp locate(frame, tray, hooks, profile, ctx) do
    case find_locator(frame, hooks) do
      nil ->
        Ctx.log(ctx, :info, "playbook: #{profile.name} (#{hook_names(hooks)}) not found in the skill tray, skipping")
        save_tray_miss(frame, hooks, ctx)
        :skip

      {hook, rects} ->
        {x, _y, w, _h} = Enum.min_by(rects, &elem(&1, 0))
        column = SkillTray.column_at(tray, x + w / 2)

        if length(rects) > 1,
          do: Ctx.log(ctx, :info, "playbook: #{profile.name} (#{hook}) matched #{length(rects)} times, using the leftmost (slot #{column + 1})"),
          else: Ctx.log(ctx, :info, "playbook: #{profile.name} (#{hook}) found at slot #{column + 1}")

        {:ok, column}
    end
  end

  defp guard(ctx) do
    cond do
      Ctx.pause_requested?(ctx) ->
        Ctx.log(ctx, :info, "pause requested, stopping the playbook")
        {:error, :window_not_focused}

      Capture.focused?() ->
        :ok

      true ->
        Ctx.log(ctx, :error, "game window lost focus (alt-tabbed?), stopping the playbook")
        {:error, :window_not_focused}
    end
  end

  defp await(condition, timeout_ms), do: poll(condition, System.monotonic_time(:millisecond) + timeout_ms)

  defp poll(condition, deadline) do
    matched? =
      case Capture.grab_frame() do
        {:ok, frame} -> Runner.hook_matches?(frame, condition)
        {:error, _} -> false
      end

    cond do
      matched? ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(@poll_ms)
        poll(condition, deadline)
    end
  end

  defp log_pending(ctx, text) do
    Ctx.log(ctx, :info, "playbook: #{text}")
    :pending
  end
end
