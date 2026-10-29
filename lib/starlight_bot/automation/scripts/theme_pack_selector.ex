defmodule StarlightBot.Automation.Scripts.ThemePackSelector do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.{Engine, RunMemory}
  alias StarlightBot.Ctx
  alias StarlightBot.Navigation.Runner
  alias StarlightBot.PackPlans.Resolver
  alias StarlightBot.Vision.{Capture, Frame, HookRegistry, Matcher}
  alias StarlightBot.Input.Mouse
  alias StarlightBot.{Plans, Teams, ThemePacks}

  @mode_poll_budget_ms 400
  @ready_poll_every_ms 100
  @ready_poll_tries 10
  @mode_switch_poll_tries 6
  @refresh_drop_budget_ms 1500
  @refresh_drop_poll_every_ms 50
  @refresh_ready_poll_tries 20
  @max_refresh_attempts 10
  @drag_x_offsets [20, 60, 100]
  @pull_y 540
  @drag_distance 450
  @drag_confirm_poll_tries 15
  @drag_confirm_poll_every_ms 100
  @scan_poll_every_ms 100
  @scan_budget_ms 1500
  @refresh_hover_settle_ms 200
  @search_poll_every_ms 100
  @search_poll_tries 20
  @search_icon_poll_tries 20
  @search_scroll_steps 16
  @search_row_size 5
  @search_row_clicks 9
  @search_bottom_steps 3
  @search_scroll_settle_ms 400
  @search_pack_poll_tries 50

  @floor_hooks Enum.map(15..1//-1, &:"theme_pack_floor_#{&1}")
  @base_pack_count 3
  @max_pack_count 5
  @pack_count_graces [0, 2, 9]
  @base_refreshes 1
  @interstellar_travel 2
  @interstellar_refresh_bonus 2
  @perfected_possibility 9

  def run(team_id, ctx) do
    team = Teams.get_team(team_id)
    plan_data = team |> fetch_plan_data() |> Resolver.with_mode_override(team_override(ctx, :mode_override)) |> Resolver.with_search_override(team_override(ctx, :search_override))
    grace_picks = team[:grace_picks] || []
    theme_packs = ThemePacks.list_plannable_theme_packs()

    with {:ok, frame} <- enter(plan_data, ctx) do
      detect_and_update_floor(frame, ctx)
      floor = RunMemory.floor(ctx)
      if floor == 1, do: RunMemory.put(ctx, :visited_packs, [])
      limits = %{packs: expected_pack_count(grace_picks), refreshes: refresh_budget(grace_picks), exit_to: exit_screen(grace_picks, floor)}
      mode = scheduled_mode(plan_data, ctx)

      with {:ok, frame} <- ensure_mode(frame, mode, ctx) do
        RunMemory.put_mode(ctx, mode)
        select(frame, plan_data, theme_packs, mode, floor, limits, ctx)
      end
    end
  end

  defp scheduled_mode(plan_data, ctx) do
    Resolver.mode_for_floor(plan_data["mode_schedule"] || [], RunMemory.floor(ctx))
  end

  defp enter(plan_data, ctx) do
    Engine.act([premove(:theme_pack_select_refresh)], ctx)
    case poll_mode_frame(System.monotonic_time(:millisecond) + @mode_poll_budget_ms) do
      {:ok, frame} ->
        detect_and_update_floor(frame, ctx)
        mode = scheduled_mode(plan_data, ctx)

        if current_mode(frame) == mode do
          poll_hooks([:theme_pack_select_ready], @ready_poll_tries, ctx)
        else
          with {:ok, _frame} <- ensure_mode(frame, mode, ctx), do: await_ready_only(ctx)
        end

      :timeout ->
        poll_hooks([:theme_pack_select_ready], @ready_poll_tries, ctx)
    end
  end

  defp poll_mode_frame(deadline) do
    with {:ok, frame} <- Capture.grab_frame(),
         mode when not is_nil(mode) <- current_mode(frame) do
      {:ok, frame}
    else
      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(@ready_poll_every_ms)
          poll_mode_frame(deadline)
        end
    end
  end

  defp detect_and_update_floor(frame, ctx) do
    case Enum.find(@floor_hooks, &Runner.hook_matches?(frame, &1)) do
      nil -> :ok
      hook -> RunMemory.raise_floor(ctx, floor_from_hook(hook))
    end
  end

  defp floor_from_hook(hook) do
    hook |> Atom.to_string() |> String.trim_leading("theme_pack_floor_") |> String.to_integer()
  end

  def expected_pack_count(grace_picks) do
    bonus = Enum.count(grace_picks, &(grace_index(&1) in @pack_count_graces))
    min(@base_pack_count + bonus, @max_pack_count)
  end

  def refresh_budget(grace_picks) do
    case Enum.find(grace_picks, &(grace_index(&1) == @interstellar_travel)) do
      nil -> @base_refreshes
      pick -> @base_refreshes + @interstellar_refresh_bonus + grace_enhance(pick)
    end
  end

  def exit_screen(grace_picks, 1) do
    if Enum.any?(grace_picks, &(grace_index(&1) == @perfected_possibility)), do: :cabinet_reward, else: :dungeon_graph
  end

  def exit_screen(_grace_picks, _floor), do: :dungeon_graph

  defp grace_index(%{"index" => index}), do: index
  defp grace_index(index), do: index

  defp grace_enhance(%{"enhance" => enhance}) when enhance in [1, 2], do: enhance
  defp grace_enhance(_pick), do: 0

  defp team_override(ctx, key), do: ctx |> RunMemory.team() |> then(&(&1 && Map.get(&1, key)))

  defp fetch_plan_data(team) do
    with %{pack_plan_id: id} when is_integer(id) <- team,
         %{data: data} when is_map(data) <- Plans.get(:pack_plans, id) do
      data
    else
      _ -> %{"mode_schedule" => [], "packs" => %{}}
    end
  end

  defp position_cursor_at_refresh(ctx) do
    with {:ok, _} <- Engine.act([move_to(:theme_pack_select_refresh)], ctx) do
      Process.sleep(@refresh_hover_settle_ms)
      Capture.grab_frame()
    end
  end

  defp await_ready_only(ctx) do
    Engine.act([premove(:theme_pack_select_refresh)], ctx)
    poll_hooks([:theme_pack_select_ready], @ready_poll_tries, ctx)
  end

  defp await_refreshed(ctx) do
    clicked_at = System.monotonic_time(:millisecond)

    case poll_ready_drop(clicked_at + @refresh_drop_budget_ms) do
      :dropped ->
        with {:ok, frame} <- poll_hooks([:theme_pack_select_ready], @refresh_ready_poll_tries, ctx) do
          Ctx.log(ctx, :info, "theme pack selector: new packs ready #{System.monotonic_time(:millisecond) - clicked_at}ms after refresh")
          {:ok, frame}
        end

      :timeout ->
        Ctx.log(ctx, :info, "theme pack selector: ready never dropped within #{@refresh_drop_budget_ms}ms of refresh, scanning anyway")
        poll_hooks([:theme_pack_select_ready], @refresh_ready_poll_tries, ctx)
    end
  end

  defp poll_ready_drop(deadline) do
    case Capture.grab_frame() do
      {:ok, frame} ->
        cond do
          not Runner.hook_matches?(frame, :theme_pack_select_ready) -> :dropped
          System.monotonic_time(:millisecond) >= deadline -> :timeout
          true ->
            Process.sleep(@refresh_drop_poll_every_ms)
            poll_ready_drop(deadline)
        end

      {:error, _} ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(@refresh_drop_poll_every_ms)
          poll_ready_drop(deadline)
        end
    end
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

      with {:ok, _} <- Engine.run_action(:theme_pack, action, ctx) do
        verify_mode(expected_mode, @mode_switch_poll_tries, ctx)
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

  defp select(frame, plan_data, theme_packs, mode, floor, limits, ctx) do
    {favorites, others} =
      plan_data
      |> packs_with_priority(theme_packs, mode, floor, "hunt")
      |> Resolver.sort_hunt(plan_data, mode)
      |> Enum.split_with(&Resolver.favorite?(plan_data, &1.id, mode))

    {hunt, backup} = if favorites == [], do: {others, []}, else: {favorites, others}
    hunt = if hunt == [], do: packs_with_priority(plan_data, theme_packs, mode, floor, "fine"), else: hunt

    Ctx.log(ctx, :info, "theme pack selector: floor #{floor} (#{mode}) hunting for #{pack_names(hunt)}#{backup_suffix(backup)}, expecting #{limits.packs} packs and #{limits.refreshes} refreshes")

    attempt(frame, backup, hunt, theme_packs, plan_data, mode, floor, limits, 0, ctx)
  end

  defp pack_names([]), do: "(none)"
  defp pack_names(packs), do: Enum.map_join(packs, ", ", & &1.name_en)

  defp backup_suffix([]), do: ""
  defp backup_suffix(backup), do: "; backup: #{pack_names(backup)}"

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

  def floor_pool(theme_packs, mode, floor) do
    Enum.filter(theme_packs, &(floor in Resolver.eligible_floors(&1, mode)))
  end

  defp attempt(_frame, _backup, _hunt, _theme_packs, _plan_data, _mode, _floor, _limits, refreshes_used, ctx)
       when refreshes_used > @max_refresh_attempts do
    Ctx.log(ctx, :error, "theme pack selector: exceeded #{@max_refresh_attempts} refreshes — giving up")
    {:error, :refresh_limit_exceeded}
  end

  defp attempt(frame, backup, hunt, theme_packs, plan_data, mode, floor, limits, refreshes_used, ctx) do
    pool = floor_pool(theme_packs, mode, floor)
    wanted = Enum.filter(pool, &Resolver.extreme_override?(plan_data, &1.id, mode)) ++ hunt
    refresh_available? = refreshes_used < limits.refreshes
    target = unless refresh_available?, do: search_target(plan_data, theme_packs, mode, floor, RunMemory.visited_packs(ctx), &search_hook_ready?/1)

    unless refresh_available? do
      idle_hook = if target, do: :theme_pack_select_pack_search, else: :theme_pack_mouse_checkpoint
      Ctx.log(ctx, :info, "theme pack selector: last look (#{refreshes_used}/#{limits.refreshes} refreshes used), premoving to #{idle_hook}")
      Engine.act([premove(idle_hook)], ctx)
    end

    result =
      case scan_wanted(frame, wanted, pool, limits.packs, plan_data, mode, floor, ctx) do
        {:ok, _pack, _rect} = found ->
          found

        {:none, _last_frame} when refresh_available? or target != nil ->
          :none

        {:none, last_frame} ->
          fallback = Enum.uniq_by(wanted ++ backup ++ all_unbanned(plan_data, theme_packs, mode, floor), & &1.id)

          case scan_and_pick(last_frame, fallback, [], plan_data, mode, floor, ctx) do
            {:none, _seen} -> :none
            found -> found
          end
      end

    case result do
      {:ok, pack, rect} ->
        Ctx.log(ctx, :ok, "theme pack selector: selecting #{pack.name_en}")

        case confirm(frame, rect, pack, limits.exit_to, ctx) do
          :not_pulled when refresh_available? ->
            Ctx.log(ctx, :info, "theme pack selector: couldn't pull #{pack.name_en}, refreshing (#{refreshes_used + 1})")
            refresh_and_attempt(backup, hunt, theme_packs, plan_data, mode, floor, limits, refreshes_used, ctx)

          :not_pulled ->
            Ctx.log(ctx, :info, "theme pack selector: couldn't pull #{pack.name_en} and no refresh available, using default pick")
            leave(limits.exit_to, ctx)

          result ->
            result
        end

      :none when refresh_available? ->
        Ctx.log(ctx, :info, "theme pack selector: nothing wanted shown, refreshing (#{refreshes_used + 1})")
        refresh_and_attempt(backup, hunt, theme_packs, plan_data, mode, floor, limits, refreshes_used, ctx)

      :none when target != nil ->
        Ctx.log(ctx, :info, "theme pack selector: no refreshes left, searching for #{target.name_en}")

        case search_replace(target, ctx, length(pool), limits.exit_to) do
          {:error, {:search_failed, _reason}} ->
            Ctx.log(ctx, :info, "theme pack selector: rescanning theme packs after failed search")
            plan_without_search = Map.put(plan_data, "search_floors", [])

            case await_ready_only(ctx) do
              {:ok, next_frame} -> attempt(next_frame, backup, hunt, theme_packs, plan_without_search, mode, floor, limits, refreshes_used, ctx)
              {:error, _} -> leave(limits.exit_to, ctx)
            end

          result ->
            result
        end

      :none ->
        Ctx.log(ctx, :info, "theme pack selector: nothing wanted and no refreshes left — using default pick")
        leave(limits.exit_to, ctx)
    end
  end

  defp refresh_and_attempt(backup, hunt, theme_packs, plan_data, mode, floor, limits, refreshes_used, ctx) do
    with {:ok, _} <- Engine.act([click(:theme_pack_select_refresh)], ctx),
         {:ok, next_frame} <- await_refreshed(ctx) do
      attempt(next_frame, backup, hunt, theme_packs, plan_data, mode, floor, limits, refreshes_used + 1, ctx)
    end
  end

  def search_target(plan_data, theme_packs, mode, floor, visited_ids, search_hook_ready?) do
    if Resolver.searchable_floor?(floor) and floor in Map.get(plan_data, "search_floors", []) do
      hunt = plan_data |> packs_with_priority(theme_packs, mode, floor, "hunt") |> Resolver.sort_hunt(plan_data, mode)
      favorites = Enum.filter(hunt, &Resolver.favorite?(plan_data, &1.id, mode))
      candidates = if favorites == [], do: hunt, else: favorites

      Enum.find(candidates, &(&1.id not in visited_ids and search_hook_ready?.(&1)))
    end
  end

  defp search_hook_ready?(%{search_hook_name: name}) when is_binary(name) do
    with hook when not is_nil(hook) <- safe_to_atom(name),
         {:ok, %{gray_mat: gray_mat}} <- HookRegistry.find(hook) do
      Evision.Mat.shape(gray_mat) != {1, 1}
    else
      _ -> false
    end
  end

  defp search_hook_ready?(_pack), do: false

  def search_replace(pack, ctx, pane_packs \\ nil, exit_to \\ :dungeon_graph) do
    search_hook = safe_to_atom(pack.search_hook_name)
    sleeve_hook = hook_atom(pack)

    with {:ok, frame, icon} <- enable_pack_search(ctx),
         :ok <- open_search_popup(frame, icon, ctx),
         {:ok, _} <- Engine.act([move_to(:theme_pack_search_browser)], ctx),
         {:ok, frame, rect} <- scroll_to_pack(search_hook, scroll_plan(pane_packs), ctx),
         :ok <- commit_search(frame, rect, ctx),
         {:ok, {x, _y, w, _h}} <- poll_replaced_pack(sleeve_hook, @search_pack_poll_tries),
         :ok <- pull_replaced({x, w}, sleeve_hook, ctx) do
      RunMemory.add_visited_pack(ctx, pack.id)
      RunMemory.add_picked_pack(ctx, pack.name_en)
      Engine.goto(:theme_pack, exit_to, ctx)
    else
      {:error, reason} ->
        Ctx.log(ctx, :error, "theme pack selector: search for #{pack.name_en} failed (#{inspect(reason)})")
        Engine.act([reclick_until_gone(:theme_pack_search_popup_black_cancel, every: 500, tries: 10)], ctx)
        {:error, {:search_failed, reason}}
    end
  end

  defp enable_pack_search(ctx) do
    case poll_leftmost_refresh_icon(1) do
      {:ok, _frame, _icon} = found ->
        Ctx.log(ctx, :info, "theme pack selector: pack search already on")
        found

      {:error, :no_refresh_icons} ->
        enable_pack_search(2, ctx)
    end
  end

  defp enable_pack_search(clicks_left, ctx) do
    with {:ok, _} <- Engine.act([click(:theme_pack_select_pack_search, settle_ms: 50)], ctx) do
      clicked_at = System.monotonic_time(:millisecond)

      case poll_leftmost_refresh_icon(@search_icon_poll_tries) do
        {:error, :no_refresh_icons} when clicks_left > 1 ->
          Ctx.log(ctx, :info, "theme pack selector: no refresh icons, toggling pack search again")
          enable_pack_search(clicks_left - 1, ctx)

        {:ok, _frame, _icon} = found ->
          Ctx.log(ctx, :info, "theme pack selector: refresh icons after #{System.monotonic_time(:millisecond) - clicked_at}ms")
          found

        result ->
          result
      end
    end
  end

  defp poll_leftmost_refresh_icon(0), do: {:error, :no_refresh_icons}

  defp poll_leftmost_refresh_icon(tries_left) do
    with {:ok, frame} <- Capture.grab_frame(),
         [_ | _] = icons <- Matcher.find_all(frame, :theme_pack_refresh_icon) do
      {:ok, frame, Enum.min_by(icons, fn {x, _y, _w, _h} -> x end)}
    else
      _ ->
        Process.sleep(@search_poll_every_ms)
        poll_leftmost_refresh_icon(tries_left - 1)
    end
  end

  defp open_search_popup(frame, icon, ctx) do
    click_rect_center(frame, icon)

    case poll_hooks([:theme_pack_search_popup_black_cancel], @search_poll_tries, ctx) do
      {:ok, _frame} -> :ok
      {:error, _} -> {:error, :search_popup_not_open}
    end
  end

  def scroll_plan(nil), do: {0, @search_scroll_steps}

  def scroll_plan(pane_packs) do
    rows = div(pane_packs + @search_row_size - 1, @search_row_size)
    {max(rows - 2, 0), @search_bottom_steps}
  end

  defp scroll_to_pack(search_hook, {fast_steps, settle_steps}, ctx) do
    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, rect} <- Matcher.find(frame, search_hook) do
      {:ok, frame, rect}
    else
      _ when fast_steps == 0 and settle_steps == 0 ->
        {:error, :pack_not_in_search}

      _ ->
        with {:ok, _} <- Engine.act([scroll_down(@search_row_clicks)], ctx) do
          if fast_steps > 0 do
            scroll_to_pack(search_hook, {fast_steps - 1, settle_steps}, ctx)
          else
            Process.sleep(@search_scroll_settle_ms)
            scroll_to_pack(search_hook, {0, settle_steps - 1}, ctx)
          end
        end
    end
  end

  defp commit_search(frame, rect, ctx) do
    click_rect_center(frame, rect)

    steps =
      [click(:theme_pack_search_popup_black_confirm, settle_ms: 50)] ++
      confirm_enter(:theme_pack_search_popup_white_confirm)

    with {:ok, _} <- Engine.act(steps, ctx), do: :ok
  end

  defp poll_replaced_pack(nil, _tries_left), do: {:error, :no_sleeve_hook}
  defp poll_replaced_pack(_hook, 0), do: {:error, :replaced_pack_not_found}

  defp poll_replaced_pack(hook, tries_left) do
    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, rect} <- Matcher.find(frame, hook) do
      {:ok, rect}
    else
      _ ->
        Process.sleep(@ready_poll_every_ms)
        poll_replaced_pack(hook, tries_left - 1)
    end
  end

  defp pull_replaced(span, hook, ctx) do
    case try_pulls(@drag_x_offsets, span, hook, ctx) do
      :ok -> :ok
      :failed -> {:error, :replaced_drag_failed}
    end
  end

  defp click_rect_center(frame, {x, y, w, h}) do
    {sx, sy} = Frame.to_screen_coords(frame, {x + w / 2, y + h / 2})
    Mouse.click(sx, sy)
  end

  defp scan_wanted(frame, wanted, pool, pack_count, plan_data, mode, floor, ctx) do
    deadline = System.monotonic_time(:millisecond) + @scan_budget_ms
    scan_until(frame, wanted, pool, pack_count, %{}, deadline, plan_data, mode, floor, ctx)
  end

  defp scan_until(frame, wanted, pool, pack_count, seen, deadline, plan_data, mode, floor, ctx) do
    case scan_and_pick(frame, wanted, pool, plan_data, mode, floor, ctx) do
      {:ok, _pack, _rect} = found ->
        found

      {:none, frame_seen} ->
        seen = Map.merge(seen, frame_seen, fn _name, a, b -> max(a, b) end)

        cond do
          map_size(seen) >= pack_count ->
            Ctx.log(ctx, :info, "theme pack selector: #{map_size(seen)}/#{pack_count} packs seen and none wanted (#{format_seen(seen)}), skipping remaining polls")
            {:none, frame}

          System.monotonic_time(:millisecond) >= deadline ->
            Ctx.log(ctx, :info, "theme pack selector: scan budget spent with #{map_size(seen)}/#{pack_count} packs seen (#{format_seen(seen)})")
            {:none, frame}

          true ->
            Process.sleep(@scan_poll_every_ms)

            case Capture.grab_frame() do
              {:ok, next_frame} -> scan_until(next_frame, wanted, pool, pack_count, seen, deadline, plan_data, mode, floor, ctx)
              {:error, _} -> scan_until(frame, wanted, pool, pack_count, seen, deadline, plan_data, mode, floor, ctx)
            end
        end
    end
  end

  defp format_seen(seen) do
    seen
    |> Enum.sort()
    |> Enum.map_join(", ", fn {name, score} -> "#{name}: #{format_score(score)}" end)
  end

  defp scan_and_pick(frame, wanted, pool, plan_data, mode, floor, ctx) do
    hook_by_pack =
      Enum.uniq_by(wanted ++ pool, & &1.id)
      |> Map.new(&{&1, hook_atom(&1)})
      |> Enum.reject(fn {_p, h} -> is_nil(h) end)
      |> Map.new()

    if map_size(hook_by_pack) == 0 do
      {:none, %{}}
    else
      {scan_us, results} = :timer.tc(fn -> Matcher.find_with_score_batch(frame, Map.values(hook_by_pack)) end)
      wanted_ids = MapSet.new(wanted, & &1.id)
      log_scan_scores(Map.filter(hook_by_pack, fn {pack, _hook} -> pack.id in wanted_ids end), results, map_size(hook_by_pack), scan_us, ctx)

      matched_hooks =
        for {hook, {:ok, _score, {:ok, rect}}, _us} <- results, into: %{} do
          {hook, rect}
        end

      matched_scores =
        for {hook, {:ok, score, {:ok, _rect}}, _us} <- results, into: %{} do
          {hook, score}
        end

      matched_pairs = Enum.filter(hook_by_pack, fn {_pack, hook} -> Map.has_key?(matched_hooks, hook) end)

      matched_pairs
      |> Enum.filter(fn {pack, _hook} -> pack.id in wanted_ids end)
      |> pick_winner(matched_hooks, plan_data, mode, floor)
      |> case do
        :none -> {:none, Map.new(matched_pairs, fn {pack, hook} -> {pack.name_en, matched_scores[hook]} end)}
        found -> found
      end
    end
  end

  defp log_scan_scores(hook_by_pack, results, hook_count, scan_us, ctx) do
    score_by_hook = Map.new(results, fn {hook, result, _us} -> {hook, score_of(result)} end)

    summary =
      hook_by_pack
      |> Enum.map(fn {pack, hook} -> "#{pack.name_en}: #{format_score(score_by_hook[hook])}" end)
      |> Enum.join(", ")

    Ctx.log(ctx, :info, "theme pack selector: scan scores (#{hook_count} hooks, #{div(scan_us, 1000)}ms) — #{summary}")
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
    by_priority =
      Enum.group_by(matched_pairs, fn {pack, _hook} ->
        if Resolver.extreme_override?(plan_data, pack.id, mode), do: "override", else: Resolver.priority_at(plan_data, pack, mode, floor)
      end)

    rank = Resolver.hunt_rank(plan_data, mode)

    winner =
      cond do
        override = by_priority["override"] -> hd(override)
        hunt = by_priority["hunt"] -> Enum.min_by(hunt, fn {pack, _hook} -> rank.(pack.id) end)
        fine = by_priority["fine"] -> hd(fine)
        true -> nil
      end

    case winner do
      nil -> :none
      {pack, hook} -> {:ok, pack, Map.fetch!(matched_hooks, hook)}
    end
  end

  defp confirm(_frame, {x, _y, w, _h}, pack, exit_to, ctx) do
    hook = hook_atom(pack)

    case try_pulls(@drag_x_offsets, {x, w}, hook, ctx) do
      :ok -> pulled(pack, exit_to, ctx)
      :failed -> rescan_and_pull(pack, hook, exit_to, ctx)
    end
  end

  defp rescan_and_pull(pack, hook, exit_to, ctx) do
    Ctx.log(ctx, :info, "theme pack selector: pulls failed, rescanning for #{hook} with cursor at refresh")

    with {:ok, frame} <- position_cursor_at_refresh(ctx),
         {:ok, {x, _y, w, _h}} <- Matcher.find(frame, hook) do
      case try_pulls(@drag_x_offsets, {x, w}, hook, ctx) do
        :ok ->
          pulled(pack, exit_to, ctx)

        :failed ->
          Ctx.log(ctx, :info, "theme pack selector: pulls failed again after rescan")
          :not_pulled
      end
    else
      _ ->
        Ctx.log(ctx, :info, "theme pack selector: rescan missed #{hook}")
        :not_pulled
    end
  end

  defp pulled(pack, exit_to, ctx) do
    RunMemory.add_visited_pack(ctx, pack.id)
    RunMemory.add_picked_pack(ctx, pack.name_en)
    Engine.goto(:theme_pack, exit_to, ctx)
  end

  defp try_pulls([], _span, _hook, _ctx), do: :failed

  defp try_pulls([dx | rest], {x, w} = span, hook, ctx) do
    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, %{region: {_cx, cy, _cw, ch}}} <- HookRegistry.find(:theme_pack_mouse_checkpoint),
         {sx, sy} = Frame.to_screen_coords(frame, {x + w / 2, cy + ch / 2}),
         _ <- Mouse.move_to(sx, sy),
         {:ok, true_x} <- recheck_x(hook, x + w / 2, ctx),
         {:ok, frame} <- Capture.grab_frame() do
      from = Frame.to_screen_coords(frame, {true_x + dx, @pull_y})
      to = Frame.to_screen_coords(frame, {true_x + dx, @pull_y + @drag_distance})
      Mouse.drag(from, to, release_settle_ms: 200)

      if await_moved_away(ctx), do: :ok, else: try_pulls(rest, span, hook, ctx)
    else
      _ -> try_pulls(rest, span, hook, ctx)
    end
  end

  defp recheck_x(nil, expected_x, _ctx), do: {:ok, expected_x}

  defp recheck_x(hook, expected_x, ctx), do: recheck_x(hook, expected_x, @ready_poll_tries, ctx)

  defp recheck_x(hook, expected_x, 0, ctx) do
    Ctx.log(ctx, :info, "theme pack selector: lost #{hook} on recheck, pulling at x=#{round(expected_x)}")
    {:ok, expected_x}
  end

  defp recheck_x(hook, expected_x, tries_left, ctx) do
    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, {x, _y, w, _h}} <- Matcher.find(frame, hook) do
      true_x = x + w / 2
      if abs(true_x - expected_x) > 1, do: Ctx.log(ctx, :info, "theme pack selector: #{hook} moved from x=#{round(expected_x)} to x=#{round(true_x)}")
      {:ok, true_x}
    else
      _ ->
        Process.sleep(@ready_poll_every_ms)
        recheck_x(hook, expected_x, tries_left - 1, ctx)
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

  defp leave(exit_to, ctx), do: Engine.goto(:theme_pack, exit_to, ctx)
end
