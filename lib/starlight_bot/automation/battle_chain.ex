defmodule StarlightBot.Automation.BattleChain do
  alias StarlightBot.Automation.ChainStreak
  alias StarlightBot.Ctx
  alias StarlightBot.Input.Mouse
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
         {picks, _top_results, _bottom_results} = compute_picks(frame, tray, "chain_fast", %{}),
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
    with {:ok, {sx, sy}} <- Runner.to_screen_point({gx + gw / 2, gy + gh / 2}) do
      Mouse.move_to(sx, sy)
      Mouse.mouse_down()
      Process.sleep(@preview_settle_ms)
      Mouse.mouse_up()
      :ok
    end
  end

  @spec drag(term, SkillTray.t(), {number, number, number, number}, String.t(), %{non_neg_integer => :top | :bottom}, Ctx.t()) ::
          :ok | {:error, term}
  def drag(frame, tray, {gx, gy, gw, gh}, chain_type, forced, ctx) do
    {picks, top_results, bottom_results} = compute_picks(frame, tray, chain_type, forced)
    log_skill_tray(ctx, top_results, bottom_results)
    path = build_path({gx + gw / 2, gy + gh / 2}, picks, release_point(tray))

    with {:ok, path_screens} <- to_screen_points(path) do
      Ctx.log(ctx, :info, "battle_chain: dragging #{chain_type} across #{tray.skill_num} slot(s)")
      run_drag(path_screens)
      :ok
    end
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

  defp run_drag([{gx, gy} | rest]) do
    Mouse.move_to(gx, gy, duration_mult: @chain_duration_mult)
    Mouse.mouse_down()
    Enum.each(rest, fn {x, y} -> Mouse.move_to(x, y, duration_mult: @chain_duration_mult) end)
    Mouse.mouse_up()
  end

  defp to_screen_points(points) do
    Enum.reduce_while(points, {:ok, []}, fn {x, y}, {:ok, acc} ->
      case Runner.to_screen_point({x, y}) do
        {:ok, point} -> {:cont, {:ok, [point | acc]}}
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

  defp compute_picks(frame, tray, chain_type, forced) do
    {top_results, bottom_results} = SinColor.classify_tray(frame.mat, tray)

    picks =
      case chain_type do
        "chain_a_res" ->
          waypoints_by_streak(tray, Enum.map(top_results, & &1.sin), Enum.map(bottom_results, & &1.sin), forced)

        _ ->
          waypoints(
            tray,
            Enum.map(top_results, &{&1.tier, &1.tier_margin}),
            Enum.map(bottom_results, &{&1.tier, &1.tier_margin}),
            forced
          )
      end

    {picks, top_results, bottom_results}
  end

  defp log_skill_tray(ctx, top_results, bottom_results) do
    text =
      [
        "battle_chain: skill tray read (#{length(top_results)} column(s))",
        format_skill_row("top", top_results),
        format_skill_row("bottom", bottom_results)
      ]
      |> Enum.join("\n")

    Ctx.log(ctx, :info, text)
  end

  defp format_skill_row(label, results) do
    cells =
      results
      |> Enum.with_index(1)
      |> Enum.map(fn {r, i} -> "#{i}:#{r.sin}/#{r.tier}" end)
      |> Enum.join("  ")

    "  #{String.pad_trailing(label, 6)} #{cells}"
  end

  @type scored_tier :: {SinColor.tier(), float}

  @spec waypoints(SkillTray.t(), [scored_tier], [scored_tier], %{non_neg_integer => :top | :bottom}) ::
          [{:top | :bottom, number, number}]
  def waypoints(%SkillTray{} = tray, top_skills, bottom_skills, forced \\ %{}) do
    top_skills
    |> Enum.zip(bottom_skills)
    |> steady_rows(forced)
    |> Enum.zip(SkillTray.chain_grid(tray))
    |> Enum.map(fn {row_choice, {x, top_y, bottom_y}} ->
      y = if row_choice == :top, do: top_y, else: bottom_y
      {row_choice, x, y}
    end)
  end

  defp steady_rows([], _forced), do: []

  defp steady_rows(columns, forced) do
    columns
    |> Enum.with_index()
    |> Enum.reduce(%{start: {{0, 0, 0.0}, []}}, fn {{top_skill, bottom_skill}, index}, paths ->
      rows = if row = Map.get(forced, index), do: [row], else: [:bottom, :top]

      Map.new(rows, fn row ->
        {tier, margin} = if row == :top, do: top_skill, else: bottom_skill

        best =
          paths
          |> Enum.map(fn {prev_row, {{ranks, switches, margins}, picked}} ->
            switched = if prev_row in [:start, row], do: 0, else: 1
            {{ranks + tier_rank(tier), switches + switched, margins + margin}, [row | picked], prev_row == :top}
          end)
          |> Enum.min_by(fn {cost, _picked, from_top?} -> {cost, from_top?} end)
          |> Tuple.delete_at(2)

        {row, best}
      end)
    end)
    |> Enum.min_by(fn {row, {cost, _picked}} -> {cost, row == :top} end)
    |> elem(1)
    |> elem(1)
    |> Enum.reverse()
  end

  @spec waypoints_by_streak(SkillTray.t(), [SinColor.sin()], [SinColor.sin()], %{non_neg_integer => :top | :bottom}) ::
          [{:top | :bottom, number, number}]
  def waypoints_by_streak(%SkillTray{} = tray, top_sins, bottom_sins, forced \\ %{}) do
    top_sins
    |> ChainStreak.best_path(bottom_sins, forced)
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
