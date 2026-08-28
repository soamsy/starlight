defmodule StarlightBot.Automation.BattleChain do
  alias StarlightBot.Ctx
  alias StarlightBot.Input.Mouse
  alias StarlightBot.Navigation.{DSL, Runner}
  alias StarlightBot.Vision.{Capture, Matcher, SinColor, SkillTray}

  @gear_hook :battle_chain
  @release_margin_px 80
  @alt_tab_delay_ms 2_000
  @preview_settle_ms 500

  @diagonal_x_bias 0.7
  @diagonal_y_lead_pct 0.2

  @spec select_and_commit(term, Ctx.t()) :: {:ok, term} | {:error, term}
  def select_and_commit(_last_frame, ctx) do
    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, gear_rect} <- Matcher.find(frame, @gear_hook),
         {:ok, tray} <- SkillTray.scan(frame) do
      drag_chain(frame, tray, gear_rect, ctx)
    else
      _ ->
        Ctx.log(ctx, :info, "battle_chain: skill tray not readable — falling back to p+enter")
        fallback(ctx)
    end
  end

  @spec preview_drag() ::
          {:ok, %{frame: term, tray: SkillTray.t(), picks: [{:top | :bottom, number, number}], path: [{number, number}]}}
          | {:error, term}
  def preview_drag do
    Process.sleep(@alt_tab_delay_ms)

    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, {gx, gy, gw, gh} = gear_rect} <- Matcher.find(frame, @gear_hook),
         {:ok, tray} <- SkillTray.scan(frame),
         {picks, _top_results, _bottom_results} = compute_picks(frame, tray),
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

  defp drag_chain(frame, tray, {gx, gy, gw, gh}, ctx) do
    {picks, top_results, bottom_results} = compute_picks(frame, tray)
    log_skill_tray(ctx, top_results, bottom_results)
    gear_point = {gx + gw / 2, gy + gh / 2}
    path = build_path(gear_point, picks, release_point(tray))

    with {:ok, path_screens} <- to_screen_points(path) do
      Ctx.log(ctx, :info, "battle_chain: dragging chain selection across #{tray.skill_num} slot(s)")
      run_drag(path_screens)
      Ctx.log(ctx, :ok, "battle_chain: chain selection committed")
      {:ok, nil}
    else
      {:error, reason} ->
        Ctx.log(ctx, :error, "battle_chain: #{inspect(reason)} — falling back to p+enter")
        fallback(ctx)
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
    Mouse.move_to(gx, gy)
    Mouse.mouse_down()
    Enum.each(rest, fn {x, y} -> Mouse.move_to(x, y) end)
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

  defp compute_picks(frame, tray) do
    bg_color = SinColor.background_color(frame.mat, SkillTray.background_region(tray))

    top_results =
      SinColor.classify_row(frame.mat, tray.top_row, bg_color.hue, bg_color.saturation, bg_color.value)

    bottom_results =
      SinColor.classify_row(frame.mat, tray.bottom_row, bg_color.hue, bg_color.saturation, bg_color.value)

    top_tiers = Enum.map(top_results, & &1.tier)
    bottom_tiers = Enum.map(bottom_results, & &1.tier)

    {waypoints(tray, top_tiers, bottom_tiers), top_results, bottom_results}
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

  @spec waypoints(SkillTray.t(), [SinColor.tier()], [SinColor.tier()]) :: [{:top | :bottom, number, number}]
  def waypoints(%SkillTray{} = tray, top_tiers, bottom_tiers) do
    top_tiers
    |> Enum.zip(bottom_tiers)
    |> Enum.zip(SkillTray.chain_grid(tray))
    |> Enum.map(fn {{top_tier, bottom_tier}, {x, top_y, bottom_y}} ->
      row_choice = pick_row(top_tier, bottom_tier)
      y = if row_choice == :top, do: top_y, else: bottom_y
      {row_choice, x, y}
    end)
  end

  @spec pick_row(SinColor.tier(), SinColor.tier()) :: :top | :bottom
  def pick_row(top_tier, bottom_tier) do
    if tier_rank(top_tier) < tier_rank(bottom_tier), do: :top, else: :bottom
  end

  defp tier_rank(:skill2), do: 0
  defp tier_rank(:skill1), do: 1
  defp tier_rank(:skill3), do: 2

  defp fallback(ctx) do
    Runner.run_steps([DSL.key(:p), DSL.sleep(100), DSL.key(:enter)], ctx)
  end
end
