defmodule StarlightBot.Automation.Scripts.ThemePackSelector do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.{Engine, RunMemory}
  alias StarlightBot.Ctx
  alias StarlightBot.Navigation.Runner
  alias StarlightBot.ThemePackPlans.Resolver
  alias StarlightBot.Vision.{Capture, Frame, Matcher}
  alias StarlightBot.Input.Mouse
  alias StarlightBot.{Strategies, Teams, ThemePacks}

  @entry_settle_ms 1500
  @ready_poll_every_ms 300
  @ready_poll_tries 3
  @mode_switch_poll_tries 6
  @max_refresh_attempts 30
  @drag_offsets [{0, -100}, {50, -100}, {100, -100}]
  @drag_distance 500
  @drag_confirm_poll_tries 8
  @drag_confirm_poll_every_ms 250
  @scan_retry_tries 4
  @scan_retry_every_ms 400
  @refresh_hover_settle_ms 300

  @floor_hooks Enum.map(1..5, &:"theme_pack_floor_#{&1}")

  def run(team_id, ctx) do
    plan_data = fetch_plan_data(team_id)
    theme_packs = ThemePacks.list_theme_packs()

    with {:ok, frame} <- await_ready(ctx) do
      detect_and_update_floor(frame, ctx)
      floor = RunMemory.floor(ctx)
      mode = Resolver.mode_for_floor(plan_data["mode_schedule"] || [], floor)

      with {:ok, frame} <- ensure_mode(frame, mode, ctx) do
        select(frame, plan_data, theme_packs, mode, floor, ctx)
      end
    end
  end

  defp detect_and_update_floor(frame, ctx) do
    case Enum.find(@floor_hooks, &Runner.hook_matches?(frame, &1)) do
      nil -> :ok
      hook -> RunMemory.put_floor(ctx, floor_from_hook(hook))
    end
  end

  defp floor_from_hook(hook) do
    hook |> Atom.to_string() |> String.trim_leading("theme_pack_floor_") |> String.to_integer()
  end

  defp fetch_plan_data(team_id) do
    with %{theme_pack_plan_id: id} when is_integer(id) <- Teams.get_team(team_id),
         %{data: data} when is_map(data) <- Strategies.get(:theme_pack_plans, id) do
      data
    else
      _ -> %{"mode_schedule" => [], "packs" => %{}}
    end
  end

  defp await_ready(ctx) do
    Process.sleep(@entry_settle_ms)

    with {:ok, _frame} <- position_cursor_at_refresh(ctx) do
      poll_ready_and_refresh(@ready_poll_tries, ctx)
    end
  end

  defp poll_ready_and_refresh(tries_left, ctx) when tries_left <= 0 do
    Ctx.log(ctx, :error, "theme pack selector: gave up waiting for theme_pack_select_ready")
    {:error, :theme_pack_not_ready}
  end

  defp poll_ready_and_refresh(tries_left, ctx) do
    case Capture.grab_frame() do
      {:ok, frame} ->
        ready? = Runner.hook_matches?(frame, :theme_pack_select_ready)
        refresh? = Runner.hook_matches?(frame, :theme_pack_select_refresh)

        cond do
          ready? and refresh? ->
            {:ok, frame}

          ready? and tries_left <= 1 ->
            Ctx.log(ctx, :info, "theme pack selector: refresh button never matched — proceeding as if 0 refreshes")
            {:ok, frame}

          true ->
            Process.sleep(@ready_poll_every_ms)
            poll_ready_and_refresh(tries_left - 1, ctx)
        end

      {:error, _} ->
        Process.sleep(@ready_poll_every_ms)
        poll_ready_and_refresh(tries_left - 1, ctx)
    end
  end

  defp position_cursor_at_refresh(ctx) do
    with {:ok, _} <- Engine.act([move_to(:theme_pack_select_refresh)], ctx) do
      Process.sleep(@refresh_hover_settle_ms)
      Capture.grab_frame()
    end
  end

  defp await_ready_only(ctx) do
    Process.sleep(@entry_settle_ms)
    poll_hooks([:theme_pack_select_ready], @ready_poll_tries, ctx)
  end

  defp poll_hooks(hooks, tries_left, ctx) when tries_left <= 0 do
    Ctx.log(ctx, :error, "theme pack selector: gave up waiting for #{inspect(hooks)}")
    {:error, :theme_pack_not_ready}
  end

  defp poll_hooks(hooks, tries_left, ctx) do
    case Capture.grab_frame() do
      {:ok, frame} ->
        if Enum.all?(hooks, &Runner.hook_matches?(frame, &1)) do
          {:ok, frame}
        else
          Process.sleep(@ready_poll_every_ms)
          poll_hooks(hooks, tries_left - 1, ctx)
        end

      {:error, _} ->
        Process.sleep(@ready_poll_every_ms)
        poll_hooks(hooks, tries_left - 1, ctx)
    end
  end

  defp ensure_mode(frame, expected_mode, ctx) do
    if current_mode(frame) == expected_mode do
      {:ok, frame}
    else
      action = if expected_mode == "hard", do: :to_hard, else: :to_normal

      with {:ok, _} <- Engine.run_action(:theme_pack, action, ctx),
           {:ok, _} <- verify_mode(expected_mode, @mode_switch_poll_tries, ctx) do
        position_cursor_at_refresh(ctx)
      end
    end
  end

  defp current_mode(frame) do
    cond do
      Runner.hook_matches?(frame, :theme_pack_select_hard) -> "hard"
      Runner.hook_matches?(frame, :theme_pack_select_normal) -> "normal"
      true -> nil
    end
  end

  defp verify_mode(_expected_mode, tries_left, ctx) when tries_left <= 0 do
    Ctx.log(ctx, :error, "theme pack selector: mode switch didn't take")
    {:error, :mode_switch_failed}
  end

  defp verify_mode(expected_mode, tries_left, ctx) do
    case Capture.grab_frame() do
      {:ok, frame} ->
        if current_mode(frame) == expected_mode do
          {:ok, frame}
        else
          Process.sleep(@ready_poll_every_ms)
          verify_mode(expected_mode, tries_left - 1, ctx)
        end

      {:error, _} ->
        Process.sleep(@ready_poll_every_ms)
        verify_mode(expected_mode, tries_left - 1, ctx)
    end
  end

  defp select(frame, plan_data, theme_packs, mode, floor, ctx) do
    bonus = packs_with_priority(plan_data, theme_packs, mode, floor, "bonus")
    hunt = packs_with_priority(plan_data, theme_packs, mode, floor, "hunt")
    hunt = if hunt == [], do: packs_with_priority(plan_data, theme_packs, mode, floor, "fine"), else: hunt

    Ctx.log(ctx, :info, "theme pack selector: floor #{floor} (#{mode}) hunting for #{pack_names(hunt)}#{bonus_suffix(bonus)}")

    attempt(frame, bonus, hunt, theme_packs, plan_data, mode, floor, 0, ctx)
  end

  defp pack_names([]), do: "(none)"
  defp pack_names(packs), do: Enum.map_join(packs, ", ", & &1.name_en)

  defp bonus_suffix([]), do: ""
  defp bonus_suffix(bonus), do: "; bonus: #{pack_names(bonus)}"

  def packs_with_priority(plan_data, theme_packs, mode, floor, priority) do
    Enum.filter(theme_packs, fn pack ->
      Resolver.eligible_floors(pack, mode) != [] and
        Resolver.priority_at(plan_data, pack, mode, floor) == priority
    end)
  end

  defp all_unbanned(plan_data, theme_packs, mode, floor) do
    Enum.filter(theme_packs, fn pack ->
      Resolver.eligible_floors(pack, mode) != [] and
        Resolver.priority_at(plan_data, pack, mode, floor) != "banned"
    end)
  end

  defp attempt(_frame, _bonus, _hunt, _theme_packs, _plan_data, _mode, _floor, refreshes_used, ctx)
       when refreshes_used > @max_refresh_attempts do
    Ctx.log(ctx, :error, "theme pack selector: exceeded #{@max_refresh_attempts} refreshes — giving up")
    {:error, :refresh_limit_exceeded}
  end

  defp attempt(frame, bonus, hunt, theme_packs, plan_data, mode, floor, refreshes_used, ctx) do
    refresh_available? = Runner.hook_matches?(frame, :theme_pack_select_refresh)

    candidates =
      if refresh_available? do
        Enum.uniq_by(bonus ++ hunt, & &1.id)
      else
        Enum.uniq_by(bonus ++ hunt ++ all_unbanned(plan_data, theme_packs, mode, floor), & &1.id)
      end

    case scan_and_pick_with_retries(frame, candidates, plan_data, mode, floor, @scan_retry_tries, ctx) do
      {:ok, pack, rect} ->
        Ctx.log(ctx, :ok, "theme pack selector: selecting #{pack.name_en}")
        confirm(frame, rect, ctx)

      :none when refresh_available? ->
        Ctx.log(ctx, :info, "theme pack selector: nothing wanted shown, refreshing (#{refreshes_used + 1})")

        with {:ok, _} <- Engine.act([click(:theme_pack_select_refresh)], ctx),
             {:ok, next_frame} <- await_ready_only(ctx) do
          attempt(next_frame, bonus, hunt, theme_packs, plan_data, mode, floor, refreshes_used + 1, ctx)
        end

      :none ->
        Ctx.log(ctx, :info, "theme pack selector: nothing wanted and no refreshes left — using default pick")
        leave(ctx)
    end
  end

  defp scan_and_pick_with_retries(frame, candidates, plan_data, mode, floor, tries_left, ctx) do
    case scan_and_pick(frame, candidates, plan_data, mode, floor, ctx) do
      {:ok, _pack, _rect} = found ->
        found

      :none when tries_left > 1 ->
        Process.sleep(@scan_retry_every_ms)

        case Capture.grab_frame() do
          {:ok, next_frame} -> scan_and_pick_with_retries(next_frame, candidates, plan_data, mode, floor, tries_left - 1, ctx)
          {:error, _} -> scan_and_pick_with_retries(frame, candidates, plan_data, mode, floor, tries_left - 1, ctx)
        end

      :none ->
        :none
    end
  end

  defp scan_and_pick(frame, candidates, plan_data, mode, floor, ctx) do
    hook_by_pack = Map.new(candidates, &{&1, hook_atom(&1)}) |> Enum.reject(fn {_p, h} -> is_nil(h) end) |> Map.new()

    if map_size(hook_by_pack) == 0 do
      :none
    else
      results = Matcher.find_with_score_batch(frame, Map.values(hook_by_pack))
      log_scan_scores(hook_by_pack, results, ctx)

      matched_hooks =
        for {hook, {:ok, _score, {:ok, rect}}, _us} <- results, into: %{} do
          {hook, rect}
        end

      hook_by_pack
      |> Enum.filter(fn {_pack, hook} -> Map.has_key?(matched_hooks, hook) end)
      |> pick_winner(matched_hooks, plan_data, mode, floor)
    end
  end

  defp log_scan_scores(hook_by_pack, results, ctx) do
    score_by_hook = Map.new(results, fn {hook, result, _us} -> {hook, score_of(result)} end)

    summary =
      hook_by_pack
      |> Enum.map(fn {pack, hook} -> "#{pack.name_en}: #{format_score(score_by_hook[hook])}" end)
      |> Enum.join(", ")

    Ctx.log(ctx, :info, "theme pack selector: scan scores — #{summary}")
  end

  defp score_of({:ok, score, _match}), do: score
  defp score_of(_), do: nil

  defp format_score(nil), do: "n/a"
  defp format_score(score), do: :erlang.float_to_binary(score * 1.0, decimals: 3)

  defp hook_atom(pack) do
    case pack.hook_name do
      nil -> nil
      name -> safe_to_atom(name)
    end
  end

  defp safe_to_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  def pick_winner([], _matched_hooks, _plan_data, _mode, _floor), do: :none

  def pick_winner(matched_pairs, matched_hooks, plan_data, mode, floor) do
    by_priority = Enum.group_by(matched_pairs, fn {pack, _hook} -> Resolver.priority_at(plan_data, pack, mode, floor) end)

    winner =
      Enum.find_value(["bonus", "hunt", "fine"], fn priority ->
        case by_priority[priority] do
          [{pack, hook} | _] -> {pack, hook}
          _ -> nil
        end
      end)

    case winner do
      nil -> :none
      {pack, hook} -> {:ok, pack, Map.fetch!(matched_hooks, hook)}
    end
  end

  defp confirm(frame, {x, y, w, _h}, ctx) do
    cx = x + w / 2
    offsets = for {ddx, ddy} <- @drag_offsets, do: {cx + ddx, max(y + ddy, 0)}

    case try_offsets(offsets, frame, ctx) do
      :ok -> Engine.goto(:theme_pack, :dungeon_graph, ctx)
      :failed -> leave(ctx)
    end
  end

  defp try_offsets([], _frame, _ctx), do: :failed

  defp try_offsets([{sx, sy} | rest], frame, ctx) do
    from = Frame.to_screen_coords(frame, {sx, sy})
    to = Frame.to_screen_coords(frame, {sx, sy + @drag_distance})
    Mouse.drag(from, to)

    if await_moved_away(ctx) do
      :ok
    else
      try_offsets(rest, frame, ctx)
    end
  end

  defp await_moved_away(ctx), do: poll_gone(@drag_confirm_poll_tries, ctx)

  defp poll_gone(0, _ctx), do: false

  defp poll_gone(tries_left, ctx) do
    case Capture.grab_frame() do
      {:ok, frame} ->
        if Runner.hook_matches?(frame, :theme_pack_select) do
          Process.sleep(@drag_confirm_poll_every_ms)
          poll_gone(tries_left - 1, ctx)
        else
          true
        end

      {:error, _} ->
        Process.sleep(@drag_confirm_poll_every_ms)
        poll_gone(tries_left - 1, ctx)
    end
  end

  defp leave(ctx), do: Engine.goto(:theme_pack, :dungeon_graph, ctx)
end
