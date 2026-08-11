defmodule StarlightBotWeb.Live.BattleInspectorLive do
  use StarlightBotWeb, :live_view
  alias StarlightBot.Vision.{Capture, HookRegistry, Matcher, SinColor, SkillTray}

  @tmp_jpeg "/tmp/_starlight_battle_inspector.jpg"
  @tmp_cell_png "/tmp/_starlight_battle_inspector_cell.png"
  @palette ["#f87171", "#60a5fa", "#facc15", "#4ade80", "#c084fc", "#fb923c", "#22d3ee"]

  @tier_boundary_safe_margin 0.15
  @tier_boundary_red {239, 68, 68}
  @tier_boundary_green {34, 197, 94}
  @tier_boundary_neutral "#9ca3af"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:status, :idle)
     |> assign(:frame_b64, nil)
     |> assign(:battle_chain?, false)
     |> assign(:tray, nil)
     |> assign(:top_sins, nil)
     |> assign(:bottom_sins, nil)
     |> assign(:scan_error, nil)}
  end

  @impl true
  def handle_event("take_screenshot", _, socket) do
    case Capture.grab_frame() do
      {:ok, frame} ->
        case encode_jpeg(frame.mat) do
          {:ok, jpeg} ->
            b64 = Base.encode64(jpeg)
            scan = scan_battle(frame)

            {:noreply,
             socket
             |> assign(:status, :done)
             |> assign(:frame_b64, b64)
             |> assign(:battle_chain?, scan.battle_chain?)
             |> assign(:tray, scan.tray)
             |> assign(:top_sins, scan.top_sins)
             |> assign(:bottom_sins, scan.bottom_sins)
             |> assign(:scan_error, scan.error)
             |> push_event("load_battle_frame", %{data: b64, overlays: overlays(scan)})}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:status, :error)
             |> put_flash(:error, "Encode failed: #{inspect(reason)}")}
        end

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

  defp scan_battle(frame) do
    case Matcher.find(frame, :battle_chain) do
      :not_found ->
        %{battle_chain?: false, gear_rect: nil, tray: nil, top_sins: nil, bottom_sins: nil, error: nil}

      {:ok, gear_rect} ->
        case SkillTray.scan(frame) do
          {:ok, tray} ->
            %{
              battle_chain?: true,
              gear_rect: gear_rect,
              tray: tray,
              top_sins: classify_row_with_previews(frame.mat, tray.top_row),
              bottom_sins: classify_row_with_previews(frame.mat, tray.bottom_row),
              error: nil
            }

          :not_found ->
            %{
              battle_chain?: true,
              gear_rect: gear_rect,
              tray: nil,
              top_sins: nil,
              bottom_sins: nil,
              error: "battle_chain didn't re-match during the skill tray scan"
            }

          {:error, reason} ->
            %{battle_chain?: true, gear_rect: gear_rect, tray: nil, top_sins: nil, bottom_sins: nil, error: inspect(reason)}
        end
    end
  end

  defp classify_row_with_previews(mat, row) do
    tier_columns = SkillTray.row_columns(row)
    hue_columns = SkillTray.hue_scan_columns(row)
    results = SinColor.classify_row(mat, row)

    [results, tier_columns, hue_columns]
    |> Enum.zip()
    |> Enum.map(fn {result, {x0, x1}, {hx0, hx1}} ->
      hue_cell = Evision.Mat.roi(mat, {hx0, row.hue_scan_y, hx1 - hx0, row.h})
      tier_cell = Evision.Mat.roi(mat, {x0, row.y, x1 - x0, row.h})

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

  defp overlays(%{gear_rect: {x, y, w, h}, tray: nil}) do
    [gear_overlay(x, y, w, h)]
  end

  defp overlays(%{gear_rect: {x, y, w, h}, tray: tray, top_sins: top_sins, bottom_sins: bottom_sins}) do
    [gear_overlay(x, y, w, h) | tray_overlays(tray, top_sins, bottom_sins)]
  end

  defp gear_overlay(x, y, w, h) do
    %{type: "rect", x: x, y: y, w: w, h: h, color: "#4ade80", text: "gear", text_x: x, text_y: y - 6}
  end

  defp tray_overlays(%SkillTray{} = tray, top_sins, bottom_sins) do
    hp_strip = hp_strip_overlay(tray)
    top = row_overlays(tray.top_row, top_sins, "top row", "#38bdf8")
    bottom = row_overlays(tray.bottom_row, bottom_sins, "bottom row", "#fb7185")
    bounds = [tray_start_line(tray), tray_end_line(tray)]
    bins = bin_overlays(tray)
    Enum.reject([hp_strip | top ++ bottom ++ bounds ++ bins], &is_nil/1)
  end

  defp row_overlays(row, sins, label, color) do
    [row_band(row, label, color), hue_scan_band(row, color) | row_column_overlays(row, sins, color)]
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
      dashed: true,
      text: "hue scan",
      text_x: row.start_x,
      text_y: row.hue_scan_y + row.h + 12
    }
  end

  defp row_column_overlays(row, sins, color) do
    row
    |> SkillTray.row_columns()
    |> Enum.zip(sins)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{{x0, _x1}, sin_result}, i} ->
      swatch = bgr_to_hex(sin_result.reference.bgr)

      [
        %{type: "line", x1: x0, y1: row.y, x2: x0, y2: row.y + row.h, color: color},
        %{
          type: "label",
          text: "#{i} #{sin_result.sin} #{sin_result.tier} (#{Float.round(sin_result.confidence, 2)})",
          text_x: x0 + 4,
          text_y: row.y + row.h + 14,
          color: swatch
        }
      ]
    end)
  end

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
          text: "##{i} S#{sinner_id}#{marker}",
          text_x: div(x0 + x1, 2) - 20,
          text_y: 795,
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

  defp encode_jpeg(mat) do
    Evision.imwrite(@tmp_jpeg, mat)
    File.read(@tmp_jpeg)
  rescue
    e -> {:error, Exception.message(e)}
  end
end
