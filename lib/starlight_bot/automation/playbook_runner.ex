defmodule StarlightBot.Automation.PlaybookRunner do
  alias StarlightBot.Automation.{BattleChain, Engine, RunMemory, TrayWatch}
  alias StarlightBot.{BattleStrategies, Conditions, Ctx, SinnerProfiles}
  alias StarlightBot.BattleStrategies.Resolver
  alias StarlightBot.Input.Mouse
  alias StarlightBot.Navigation.{DSL, Runner}
  alias StarlightBot.Vision.{Capture, EnemyTargets, HookRegistry, Matcher, SinColor, SkillTray}

  @key_gap_ms 50
  @poll_ms 100
  @turn_start_timeout_ms 2_000
  @combat_ready_timeout_ms 3_000
  @mode_cycle_settle_ms 300
  @mode_cleared_timeout_ms 500
  @focused_key_tries 3
  @clear_max_presses 4
  @clear_settle_ms 500
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
  @target_tries 3
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
  @target_release_settle_ms 300
  @target_found_hold_ms 150
  @preview_alt_tab_ms 2_000
  @hover_label_min_dy 100
  @hover_label_max_dy 650
  @hover_label_max_dx 250

  @turn_started DSL.any_of([:battle_pause_button, DSL.not_hook(:battle_turn)])
  @ego_menu :battle_ego_resistances
  @ego_warning :battle_ego_warning
  @hover_label :enemy_target_hovering_label

  def play_chain_turn(_last_frame, ctx), do: play_turn("chain", ctx)

  def play_focused_turn(_last_frame, ctx), do: play_turn("focused", ctx)

  def preview_target(enemy_pick, ctx) do
    Process.sleep(@preview_alt_tab_ms)

    with {:ok, _frame, tray} <- scan(ctx),
         {:ok, grab} <- skill_point(tray, 0, :bottom, ctx) do
      Ctx.log(ctx, :info, "playbook: previewing slot 1 (bottom skill) to the #{enemy_pick} enemy")
      {:ok, drag_to_enemy(grab, %{"pick" => enemy_pick}, ctx)}
    else
      :skip -> {:error, :skill_tray_not_readable}
    end
  end

  def preview_target_everyone(ctx) do
    Process.sleep(@preview_alt_tab_ms)

    with {:ok, _frame, %SkillTray{sinner_of_slot: [_ | _] = sinner_of_slot} = tray} <- scan(ctx) do
      results =
        sinner_of_slot
        |> Enum.with_index()
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Enum.sort()
        |> Enum.map(fn {sinner, columns} -> target_randomly(tray, sinner, columns, ctx) end)

      {outcome, _attempts} = List.last(results)
      {:ok, {outcome, Enum.flat_map(results, &elem(&1, 1))}}
    else
      _ -> {:error, :skill_tray_not_readable}
    end
  end

  defp target_randomly(tray, sinner, columns, ctx) do
    column = Enum.random(columns)
    row = Enum.random([:top, :bottom])
    percent = Enum.random(0..100)

    case skill_point(tray, column, row, ctx) do
      {:ok, grab} ->
        Ctx.log(ctx, :info, "playbook: sinner #{sinner + 1}: slot #{column + 1} (#{row} skill) to the enemy at #{percent}%")
        {outcome, attempts} = drag_to_enemy(grab, %{"pick" => "percent", "n" => percent}, ctx)
        Ctx.log(ctx, :info, "playbook: sinner #{sinner + 1}: #{inspect(outcome)}")
        {outcome, attempts}

      :skip ->
        {{:error, :slot_not_on_screen}, []}
    end
  end

  def new_battle(last_frame, ctx) do
    RunMemory.put_battle_turn(ctx, 1)
    {:ok, last_frame}
  end

  defp play_turn(kind, ctx) do
    turn = RunMemory.battle_turn(ctx)
    track = RunMemory.battle_track(ctx, kind)
    floor = if BattleStrategies.lux_track?(track), do: 1, else: RunMemory.floor(ctx)
    playbook = playbook(ctx, track, floor, kind)
    actions = playbook |> Resolver.phase_for(turn) |> Map.get("actions", []) |> order_actions()

    Ctx.log(
      ctx,
      :info,
      "playbook: #{track} F#{floor} turn #{turn} -> #{playbook["name"]} [#{Enum.map_join(actions, ", ", & &1["type"])}]"
    )

    scan = if Enum.any?(BattleStrategies.flatten_actions(actions), &needs_tray?/1), do: scan(ctx), else: :skip
    RunMemory.put(ctx, :target_panned?, false)

    with {:ok, state} <- run_actions(actions |> merge_keys() |> commit_trailing_damage_rate(), %{kind: kind, scan: scan}, ctx),
         :ok <- ensure_started(state, kind, ctx) do
      RunMemory.put_battle_turn(ctx, turn + 1)
      {:ok, nil}
    end
  end

  defp playbook(ctx, track, floor, kind) do
    case RunMemory.battle_strategy(ctx) |> Resolver.playbook_for(track, floor) do
      %{} = playbook ->
        playbook

      nil ->
        Ctx.log(ctx, :info, "playbook: nothing assigned to #{track} F#{floor}, using the #{kind} default")
        BattleStrategies.new_playbook(kind, "Default")
    end
  end

  defp needs_tray?(%{"type" => "if", "condition" => tree}), do: Enum.any?(Conditions.leaves(tree), &(BattleStrategies.sinner_leaf?(&1) or BattleStrategies.tray_leaf?(&1) or BattleStrategies.position_leaf?(&1)))
  defp needs_tray?(%{"type" => type}), do: type in ~w(dodge ego target chain_fast chain_a_res)

  defp order_actions(actions) do
    {terminal, rest} = Enum.split_with(actions, &BattleStrategies.terminal?/1)
    rest ++ Enum.take(terminal, 1)
  end

  defp merge_keys([%{"type" => "win_rate"}, %{"type" => "commit"} | rest]),
    do: [%{"type" => "win_rate_commit"} | merge_keys(rest)]

  defp merge_keys([%{"type" => "damage_rate"}, %{"type" => "commit"} | rest]),
    do: [%{"type" => "damage_rate_commit"} | merge_keys(rest)]

  defp merge_keys([action | rest]), do: [action | merge_keys(rest)]
  defp merge_keys([]), do: []

  defp commit_trailing_damage_rate(actions) do
    case List.last(actions) do
      %{"type" => "damage_rate"} -> List.replace_at(actions, -1, %{"type" => "damage_rate_commit"})
      _ -> actions
    end
  end

  defp run_actions([], _turn, _ctx), do: {:ok, :pending}

  defp run_actions([action | rest], turn, ctx) do
    with :ok <- guard(ctx) do
      case run_action(action, turn, ctx) do
        :pending ->
          run_actions(rest, turn, ctx)

        :started ->
          if rest != [], do: Ctx.log(ctx, :info, "playbook: turn started, skipping #{length(rest)} remaining action(s)")
          {:ok, :started}

        {:error, _} = error ->
          error
      end
    end
  end

  defp run_action(%{"type" => "if"} = block, turn, ctx) do
    branch = if condition_met?(block["condition"], turn.scan, ctx), do: "then", else: "else"
    actions = block[branch] |> order_actions() |> merge_keys()

    Ctx.log(
      ctx,
      :info,
      "playbook: if #{BattleStrategies.condition_label(block["condition"], profile_names())} -> #{branch} [#{Enum.map_join(actions, ", ", & &1["type"])}]"
    )

    case run_actions(actions, turn, ctx) do
      {:ok, state} -> state
      {:error, _} = error -> error
    end
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

    case Engine.goto(:battle_turn, target, ctx) do
      {:ok, _} -> {:error, :battle_left}
      {:error, _} = error -> error
    end
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

  defp run_action(%{"type" => "clear"}, _turn, ctx), do: clear(ctx, @clear_max_presses)

  defp run_action(%{"type" => "dodge"} = action, turn, ctx) do
    with {:ok, frame, tray} <- turn.scan,
         {:ok, columns} <- action_columns(action, frame, tray, profiles(), ctx) do
      Enum.each(columns, &click_dodge(tray, &1, ctx))
    end

    :pending
  end

  defp run_action(%{"type" => "ego"} = action, turn, ctx) do
    with {:ok, frame, tray} <- turn.scan,
         {:ok, columns} <- action_columns(action, frame, tray, profiles(), ctx) do
      Enum.each(columns, fn column ->
        with {:ok, point} <- slot_point(tray, column, ctx) do
          Ctx.log(ctx, :info, "playbook: #{action["grade"]} EGO#{if action["corrode"], do: " (corroded)"} on slot #{column + 1}")
          use_ego(point, action, ctx)
        end
      end)
    end

    :pending
  end

  defp run_action(%{"type" => "target"} = action, turn, ctx) do
    with {:ok, frame, tray} <- turn.scan,
         {:ok, columns} <- action_columns(action, frame, tray, profiles(), ctx) do
      Enum.each(columns, &target_or_dodge(resolve_row(action, &1, frame, tray, ctx), action, tray, &1, ctx))
    end

    :pending
  end

  defp run_action(%{"type" => chain_type} = action, turn, ctx) when chain_type in ~w(chain_fast chain_a_res) do
    with {:ok, frame, tray} <- turn.scan,
         {:ok, gear_rect} <- find_gear(frame, ctx),
         forced = forced_rows(action["pins"] || [], frame, tray, ctx),
         forced = dodge_forced(forced, tray, ctx),
         :ok <- BattleChain.drag(frame, tray, gear_rect, chain_type, forced, ctx) do
      if await(@turn_started, @turn_start_timeout_ms), do: :started, else: log_pending(ctx, "chain drag didn't start the turn")
    else
      {:error, reason} -> log_pending(ctx, "chain drag failed: #{inspect(reason)}")
      :skip -> :pending
    end
  end

  defp run_action(%{"type" => type}, _turn, ctx), do: log_pending(ctx, "unknown action #{inspect(type)}, skipping")

  defp target_or_dodge(:dodge, _action, tray, column, ctx), do: click_dodge(tray, column, ctx)

  defp target_or_dodge(row, action, tray, column, ctx) do
    with {:ok, grab} <- skill_point(tray, column, row, ctx) do
      Ctx.log(ctx, :info, "playbook: targeting enemy #{pick_text(action["enemy"])} with slot #{column + 1} (#{row} skill)")
      drag_to_enemy(grab, action["enemy"], ctx)
    end
  end

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
          Ctx.log(ctx, :info, "playbook: #{inspect(condition)} not reached, clicking battle_safe_click_spot and retrying")

          case Runner.run_steps([DSL.click(:battle_safe_click_spot), DSL.sleep(@key_gap_ms)], ctx) do
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

  defp clear(_ctx, 0), do: :pending

  defp clear(ctx, presses_left) do
    if await(:battle_combat_ready, 0) do
      press([:p], ctx)
      Process.sleep(@clear_settle_ms)
      clear(ctx, presses_left - 1)
    else
      :pending
    end
  end

  defp use_ego({sx, sy}, action, ctx) do
    Mouse.move_to(sx, sy)
    Mouse.mouse_down()
    opened? = await(@ego_menu, @ego_menu_timeout_ms)
    Mouse.mouse_up()

    if opened? do
      pick_ego_card(action, ctx)
    else
      Ctx.log(ctx, :error, "playbook: EGO menu didn't open, skipping")
    end
  end

  defp pick_ego_card(action, ctx) do
    hook = :"battle_ego_#{action["grade"]}"

    deadline = System.monotonic_time(:millisecond) + @ego_card_timeout_ms

    with {:ok, {x, _y, w, _h}} <- await_still_card(hook, nil, deadline),
         {:ok, %{region: {_wx, wy, _ww, wh}}} <- HookRegistry.find(@ego_warning),
         {:ok, {cx, cy}} <- Runner.to_screen_point({x + w / 2, wy + wh / 2}) do
      if action["corrode"], do: overclock(cx, cy, ctx)

      Mouse.click(cx, cy)
      Process.sleep(@ego_reclick_wait_ms)

      unless await(DSL.not_hook(@ego_menu), 0) do
        Ctx.log(ctx, :info, "playbook: EGO menu still open after the first click, clicking the card again")
        Mouse.click(cx, cy)
      end

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
    warned? = await(@ego_warning, @overclock_timeout_ms)
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

  defp condition_met?(nil, _scan, _ctx), do: true

  defp condition_met?(tree, scan, ctx) do
    case Capture.grab_frame() do
      {:ok, frame} ->
        leaves = Conditions.leaves(tree)
        sinners = if Enum.any?(leaves, &BattleStrategies.sinner_leaf?/1), do: sinner_count(scan, ctx)
        classified = if Enum.any?(leaves, &BattleStrategies.tray_leaf?/1), do: classify_scan(scan, ctx)
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
    cond do
      BattleStrategies.tray_leaf?(leaf) -> tray_count_leaf(leaf, tray_info, ctx)
      BattleStrategies.position_leaf?(leaf) -> position_leaf(leaf, tray_info, ctx)
      BattleStrategies.fight_leaf?(leaf) -> fight_leaf(leaf, ctx)
      not BattleStrategies.sinner_leaf?(leaf) -> hook_leaf(leaf, frame, ctx)
      is_nil(tray_info.sinners) -> false
      true -> BattleStrategies.sinner_count_matches?(leaf, tray_info.sinners)
    end
  end

  defp tray_count_leaf(_leaf, %{classified: nil}, _ctx), do: false

  defp tray_count_leaf(leaf, %{classified: classified, scan: {:ok, frame, tray}}, ctx) do
    columns =
      case leaf["profile_id"] do
        nil ->
          :all

        profile_id ->
          case action_columns(%{"who" => "only", "profile_ids" => [profile_id], "skill" => %{"pick" => "all"}}, frame, tray, profiles(), ctx) do
            {:ok, columns} -> columns
            :skip -> []
          end
      end

    count = BattleStrategies.tray_count(leaf, classified, columns)
    Ctx.log(ctx, :info, "playbook: #{BattleStrategies.condition_label(leaf, profile_names())} (counted #{count})")
    BattleStrategies.tray_count_matches?(leaf, count)
  end

  defp position_leaf(leaf, %{scan: {:ok, frame, %SkillTray{sinner_of_slot: [_ | _] = sinner_of_slot} = tray}}, ctx) do
    with {:ok, profile} <- fetch_profile(profiles(), leaf["profile_id"], ctx),
         {:ok, hook} <- locator_hook(profile, ctx),
         {:ok, column} <- locate(frame, tray, hook, profile, ctx) do
      index = Enum.at(sinner_of_slot, column)
      count = List.last(sinner_of_slot) + 1
      Ctx.log(ctx, :info, "playbook: #{BattleStrategies.condition_label(leaf, profile_names())} (#{profile.name} is sinner #{index + 1} of #{count})")
      BattleStrategies.position_matches?(leaf, index, count)
    else
      :skip ->
        Ctx.log(ctx, :info, "playbook: #{BattleStrategies.condition_label(leaf, profile_names())} can't be checked, treating it as false")
        false
    end
  end

  defp position_leaf(_leaf, _tray_info, _ctx), do: false

  defp fight_leaf(%{"op" => op}, ctx) do
    boss? = RunMemory.venue(ctx) == "md_boss"
    Ctx.log(ctx, :info, "playbook: #{if boss?, do: "boss fight", else: "not a boss fight"} (venue #{RunMemory.venue(ctx)})")
    boss? == (op == "boss_fight")
  end

  defp hook_leaf(%{"op" => op, "hook" => name}, frame, ctx) do
    case Enum.find(HookRegistry.all_names(), &(Atom.to_string(&1) == name)) do
      nil ->
        Ctx.log(ctx, :error, "playbook: condition hook #{inspect(name)} isn't loaded, treating it as false")
        false

      hook ->
        Runner.hook_matches?(frame, hook) == (op == "hook_on")
    end
  end

  defp drag_to_enemy({gx, gy}, enemy, ctx) do
    Mouse.move_to(gx, gy)
    Process.sleep(@skill_hover_ms)
    Mouse.mouse_down()

    settle = if RunMemory.get(ctx, :target_panned?, false), do: [], else: [DSL.sleep(@target_pan_settle_ms)]
    RunMemory.put(ctx, :target_panned?, true)

    try do
      case Runner.run_steps([DSL.move_to(:battle_safe_click_spot) | settle], ctx) do
        {:ok, _} -> aim(enemy, 1, nil, [], ctx)
        {:error, reason} -> {{:error, reason}, []}
      end
    after
      Mouse.mouse_up()
      Process.sleep(@target_release_settle_ms)
    end
  end

  defp aim(_enemy, attempt, _last_point, attempts, ctx) when attempt > @target_tries do
    Ctx.log(ctx, :error, "playbook: no enemy highlighted after #{@target_tries} tries, releasing at battle_safe_click_spot")
    Runner.run_steps([DSL.move_to(:battle_safe_click_spot)], ctx)
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

      case pick_enemy(BattleStrategies.filter_by_height(targets, enemy["height"]), enemy, attempt, ctx) do
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
    label =
      case Capture.grab_frame() do
        {:ok, frame} -> frame |> Matcher.find_all(@hover_label) |> Enum.find(&hover_label_for?(&1, point))
        {:error, _} -> nil
      end

    cond do
      label ->
        Ctx.log(ctx, :info, "playbook: hover label #{inspect(label)} under cursor #{inspect(point)}")
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

  defp pick_enemy(targets, %{"pick" => "first"}, _attempt, _ctx), do: {:ok, List.first(targets)}
  defp pick_enemy(targets, %{"pick" => "last"}, _attempt, _ctx), do: {:ok, List.last(targets)}

  defp pick_enemy(targets, %{"pick" => "percent", "n" => n}, _attempt, _ctx),
    do: {:ok, Enum.at(targets, BattleStrategies.percent_index(length(targets), n))}

  defp pick_enemy(targets, %{"pick" => "up_to", "n" => n}, _attempt, _ctx),
    do: {:ok, Enum.at(targets, min(n, length(targets)) - 1)}

  defp pick_enemy(targets, %{"pick" => "exact", "n" => n}, attempt, ctx) do
    case Enum.at(targets, n - 1) do
      nil ->
        Ctx.log(ctx, :info, "playbook: only #{length(targets)} enemy target(s) detected, wanted ##{n} (try #{attempt})")
        :skip

      target ->
        {:ok, target}
    end
  end

  defp pick_text(enemy), do: base_pick_text(enemy) <> BattleStrategies.height_label(enemy["height"])

  defp base_pick_text(%{"pick" => "percent", "n" => n}), do: "at #{n}%"
  defp base_pick_text(%{"pick" => pick, "n" => n}), do: "#{pick} #{n}"
  defp base_pick_text(%{"pick" => pick}), do: pick

  defp resolve_row(%{"row" => "priority"} = holder, column, frame, tray, ctx) do
    {top, bottom} = SinColor.classify_tray(frame.mat, tray)
    priority_row(holder, column, top, bottom, ctx)
  end

  defp resolve_row(%{"row" => "top"}, _column, _frame, _tray, _ctx), do: :top
  defp resolve_row(_holder, _column, _frame, _tray, _ctx), do: :bottom

  defp priority_row(holder, column, top, bottom, ctx) do
    top_cell = Enum.at(top, column)
    bottom_cell = Enum.at(bottom, column)
    row = BattleStrategies.pick_row(holder, top_cell, bottom_cell)

    Ctx.log(
      ctx,
      :info,
      "playbook: slot #{column + 1} #{BattleStrategies.row_label(holder)}: top #{BattleStrategies.cell_label(top_cell)}, bottom #{BattleStrategies.cell_label(bottom_cell)} -> #{row}"
    )

    row
  end

  defp skill_point(tray, column, row, ctx) do
    %{y: y, h: h} = skill_row = if row == :top, do: tray.top_row, else: tray.bottom_row
    {x0, x1} = skill_row |> SkillTray.row_columns() |> Enum.at(column)
    center_x = (x0 + x1) / 2
    toward_middle = if center_x < @screen_mid_x, do: 1, else: -1
    drop = if row == :top, do: 0, else: @bottom_skill_grab_drop_px
    point = {center_x + toward_middle * (x1 - x0) * @skill_grab_inward_pct, y + h * @skill_grab_depth_pct + drop}

    case Runner.to_screen_point(point) do
      {:ok, point} ->
        {:ok, point}

      {:error, reason} ->
        Ctx.log(ctx, :error, "playbook: can't map slot #{column + 1} to the screen: #{inspect(reason)}")
        :skip
    end
  end

  defp scan(ctx) do
    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, tray} <- SkillTray.scan(frame) do
      TrayWatch.record(frame)
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
        {:ok, point}

      {:error, reason} ->
        Ctx.log(ctx, :error, "playbook: can't map slot #{column + 1} to the screen: #{inspect(reason)}")
        :skip
    end
  end

  defp profiles, do: Map.new(SinnerProfiles.list(), &{&1.id, &1})

  defp profile_names, do: Map.new(SinnerProfiles.list(), &{&1.id, &1.name})

  defp forced_rows(pins, frame, tray, ctx) do
    profiles = profiles()
    classified = if Enum.any?(pins, &(&1["row"] == "priority")), do: SinColor.classify_tray(frame.mat, tray)

    Enum.reduce(pins, %{}, fn pin, acc ->
      case action_columns(pin, frame, tray, profiles, ctx) do
        {:ok, columns} ->
          Map.merge(acc, pin_rows(pin, columns, classified, ctx))

        :skip ->
          acc
      end
    end)
  end

  defp dodge_forced(forced, tray, ctx) do
    Map.new(forced, fn
      {column, :dodge} ->
        click_dodge(tray, column, ctx)
        {column, :bottom}

      entry ->
        entry
    end)
  end

  defp pin_rows(%{"row" => "priority"} = pin, columns, {top, bottom}, ctx) do
    rows = BattleStrategies.allocate_rows(pin, Enum.map(columns, &{&1, Enum.at(top, &1), Enum.at(bottom, &1)}))

    Enum.each(columns, fn column ->
      Ctx.log(
        ctx,
        :info,
        "playbook: slot #{column + 1} #{BattleStrategies.row_label(pin)}: top #{BattleStrategies.cell_label(Enum.at(top, column))}, bottom #{BattleStrategies.cell_label(Enum.at(bottom, column))} -> #{rows[column]}"
      )
    end)

    rows
  end

  defp pin_rows(%{"row" => "top"}, columns, _classified, _ctx), do: Map.new(columns, &{&1, :top})
  defp pin_rows(_pin, columns, _classified, _ctx), do: Map.new(columns, &{&1, :bottom})

  defp action_columns(%{"skill" => skill} = action, frame, tray, profiles, ctx) do
    with {:ok, groups} <- sinner_groups(action["who"], action["profile_ids"] || [], frame, tray, profiles, ctx) do
      groups
      |> Enum.map(fn {columns, who} -> pick_skill(columns, skill, frame, tray, who, ctx) end)
      |> Enum.flat_map(fn
        {:ok, columns} -> columns
        :skip -> []
      end)
      |> case do
        [] -> :skip
        columns -> {:ok, columns}
      end
    end
  end

  defp sinner_groups("everyone", _ids, _frame, tray, _profiles, _ctx) do
    who = %{name: "everyone"}
    {:ok, Enum.map(tray_groups(tray), &{&1, who})}
  end

  defp sinner_groups("except", ids, frame, tray, profiles, ctx) do
    with {:ok, excluded} <- located_groups(ids, frame, tray, profiles, "so everyone counts as not", ctx) do
      names = Enum.map_join(ids, ", ", &profiles[&1].name)
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
          names = Enum.map_join(ids, ", ", &profiles[&1].name)
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
             {:ok, hook} <- locator_hook(profile, ctx),
             {:ok, column} <- locate(frame, tray, hook, profile, ctx) do
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
           {:ok, hook} <- locator_hook(profile, ctx) do
        case Matcher.find_all(frame, hook) do
          [] ->
            Ctx.log(ctx, :info, "playbook: #{profile.name} not found in the skill tray, #{missing_note} #{profile.name}")
            {:cont, {:ok, acc}}

          rects ->
            {x, _y, w, _h} = Enum.min_by(rects, &elem(&1, 0))
            {:cont, {:ok, [SkillTray.owned_columns(tray, SkillTray.column_at(tray, x + w / 2)) | acc]}}
        end
      else
        :skip -> {:halt, :skip}
      end
    end)
  end

  defp tray_groups(tray) do
    tray.sinner_of_slot
    |> Enum.with_index()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  defp pick_skill(columns, %{"pick" => "first_with", "match" => match, "n" => n}, frame, tray, who, ctx),
    do: first_with(columns, match, n, frame, tray, who, ctx)

  defp pick_skill(columns, skill, _frame, _tray, who, ctx), do: pick_columns(columns, skill, who, ctx)

  defp first_with(columns, match, n, frame, tray, profile, ctx) do
    case BattleStrategies.first_with(columns, match, n, SinColor.classify_tray(frame.mat, tray)) do
      [] ->
        Ctx.log(ctx, :info, "playbook: #{profile.name} has no #{match} skill in the tray, skipping")
        :skip

      picked ->
        Ctx.log(ctx, :info, "playbook: #{profile.name} first #{n} #{match} skill(s) -> slot(s) #{Enum.map_join(picked, ", ", &(&1 + 1))}")
        {:ok, picked}
    end
  end

  defp fetch_profile(profiles, profile_id, ctx) do
    case Map.fetch(profiles, profile_id) do
      {:ok, profile} ->
        {:ok, profile}

      :error ->
        Ctx.log(ctx, :error, "playbook: sinner profile #{inspect(profile_id)} not found, skipping")
        :skip
    end
  end

  defp locator_hook(%{locator_hook: name} = profile, ctx) do
    case Enum.find(HookRegistry.all_names(), &(Atom.to_string(&1) == name)) do
      nil ->
        Ctx.log(ctx, :error, "playbook: #{profile.name} locator hook #{inspect(name)} isn't loaded, skipping")
        :skip

      hook ->
        {:ok, hook}
    end
  end

  defp locate(frame, tray, hook, profile, ctx) do
    case Matcher.find_all(frame, hook) do
      [] ->
        Ctx.log(ctx, :info, "playbook: #{profile.name} not found in the skill tray, skipping")
        :skip

      rects ->
        {x, _y, w, _h} = Enum.min_by(rects, &elem(&1, 0))
        column = SkillTray.column_at(tray, x + w / 2)

        if length(rects) > 1,
          do: Ctx.log(ctx, :info, "playbook: #{profile.name} matched #{length(rects)} times, using the leftmost (slot #{column + 1})")

        {:ok, column}
    end
  end

  defp pick_columns(columns, %{"pick" => "first"}, _profile, _ctx), do: {:ok, [List.first(columns)]}
  defp pick_columns(columns, %{"pick" => "last"}, _profile, _ctx), do: {:ok, [List.last(columns)]}
  defp pick_columns(columns, %{"pick" => "all"}, _profile, _ctx), do: {:ok, columns}

  defp pick_columns(columns, %{"pick" => "up_to", "n" => n}, _profile, _ctx),
    do: {:ok, [Enum.at(columns, min(n, length(columns)) - 1)]}

  defp pick_columns(columns, %{"pick" => "exact", "n" => n}, profile, ctx) do
    case Enum.at(columns, n - 1) do
      nil ->
        Ctx.log(ctx, :info, "playbook: #{profile.name} has #{length(columns)} skill(s), skill #{n} doesn't exist, skipping")
        :skip

      column ->
        {:ok, [column]}
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
