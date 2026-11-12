defmodule StarlightBot.Automation.BattleChain do
  alias StarlightBot.Automation.ChainStreak
  alias StarlightBot.Ctx
  alias StarlightBot.Input.{Leeway, Mouse, Trajectory}
  alias StarlightBot.Navigation.Runner
  alias StarlightBot.Vision.{Capture, Matcher, SinColor, SkillTray}

  @gear_hook :battle_chain
  @release_margin_px 80
  @alt_tab_delay_ms 2_000
  @preview_settle_ms 500

  @diagonal_x_bias 0.7
  @diagonal_y_lead_pct 0.2
  @chain_duration_mult 0.7

  @spec preview_drag() ::
          {:ok, %{frame: term, tray: SkillTray.t(), picks: [{:top | :bottom, number, number}], path: [{number, number}]}}
          | {:error, term}
  def preview_drag do
    Process.sleep(@alt_tab_delay_ms)

    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, {gx, gy, gw, gh} = gear_rect} <- Matcher.find(frame, @gear_hook),
         {:ok, tray} <- SkillTray.scan(frame),
         {picks, _top_results, _bottom_results} = compute_picks(frame, tray, "fast", %{}, nil, nil),
         path = build_path({gx + gw / 2, gy + gh / 2}, picks, release_point(tray)),
         :ok <- click_and_release(gear_rect) do
      case Capture.grab_frame() do
        {:ok, dragged_frame} -> {:ok, %{frame: dragged_frame, tray: tray, picks: picks, path: path}}
        {:error, _} = err -> err
      end
    else
      :not_found -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp click_and_release({gx, gy, gw, gh}) do
    with {:ok, point} <- Runner.to_screen_point({gx + gw / 2, gy + gh / 2}) do
      {sx, sy} = Leeway.click(point)
      Mouse.move_to(sx, sy)
      Mouse.mouse_down()
      Process.sleep(@preview_settle_ms)
      Mouse.mouse_up()
      :ok
    end
  end

  @spec drag(term, SkillTray.t(), {number, number, number, number}, String.t(), %{non_neg_integer => :top | :bottom}, Ctx.t(), keyword) ::
          :ok | {:error, term}
  def drag(frame, tray, {gx, gy, gw, gh}, mode, forced, ctx, opts \\ []) do
    defense = Keyword.get(opts, :defense_sins)
    {picks, top_results, bottom_results} = compute_picks(frame, tray, mode, forced, defense, Keyword.get(opts, :max_defenses))
    log_skill_tray(ctx, top_results, bottom_results, defense)
    click_defense(picks, Keyword.get(opts, :click_defense, fn _column -> :ok end))
    path = build_path({gx + gw / 2, gy + gh / 2}, picks, release_point(tray))

    {start, moves} = plan_moves(path)

    with {:ok, [start_screen | move_screens]} <- to_screen_points([start | Enum.map(moves, &elem(&1, 0))]) do
      Ctx.log(ctx, :info, "battle_chain: dragging chain #{mode} across #{tray.skill_num} slot(s)")
      {_, py} = start
      arcs = moves |> Enum.map_reduce(py, fn {{_x, y}, _ms}, prev_y -> {if(y == prev_y, do: arc_for(y, tray)), y} end) |> elem(0)
      run_drag(start_screen, Enum.zip([move_screens, Enum.map(moves, &elem(&1, 1)), arcs]))
      :ok
    end
  end

  @spec plan_moves([{number, number}]) :: {{number, number}, [{{number, number}, float}]}
  def plan_moves([start | rest]) do
    {_prev, moves} =
      Enum.reduce(rest, {start, []}, fn {_x, y} = point, {{_px, py} = prev, acc} ->
        ms = Trajectory.expected_duration_ms(distance(prev, point)) * @chain_duration_mult

        case acc do
          [{_last, last_ms, true} | older] when y == py -> {point, [{point, last_ms + ms, true} | older]}
          _ -> {point, [{point, ms, y == py} | acc]}
        end
      end)

    {start, moves |> Enum.reverse() |> Enum.map(fn {point, ms, _flat} -> {point, ms} end)}
  end

  defp distance({x0, y0}, {x1, y1}), do: :math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0))

  defp click_defense(picks, click) do
    picks
    |> Enum.with_index()
    |> Enum.each(fn
      {{:defense, _x, _y}, column} -> click.(column)
      _ -> :ok
    end)
  end

  defp build_path(gear_point, picks, release_point) do
    points = [gear_point | Enum.map(picks, fn {_row, x, y} -> {x, y} end)] ++ [release_point]
    expand_diagonals(points)
  end

  @spec expand_diagonals([{number, number}]) :: [{number, number}]
  def expand_diagonals([]), do: []

  def expand_diagonals([first | rest]) do
    {_last, points} =
      Enum.reduce(rest, {first, [first]}, fn {x, y} = point, {{px, py}, acc} ->
        acc = if y == py, do: acc, else: [{px + (x - px) * @diagonal_x_bias, py + (y - py) * @diagonal_y_lead_pct} | acc]
        {point, [point | acc]}
      end)

    Enum.reverse(points)
  end

  defp arc_for(y, tray) do
    cond do
      y == tray.chain_top_y -> :upper
      y == tray.chain_bottom_y -> :lower
      true -> nil
    end
  end

  defp run_drag({gx, gy}, moves) do
    Mouse.move_to(gx, gy, duration_mult: @chain_duration_mult)
    Mouse.mouse_down()
    Enum.each(moves, fn {{x, y}, ms, arc} -> Mouse.move_to(x, y, duration_override: ms, arc: arc) end)
    Mouse.mouse_up()
  end

  defp to_screen_points(points) do
    Enum.reduce_while(points, {:ok, []}, fn {x, y}, {:ok, acc} ->
      case Runner.to_screen_point({x, y}) do
        {:ok, point} -> {:cont, {:ok, [Leeway.click(point) | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp release_point(tray) do
    {tray.tray_end_x + @release_margin_px, tray.chain_top_y + 50}
  end

  defp compute_picks(frame, tray, mode, forced, defense, max_defenses) do
    {top_results, bottom_results} = SinColor.classify_tray(frame.mat, tray)

    picks =
      case mode do
        "a_res" ->
          waypoints_by_streak(tray, Enum.map(top_results, & &1.sin), Enum.map(bottom_results, & &1.sin), forced)

        "a_res_def" ->
          waypoints_by_streak(tray, Enum.map(top_results, & &1.sin), Enum.map(bottom_results, & &1.sin), forced, defense, max_defenses)

        _ ->
          waypoints(tray, Enum.map(top_results, & &1.tier), Enum.map(bottom_results, & &1.tier), forced)
      end

    {picks, top_results, bottom_results}
  end

  defp log_skill_tray(ctx, top_results, bottom_results, defense) do
    defense_rows = if defense, do: ["  defense " <> format_defense_row(defense)], else: []

    text =
      (["battle_chain: skill tray read (#{length(top_results)} column(s))", format_skill_row("top", top_results), format_skill_row("bottom", bottom_results)] ++
         defense_rows)
      |> Enum.join("\n")

    Ctx.log(ctx, :info, text)
  end

  defp format_defense_row(defense) do
    defense |> Enum.with_index(1) |> Enum.map_join("  ", fn {sin, i} -> "#{i}:#{sin || "?"}" end)
  end

  defp format_skill_row(label, results) do
    cells =
      results
      |> Enum.with_index(1)
      |> Enum.map(fn {r, i} -> "#{i}:#{r.sin}/#{r.tier}" end)
      |> Enum.join("  ")

    "  #{String.pad_trailing(label, 6)} #{cells}"
  end

  @spec waypoints(SkillTray.t(), [SinColor.tier()], [SinColor.tier()], %{non_neg_integer => :top | :bottom}) ::
          [{:top | :bottom, number, number}]
  def waypoints(%SkillTray{} = tray, top_skills, bottom_skills, forced \\ %{}) do
    top_skills
    |> Enum.zip(bottom_skills)
    |> pick_rows(forced)
    |> Enum.zip(SkillTray.chain_grid(tray))
    |> Enum.map(fn {row_choice, {x, top_y, bottom_y}} ->
      y = if row_choice == :top, do: top_y, else: bottom_y
      {row_choice, x, y}
    end)
  end

  defp pick_rows(columns, forced) do
    columns
    |> Enum.with_index()
    |> Enum.map(fn {{top_skill, bottom_skill}, index} ->
      Map.get(forced, index) || pick_row(top_skill, bottom_skill)
    end)
  end

  defp pick_row(:skill3, :skill3), do: :bottom

  defp pick_row(top_skill, bottom_skill) do
    if tier_rank(bottom_skill) < tier_rank(top_skill), do: :bottom, else: :top
  end

  @spec waypoints_by_streak(SkillTray.t(), [SinColor.sin()], [SinColor.sin()], %{non_neg_integer => :top | :bottom}, [SinColor.sin() | nil] | nil, non_neg_integer | nil) ::
          [{:top | :bottom | :defense, number, number}]
  def waypoints_by_streak(%SkillTray{} = tray, top_sins, bottom_sins, forced \\ %{}, defense \\ nil, max_defenses \\ nil) do
    top_sins
    |> ChainStreak.best_path(bottom_sins, forced, defense, max_defenses)
    |> Enum.zip(SkillTray.chain_grid(tray))
    |> Enum.map(fn {row_choice, {x, top_y, bottom_y}} ->
      y = if row_choice == :top, do: top_y, else: bottom_y
      {row_choice, x, y}
    end)
  end

  defp tier_rank(:skill2), do: 0
  defp tier_rank(:skill1), do: 1
  defp tier_rank(:skill3), do: 2
end
