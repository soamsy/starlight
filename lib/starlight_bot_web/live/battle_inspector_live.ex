defmodule StarlightBotWeb.Live.BattleInspectorLive do
  use StarlightBotWeb, :live_view
  alias StarlightBot.Automation.{BattleChain, PlaybookRunner, TrayWatch}
  alias StarlightBot.Ctx
  alias StarlightBot.Navigation.Navigator
  alias StarlightBot.Vision.{Capture, EnemyTargets, Frame, HookRegistry, Matcher, SinColor, SkillTray}

  @tmp_jpeg "/tmp/_starlight_battle_inspector.jpg"
  @tmp_chain_preview_jpeg "/tmp/_starlight_battle_inspector_chain_preview.jpg"
  @tmp_target_preview_jpeg "/tmp/_starlight_battle_inspector_target_preview.jpg"
  @tmp_cell_png "/tmp/_starlight_battle_inspector_cell.png"
  @palette ["#f87171", "#60a5fa", "#facc15", "#4ade80", "#c084fc", "#fb923c", "#22d3ee"]
  @sin_text_colors %{
    wrath: "#f87171",
    lust: "#fb923c",
    sloth: "#facc15",
    gluttony: "#a3e635",
    gloom: "#22d3ee",
    pride: "#60a5fa",
    envy: "#c084fc"
  }
  @chain_top_color "#38bdf8"
  @chain_bottom_color "#fb7185"

  @tier_boundary_safe_margin 0.15
  @tier_boundary_red {239, 68, 68}
  @tier_boundary_green {34, 197, 94}
  @tier_boundary_neutral "#9ca3af"

  @resume_countdown_ms 2_000

  @impl true
  def mount(_params, _session, socket) do
    tray_watch = TrayWatch.state()

    if connected?(socket) do
      Navigator.subscribe()
      if tray_watch.enabled?, do: TrayWatch.subscribe()
    end

    socket =
      socket
      |> assign(:nav, Navigator.status())
      |> assign(:watch_tray?, tray_watch.enabled?)
      |> assign(:last_watched_at, nil)
      |> assign(:resume_pending?, false)
      |> assign(:status, :idle)
      |> assign(:frame_b64, nil)
      |> assign(:battle_chain?, false)
      |> assign(:gear_hook, nil)
      |> assign(:tray, nil)
      |> assign(:top_sins, nil)
      |> assign(:bottom_sins, nil)
      |> assign(:bg_color, nil)
      |> assign(:bg_strip_b64, nil)
      |> assign(:scan_error, nil)
      |> assign(:chain_preview_status, :idle)
      |> assign(:chain_preview_ready?, false)
      |> assign(:chain_preview_error, nil)
      |> assign(:target_preview_status, :idle)
      |> assign(:target_preview_ready?, false)
      |> assign(:target_preview_outcome, nil)

    case {connected?(socket), tray_watch.latest} do
      {true, {frame, at}} -> {:ok, socket |> show_frame(frame) |> assign(:last_watched_at, at)}
      _ -> {:ok, socket}
    end
  end

  @impl true
  def handle_event("take_screenshot", _, socket) do
    case Capture.grab_frame() do
      {:ok, frame} ->
        {:noreply, show_frame(socket, frame)}

      {:error, :no_window} ->
        {:noreply,
         socket
         |> assign(:status, :error)
         |> put_flash(:error, "Game window not found. Start Limbus Company first.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:status, :error)
         |> put_flash(:error, "Screenshot failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("toggle_watch_tray", _, %{assigns: %{watch_tray?: true}} = socket) do
    TrayWatch.set_enabled(false)
    TrayWatch.unsubscribe()
    {:noreply, socket |> assign(:watch_tray?, false) |> assign(:last_watched_at, nil)}
  end

  def handle_event("toggle_watch_tray", _, socket) do
    TrayWatch.set_enabled(true)
    TrayWatch.subscribe()
    {:noreply, assign(socket, :watch_tray?, true)}
  end

  def handle_event("pause_run", _, socket) do
    Navigator.pause()
    {:noreply, socket}
  end

  def handle_event("resume_run", _, %{assigns: %{resume_pending?: true}} = socket), do: {:noreply, socket}

  def handle_event("resume_run", _, socket) do
    Process.send_after(self(), :resume_run, @resume_countdown_ms)
    {:noreply, assign(socket, :resume_pending?, true)}
  end

  def handle_event("preview_chain_drag", _, %{assigns: %{chain_preview_status: :running}} = socket) do
    {:noreply, socket}
  end

  def handle_event("preview_chain_drag", _, socket) do
    me = self()
    Task.Supervisor.start_child(StarlightBot.TaskSupervisor, fn -> send(me, {:chain_preview_result, BattleChain.preview_drag()}) end)

    {:noreply,
     socket
     |> assign(:chain_preview_status, :running)
     |> assign(:chain_preview_error, nil)}
  end

  def handle_event("preview_target", _, %{assigns: %{target_preview_status: :running}} = socket) do
    {:noreply, socket}
  end

  def handle_event("preview_target", %{"enemy" => enemy}, socket) when enemy in ~w(first last) do
    me = self()
    ctx = Ctx.new()
    Task.Supervisor.start_child(StarlightBot.TaskSupervisor, fn -> send(me, {:target_preview_result, PlaybookRunner.preview_target(enemy, ctx)}) end)

    {:noreply,
     socket
     |> assign(:target_preview_status, :running)
     |> assign(:target_preview_outcome, nil)}
  end

  def handle_event("preview_target_everyone", _, socket) do
    me = self()
    ctx = Ctx.new()
    Task.Supervisor.start_child(StarlightBot.TaskSupervisor, fn -> send(me, {:target_preview_result, PlaybookRunner.preview_target_everyone(ctx)}) end)

    {:noreply,
     socket
     |> assign(:target_preview_status, :running)
     |> assign(:target_preview_outcome, nil)}
  end

  @impl true
  def handle_info({:skill_tray_scanned, frame, at}, %{assigns: %{watch_tray?: true}} = socket) do
    {:noreply, socket |> show_frame(frame) |> assign(:last_watched_at, at)}
  end

  def handle_info({:skill_tray_scanned, _frame, _at}, socket), do: {:noreply, socket}

  def handle_info({:nav_state, nav}, socket), do: {:noreply, assign(socket, :nav, nav)}

  def handle_info(:resume_run, socket) do
    case socket.assigns.nav.run_kind do
      :mirror_dungeon -> Navigator.resume_mirror_dungeon()
      :luxcavation -> Navigator.resume_luxcavation()
      nil -> :ok
    end

    {:noreply, assign(socket, :resume_pending?, false)}
  end

  def handle_info({:chain_preview_result, {:ok, %{frame: frame, tray: tray, picks: picks, path: path}}}, socket) do
    case encode_jpeg(frame.mat, @tmp_chain_preview_jpeg) do
      {:ok, jpeg} ->
        b64 = Base.encode64(jpeg)

        {:noreply,
         socket
         |> assign(:chain_preview_status, :done)
         |> assign(:chain_preview_ready?, true)
         |> assign(:chain_preview_error, nil)
         |> push_event("load_chain_preview_frame", %{data: b64, overlays: chain_preview_overlays(tray, picks, path)})}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:chain_preview_status, :error)
         |> assign(:chain_preview_error, "Encode failed: #{inspect(reason)}")}
    end
  end

  def handle_info({:target_preview_result, {:ok, {outcome, attempts}}}, socket) do
    socket = socket |> assign(:target_preview_status, :done) |> assign(:target_preview_outcome, target_outcome_text(outcome, attempts))

    case List.last(attempts) do
      nil ->
        {:noreply, socket}

      %{frame: frame, targets: targets, chosen: chosen} ->
        case encode_jpeg(frame.mat, @tmp_target_preview_jpeg) do
          {:ok, jpeg} ->
            {:noreply,
             socket
             |> assign(:target_preview_ready?, true)
             |> push_event("load_target_preview_frame", %{data: Base.encode64(jpeg), overlays: enemy_target_overlays(targets, chosen)})}

          {:error, reason} ->
            {:noreply, assign(socket, :target_preview_outcome, "Encode failed: #{inspect(reason)}")}
        end
    end
  end

  def handle_info({:target_preview_result, {:error, reason}}, socket) do
    {:noreply, socket |> assign(:target_preview_status, :error) |> assign(:target_preview_outcome, inspect(reason))}
  end

  def handle_info({:chain_preview_result, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:chain_preview_status, :error)
     |> assign(:chain_preview_error, inspect(reason))}
  end

  defp show_frame(socket, frame) do
    case encode_jpeg(frame.mat) do
      {:ok, jpeg} ->
        b64 = Base.encode64(jpeg)
        scan = scan_battle(frame)

        socket
        |> assign(:status, :done)
        |> assign(:frame_b64, b64)
        |> assign(:battle_chain?, scan.battle_chain?)
        |> assign(:gear_hook, scan.gear_hook)
        |> assign(:tray, scan.tray)
        |> assign(:top_sins, scan.top_sins)
        |> assign(:bottom_sins, scan.bottom_sins)
        |> assign(:bg_color, scan.bg_color)
        |> assign(:bg_strip_b64, scan.bg_strip_b64)
        |> assign(:scan_error, scan.error)
        |> push_event("load_battle_frame", %{data: b64, overlays: overlays(scan) ++ enemy_target_overlays(EnemyTargets.find(frame), nil)})

      {:error, reason} ->
        socket
        |> assign(:status, :error)
        |> put_flash(:error, "Encode failed: #{inspect(reason)}")
    end
  end

  defp target_outcome_text({:highlighted, attempt}, _attempts), do: "highlighted on try #{attempt}"
  defp target_outcome_text(:gave_up, attempts), do: "gave up after #{length(attempts)} detection(s)"
  defp target_outcome_text({:error, reason}, _attempts), do: "stopped: #{inspect(reason)}"

  @enemy_target_color "#f472b6"
  @chosen_target_color "#4ade80"
  @enemy_zone_color "#38bdf8"

  defp enemy_target_overlays(targets, chosen) do
    targets
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {%EnemyTargets{point: {px, py} = point, icon: {ix, iy} = icon, zone: zone} = target, i} ->
      color = if target == chosen, do: @chosen_target_color, else: @enemy_target_color
      label = if target == chosen, do: "enemy #{i} (chosen)", else: "enemy #{i}"

      zone_overlays(zone, i) ++
        [
          %{type: "line", x1: ix, y1: iy, x2: px, y2: py, color: color, dashed: true},
          point_marker(icon, color, nil),
          point_marker(point, color, label)
        ]
    end)
  end

  defp zone_overlays(nil, _i), do: []

  defp zone_overlays({x, y, w, h}, i) do
    [%{type: "rect", x: x, y: y, w: w, h: h, color: @enemy_zone_color, dashed: true, text: "reserved #{i}", text_x: x + 4, text_y: y + 16}]
  end

  def run_label(:mirror_dungeon), do: "Mirror dungeon"
  def run_label(:luxcavation), do: "Luxcavation"

  defp chain_preview_overlays(tray, picks, path) do
    [
      chain_grid_line(tray.tray_start_x, tray.tray_end_x, tray.chain_top_y, @chain_top_color, "chain_top_y"),
      chain_grid_line(tray.tray_start_x, tray.tray_end_x, tray.chain_bottom_y, @chain_bottom_color, "chain_bottom_y")
    ] ++ path_line_overlays(path) ++ path_endpoint_overlays(path) ++ pick_overlays(picks)
  end

  defp chain_grid_line(start_x, end_x, y, color, label) do
    %{type: "line", x1: start_x, y1: y, x2: end_x, y2: y, color: color, dashed: true, text: label, text_x: start_x, text_y: y - 6}
  end

  @path_line_color "#facc15"

  defp path_line_overlays(path) do
    path
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{x1, y1}, {x2, y2}] ->
      %{type: "line", x1: round(x1), y1: round(y1), x2: round(x2), y2: round(y2), color: @path_line_color}
    end)
  end

  defp path_endpoint_overlays(path) do
    [point_marker(List.first(path), "#4ade80", "mouse down"), point_marker(List.last(path), "#f87171", "release")]
  end

  @pick_marker_half_px 6

  defp pick_overlays(picks) do
    Enum.with_index(picks, fn {row_choice, x, y}, i -> point_marker({x, y}, pick_color(row_choice), "##{i} #{row_choice}") end)
  end

  defp pick_color(:top), do: @chain_top_color
  defp pick_color(:bottom), do: @chain_bottom_color

  defp point_marker({x, y}, color, label) do
    %{
      type: "rect",
      x: round(x - @pick_marker_half_px),
      y: round(y - @pick_marker_half_px),
      w: @pick_marker_half_px * 2,
      h: @pick_marker_half_px * 2,
      color: color,
      text: label,
      text_x: round(x - @pick_marker_half_px),
      text_y: round(y - @pick_marker_half_px) - 6
    }
  end

  defp scan_battle(frame) do
    case detect_gear(frame) do
      :not_found ->
        %{
          battle_chain?: false,
          gear_hook: nil,
          gear_rect: nil,
          tray: nil,
          top_sins: nil,
          bottom_sins: nil,
          bg_region: nil,
          bg_color: nil,
          bg_strip_b64: nil,
          error: nil
        }

      {:ok, gear_hook, gear_rect} ->
        case SkillTray.scan(frame) do
          {:ok, tray} ->
            bg_region = SkillTray.background_region(tray)
            bg_color = SinColor.background_color(frame.mat, bg_region)

            %{
              battle_chain?: true,
              gear_hook: gear_hook,
              gear_rect: gear_rect,
              tray: tray,
              top_sins:
                classify_row_with_previews(frame.mat, tray.top_row, bg_color),
              bottom_sins:
                classify_row_with_previews(frame.mat, tray.bottom_row, bg_color),
              bg_region: bg_region,
              bg_color: bg_color,
              bg_strip_b64: encode_png_b64(Frame.crop(frame.mat, bg_region)),
              error: nil
            }

          :not_found ->
            %{
              battle_chain?: true,
              gear_hook: gear_hook,
              gear_rect: gear_rect,
              tray: nil,
              top_sins: nil,
              bottom_sins: nil,
              bg_region: nil,
              bg_color: nil,
              bg_strip_b64: nil,
              error: "#{gear_hook} didn't re-match during the skill tray scan"
            }

          {:error, reason} ->
            %{
              battle_chain?: true,
              gear_hook: gear_hook,
              gear_rect: gear_rect,
              tray: nil,
              top_sins: nil,
              bottom_sins: nil,
              bg_region: nil,
              bg_color: nil,
              bg_strip_b64: nil,
              error: inspect(reason)
            }
        end
    end
  end

  defp detect_gear(frame) do
    case Matcher.find(frame, :battle_chain) do
      {:ok, gear_rect} ->
        {:ok, :battle_chain, gear_rect}

      :not_found ->
        case Matcher.find(frame, :battle_focused) do
          {:ok, gear_rect} -> {:ok, :battle_focused, gear_rect}
          :not_found -> :not_found
        end
    end
  end

  defp classify_row_with_previews(mat, row, bg) do
    tier_columns = SkillTray.row_columns(row)
    hue_columns = SkillTray.hue_scan_columns(row)
    results = SinColor.classify_row(mat, row, bg.hue, bg.saturation, bg.value, bg.leak)

    [results, tier_columns, hue_columns]
    |> Enum.zip()
    |> Enum.map(fn {result, {x0, x1}, {hx0, hx1}} ->
      hue_cell = Frame.crop(mat, {hx0, row.hue_scan_y, hx1 - hx0, row.h})
      tier_cell = Frame.crop(mat, {x0, row.y, x1 - x0, row.h})

      %{
        sin: result.sin,
        confidence: result.confidence,
        reference: result.reference,
        tier: result.tier,
        tier_pct: result.tier_pct,
        hue_cell_b64: encode_png_b64(hue_cell),
        mask_b64: encode_png_b64(result.reference_mask),
        tier_cell_b64: encode_png_b64(tier_cell),
        wedge_b64: encode_png_b64(result.wedge_mask),
        tier_mask_b64: encode_png_b64(result.tier_mask)
      }
    end)
  end

  defp encode_png_b64(mat) do
    Evision.imwrite(@tmp_cell_png, mat)

    case File.read(@tmp_cell_png) do
      {:ok, bin} -> Base.encode64(bin)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp overlays(%{battle_chain?: false}), do: []

  defp overlays(%{gear_hook: gear_hook, gear_rect: {x, y, w, h}, tray: nil}) do
    [gear_overlay(x, y, w, h, gear_hook)]
  end

  defp overlays(%{
         gear_hook: gear_hook,
         gear_rect: {x, y, w, h},
         tray: tray,
         top_sins: top_sins,
         bottom_sins: bottom_sins,
         bg_region: bg_region,
         bg_color: bg_color
       }) do
    [
      gear_overlay(x, y, w, h, gear_hook),
      background_overlay(bg_region, bg_color) | tray_overlays(tray, top_sins, bottom_sins)
    ]
  end

  defp gear_overlay(x, y, w, h, gear_hook) do
    %{type: "rect", x: x, y: y, w: w, h: h, color: "#4ade80", text: to_string(gear_hook), text_x: x, text_y: y - 6}
  end

  defp background_overlay({x, y, w, h}, bg_color) do
    %{
      type: "rect",
      x: x,
      y: y,
      w: w,
      h: h,
      color: bgr_to_hex(bg_color.bgr),
      dashed: true,
      text: "bg sample (hue #{bg_color.hue}, sat #{bg_color.saturation}, val #{bg_color.value})",
      text_x: x,
      text_y: y - 6
    }
  end

  defp tray_overlays(%SkillTray{} = tray, top_sins, bottom_sins) do
    hp_strip = hp_strip_overlay(tray)
    top = row_overlays(tray.top_row, top_sins, "top row", "#38bdf8", tray.top_row.y - 22)
    bottom = row_overlays(tray.bottom_row, bottom_sins, "bottom row", "#fb7185", tray.bottom_row.hue_scan_y + tray.bottom_row.h + 12)
    bounds = [tray_start_line(tray), tray_end_line(tray)]
    bins = bin_overlays(tray)
    Enum.reject([hp_strip | top ++ bottom ++ bounds ++ bins], &is_nil/1)
  end

  defp row_overlays(row, sins, label, color, cell_label_y) do
    [row_band(row, label, color), hue_scan_band(row, color) | row_column_overlays(row, sins, color, cell_label_y)]
  end

  defp row_band(row, label, color) do
    %{
      type: "rect",
      x: row.start_x,
      y: row.y,
      w: row.end_x - row.start_x,
      h: row.h,
      color: color,
      dashed: true,
      text: label,
      text_x: row.start_x,
      text_y: row.y - 6
    }
  end

  defp hue_scan_band(%{hue_scan_y: y} = row, _color) when y == row.y, do: nil

  defp hue_scan_band(row, color) do
    %{
      type: "rect",
      x: row.start_x,
      y: row.hue_scan_y,
      w: row.end_x - row.start_x,
      h: row.h,
      color: color,
      dashed: true
    }
  end

  defp row_column_overlays(row, sins, color, cell_label_y) do
    row
    |> SkillTray.row_columns()
    |> Enum.zip(sins)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{{x0, _x1}, sin_result}, i} ->
      [
        %{type: "line", x1: x0, y1: row.y, x2: x0, y2: row.y + row.h, color: color},
        %{
          type: "label",
          text: "#{i} #{tier_label(sin_result.tier)} #{sin_result.sin}",
          text_x: x0 + 4,
          text_y: cell_label_y,
          color: Map.fetch!(@sin_text_colors, sin_result.sin),
          outline: true,
          font_px: 11
        }
      ]
    end)
  end

  defp tier_label(:skill1), do: "S1"
  defp tier_label(:skill2), do: "S2"
  defp tier_label(:skill3), do: "S3"

  defp bgr_to_hex({b, g, r}) do
    "#" <> hex2(r) <> hex2(g) <> hex2(b)
  end

  defp hex2(v) do
    v |> round() |> max(0) |> min(255) |> Integer.to_string(16) |> String.pad_leading(2, "0")
  end

  defp tier_pct_color(sin, pct) do
    case SinColor.tier_thresholds()[sin] do
      nil ->
        @tier_boundary_neutral

      {tier2_min_pct, tier3_min_pct} ->
        distance = distance_to_nearest_boundary(pct, tier2_min_pct, tier3_min_pct)
        closeness = min(distance / @tier_boundary_safe_margin, 1.0)
        lerp_color(@tier_boundary_red, @tier_boundary_green, closeness)
    end
  end

  defp distance_to_nearest_boundary(pct, tier2_min_pct, tier3_min_pct) do
    cond do
      pct < tier2_min_pct -> tier2_min_pct - pct
      pct < tier3_min_pct -> min(pct - tier2_min_pct, tier3_min_pct - pct)
      true -> pct - tier3_min_pct
    end
  end

  defp lerp_color({r1, g1, b1}, {r2, g2, b2}, t) do
    r = r1 + (r2 - r1) * t
    g = g1 + (g2 - g1) * t
    b = b1 + (b2 - b1) * t
    "#" <> hex2(r) <> hex2(g) <> hex2(b)
  end

  defp hp_strip_overlay(tray) do
    case HookRegistry.find(:battle_hp_finder) do
      {:ok, %{region: {_hx, hy, _hw, hh}}} ->
        %{
          type: "rect",
          x: tray.tray_start_x,
          y: hy,
          w: tray.tray_end_x - tray.tray_start_x,
          h: hh,
          color: "#facc15",
          dashed: true,
          text: "HP strip",
          text_x: tray.tray_start_x,
          text_y: hy - 6
        }

      _ ->
        nil
    end
  end

  defp tray_start_line(tray), do: bound_line(tray.tray_start_x, "tray start")
  defp tray_end_line(tray), do: bound_line(tray.tray_end_x, "tray end (mirror)")

  defp bound_line(x, text) do
    %{type: "line", x1: x, y1: 760, x2: x, y2: 1080, color: "#e879f9", text: text, text_x: x + 4, text_y: 775}
  end

  defp bin_overlays(%SkillTray{sinner_of_slot: nil}), do: []

  defp bin_overlays(%SkillTray{} = tray) do
    first_actions = first_action_bins(tray.sinner_of_slot)

    tray.sinner_of_slot
    |> Enum.with_index()
    |> Enum.flat_map(fn {sinner_id, i} ->
      x0 = round(tray.tray_start_x + tray.bin_width * i)
      x1 = round(tray.tray_start_x + tray.bin_width * (i + 1))
      color = Enum.at(@palette, rem(sinner_id, length(@palette)))
      marker = if MapSet.member?(first_actions, i), do: " ★", else: ""

      [
        %{type: "line", x1: x0, y1: 780, x2: x0, y2: 1000, color: color, dashed: true},
        %{
          type: "label",
          text: "id #{sinner_id}#{marker}",
          text_x: div(x0 + x1, 2) - 20,
          text_y: tray.sinner_action_y,
          color: color
        }
      ]
    end)
  end

  defp first_action_bins(sinner_of_slot) do
    sinner_of_slot
    |> Enum.with_index()
    |> Enum.filter(fn {sinner_id, i} -> i == 0 or sinner_id != Enum.at(sinner_of_slot, i - 1) end)
    |> MapSet.new(fn {_sinner_id, i} -> i end)
  end

  def format_row(row) do
    "y=#{row.y} h=#{row.h} hue_scan_y=#{row.hue_scan_y} x=#{round1(row.start_x)}..#{round1(row.end_x)} cols=#{row.columns} col_w=#{round1(row.bin_width)} cell_inset=#{round1(row.cell_inset_pct * 100)}%"
  end

  defp round1(v) when is_float(v), do: Float.round(v, 1)
  defp round1(v), do: v

  def row_column_pairs(%SkillTray{top_row: top_row, bottom_row: bottom_row}, top_sins, bottom_sins) do
    [SkillTray.row_columns(top_row), top_sins, SkillTray.row_columns(bottom_row), bottom_sins]
    |> Enum.zip()
    |> Enum.with_index()
    |> Enum.map(fn {{top_x, top_sin, bottom_x, bottom_sin}, i} ->
      %{index: i, top_x: top_x, top_sin: top_sin, bottom_x: bottom_x, bottom_sin: bottom_sin}
    end)
  end

  defp encode_jpeg(mat, path \\ @tmp_jpeg) do
    Evision.imwrite(path, mat)
    File.read(path)
  rescue
    e -> {:error, Exception.message(e)}
  end
end
