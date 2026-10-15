defmodule StarlightBot.Automation.PlaybookRunner do
  alias StarlightBot.Automation.{BattleChain, RunMemory, TrayWatch}
  alias StarlightBot.{BattleStrategies, Ctx, SinnerProfiles}
  alias StarlightBot.BattleStrategies.Resolver
  alias StarlightBot.Input.Mouse
  alias StarlightBot.Navigation.{DSL, Runner}
  alias StarlightBot.Vision.{Capture, HookRegistry, Matcher, SkillTray}

  @key_gap_ms 100
  @poll_ms 100
  @turn_start_timeout_ms 2_000
  @combat_ready_timeout_ms 3_000
  @focused_key_tries 3
  @clear_max_presses 4
  @clear_settle_ms 500
  @slot_click_settle_ms 300
  @ego_menu_timeout_ms 2_000
  @ego_menu_settle_ms 300
  @corrode_hold_ms 1_500
  @ego_close_timeout_ms 1_500

  @turn_started DSL.any_of([:battle_pause_button, DSL.not_hook(:battle_turn)])
  @ego_menu :battle_ego_resistances

  def play_chain_turn(_last_frame, ctx), do: play_turn("chain", ctx)

  def play_focused_turn(_last_frame, ctx), do: play_turn("focused", ctx)

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

    with {:ok, state} <- run_actions(merge_keys(actions), kind, ctx),
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

  defp order_actions(actions) do
    {chain, rest} = Enum.split_with(actions, &BattleStrategies.chain_action?(&1["type"]))
    rest ++ Enum.take(chain, 1)
  end

  defp merge_keys([%{"type" => "win_rate"}, %{"type" => "commit"} | rest]),
    do: [%{"type" => "win_rate_commit"} | merge_keys(rest)]

  defp merge_keys([action | rest]), do: [action | merge_keys(rest)]
  defp merge_keys([]), do: []

  defp run_actions([], _kind, _ctx), do: {:ok, :pending}

  defp run_actions([action | rest], kind, ctx) do
    with :ok <- guard(ctx) do
      case run_action(action, kind, ctx) do
        :pending ->
          run_actions(rest, kind, ctx)

        :started ->
          if rest != [], do: Ctx.log(ctx, :info, "playbook: turn started, skipping #{length(rest)} remaining action(s)")
          {:ok, :started}
      end
    end
  end

  defp run_action(%{"type" => "win_rate_commit"}, kind, ctx) do
    if press_until([:p, :enter], @turn_started, @turn_start_timeout_ms, kind, ctx), do: :started, else: :pending
  end

  defp run_action(%{"type" => "win_rate"}, kind, ctx) do
    press_until([:p], :battle_combat_ready, @combat_ready_timeout_ms, kind, ctx)
    :pending
  end

  defp run_action(%{"type" => "commit"}, _kind, ctx) do
    press([:enter], ctx)
    if await(@turn_started, @turn_start_timeout_ms), do: :started, else: log_pending(ctx, "enter didn't start the turn")
  end

  defp run_action(%{"type" => "clear"}, _kind, ctx), do: clear(ctx, @clear_max_presses)

  defp run_action(%{"type" => "dodge"} = action, _kind, ctx) do
    with {:ok, frame, tray} <- scan(ctx),
         {:ok, [column]} <- action_columns(action, frame, tray, profiles(), ctx),
         {:ok, {sx, sy}} <- slot_point(tray, column, ctx) do
      Ctx.log(ctx, :info, "playbook: dodge on slot #{column + 1}")
      Mouse.visual_click(sx, sy)
      Process.sleep(@slot_click_settle_ms)
    end

    :pending
  end

  defp run_action(%{"type" => "ego"} = action, _kind, ctx) do
    with {:ok, frame, tray} <- scan(ctx),
         {:ok, [column]} <- action_columns(action, frame, tray, profiles(), ctx),
         {:ok, point} <- slot_point(tray, column, ctx) do
      Ctx.log(ctx, :info, "playbook: #{action["grade"]} EGO#{if action["corrode"], do: " (corroded)"} on slot #{column + 1}")
      use_ego(point, action, ctx)
    end

    :pending
  end

  defp run_action(%{"type" => chain_type} = action, _kind, ctx) when chain_type in ~w(chain_fast chain_a_res) do
    with {:ok, frame, tray} <- scan(ctx),
         {:ok, gear_rect} <- find_gear(frame, ctx),
         forced = forced_rows(action["pins"] || [], frame, tray, ctx),
         :ok <- BattleChain.drag(frame, tray, gear_rect, chain_type, forced, ctx) do
      if await(@turn_started, @turn_start_timeout_ms), do: :started, else: log_pending(ctx, "chain drag didn't start the turn")
    else
      {:error, reason} -> log_pending(ctx, "chain drag failed: #{inspect(reason)}")
      :skip -> :pending
    end
  end

  defp run_action(%{"type" => type}, _kind, ctx), do: log_pending(ctx, "unknown action #{inspect(type)}, skipping")

  defp ensure_started(:started, _kind, _ctx), do: :ok

  defp ensure_started(:pending, kind, ctx) do
    if await(@turn_started, 0) do
      :ok
    else
      keys = if await(:battle_combat_ready, 0), do: [:enter], else: [:p, :enter]
      Ctx.log(ctx, :info, "playbook: turn not started yet, falling back to #{Enum.map_join(keys, " + ", &Atom.to_string/1)}")

      if press_until(keys, @turn_started, @turn_start_timeout_ms, kind, ctx),
        do: :ok,
        else: {:error, :turn_not_started}
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
      Process.sleep(@ego_menu_settle_ms)
      pick_ego_card(action, ctx)
    else
      Ctx.log(ctx, :error, "playbook: EGO menu didn't open, skipping")
    end
  end

  defp pick_ego_card(action, ctx) do
    hook = :"battle_ego_#{action["grade"]}"

    with {:ok, frame} <- Capture.grab_frame(),
         [_ | _] = cards <- Matcher.find_all(frame, hook),
         {x, y, w, h} = Enum.min_by(cards, &elem(&1, 0)),
         {:ok, {cx, cy}} <- Runner.to_screen_point({x + w / 2, y + h / 2}) do
      if action["corrode"] do
        Mouse.move_to(cx, cy)
        Mouse.mouse_down()
        Process.sleep(@corrode_hold_ms)
        Mouse.mouse_up()
        Process.sleep(@ego_menu_settle_ms)
      end

      Mouse.visual_click(cx, cy)

      unless await(DSL.not_hook(@ego_menu), @ego_close_timeout_ms) do
        close_ego_menu(ctx, "EGO choice didn't take (not enough resources?)")
      end
    else
      [] -> close_ego_menu(ctx, "no #{action["grade"]} EGO card found")
      {:error, reason} -> close_ego_menu(ctx, "EGO card pick failed: #{inspect(reason)}")
    end
  end

  defp close_ego_menu(ctx, reason) do
    Ctx.log(ctx, :error, "playbook: #{reason}, closing the EGO menu")
    Runner.run_steps([DSL.click(@ego_menu), DSL.sleep(@ego_menu_settle_ms)], ctx)
  end

  defp scan(ctx) do
    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, tray} <- SkillTray.scan(frame) do
      TrayWatch.record(frame)
      {:ok, frame, tray}
    else
      other ->
        Ctx.log(ctx, :error, "playbook: skill tray not readable (#{inspect(other)}), skipping action")
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

  defp forced_rows(pins, frame, tray, ctx) do
    profiles = profiles()

    Enum.reduce(pins, %{}, fn pin, acc ->
      case action_columns(pin, frame, tray, profiles, ctx) do
        {:ok, columns} ->
          row = if pin["row"] == "top", do: :top, else: :bottom
          Map.merge(acc, Map.new(columns, &{&1, row}))

        :skip ->
          acc
      end
    end)
  end

  defp action_columns(%{"profile_id" => profile_id, "skill" => skill}, frame, tray, profiles, ctx) do
    with {:ok, profile} <- fetch_profile(profiles, profile_id, ctx),
         {:ok, hook} <- locator_hook(profile, ctx),
         {:ok, column} <- locate(frame, tray, hook, profile, ctx) do
      pick_columns(SkillTray.owned_columns(tray, column), skill, profile, ctx)
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
