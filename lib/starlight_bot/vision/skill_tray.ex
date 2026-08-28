defmodule StarlightBot.Vision.SkillTray do
  alias StarlightBot.Vision.{Frame, Matcher, HookRegistry}

  @screen_w 1920
  @hp_hook :battle_hp_finder

  @tray_left_offset 105
  @focused_tray_left_offset 73
  @est_bin_width 121

  @tray_end_inset 101

  @top_row_y 781
  @top_row_h 35
  @bottom_row_y 818
  @bottom_row_h 40

  @top_row_inset_def [15.5, 7.63, 18]
  @bottom_row_inset_def [24, 0.31, 0]

  @top_cell_inset_pct 0.14
  @bottom_cell_inset_pct 0.15

  @top_hue_scan_offset 0
  @bottom_hue_scan_offset 45

  @top_hue_inset_x_pct 0.1
  @bottom_hue_inset_x_pct 0.07

  @bg_strip_gap_above_top_row 60
  @bg_strip_h 20

  @chain_top_y_offset 100
  @chain_bottom_y_offset 200

  defstruct [
    :gear_start_x,
    :tray_start_x,
    :tray_end_x,
    :bin_width,
    :skill_num,
    :sinner_of_slot,
    :top_row,
    :bottom_row,
    :chain_top_y,
    :chain_bottom_y
  ]

  @type row :: %{
          y: integer,
          h: integer,
          hue_scan_y: integer,
          start_x: integer,
          end_x: integer,
          bin_width: float,
          columns: pos_integer,
          cell_inset_pct: float,
          hue_inset_x_pct: float
        }

  @type t :: %__MODULE__{
          gear_start_x: integer,
          tray_start_x: integer,
          tray_end_x: integer,
          bin_width: float,
          skill_num: pos_integer,
          sinner_of_slot: [non_neg_integer] | nil,
          top_row: row,
          bottom_row: row,
          chain_top_y: integer,
          chain_bottom_y: integer
        }

  @spec scan(Frame.t()) :: {:ok, t()} | :not_found | {:error, term()}
  def scan(%Frame{} = frame) do
    case Matcher.find(frame, :battle_chain) do
      {:ok, {x, _y, w, _h}} -> scan_gear(frame, x + div(w, 2), @tray_left_offset)
      :not_found -> scan_focused(frame)
    end
  end

  defp scan_focused(%Frame{} = frame) do
    case Matcher.find(frame, :battle_focused) do
      {:ok, {x, _y, w, _h}} -> scan_gear(frame, x + div(w, 2), @focused_tray_left_offset)
      :not_found -> :not_found
    end
  end

  defp scan_gear(frame, gear_start_x, tray_left_offset) do
    with tray = geometry(gear_start_x, tray_left_offset),
         {:ok, sinner_of_slot} <- assign_sinner_of_slot(tray, frame) do
      {:ok, %{tray | sinner_of_slot: sinner_of_slot}}
    end
  end

  defp get_tray_bounds(gear_start_x, tray_left_offset) do
    tray_start_x = gear_start_x + tray_left_offset
    tray_end_x = @screen_w - tray_start_x - @tray_end_inset
    length = tray_end_x - tray_start_x
    skill_num = max(1, round(length / @est_bin_width))
    {tray_start_x, tray_end_x, length, skill_num}
  end

  @gear_x_correction %{12 => -5, 11 => -4, 10 => -3, 9 => -1}

  @spec geometry(integer, integer) :: t()
  def geometry(gear_start_x, tray_left_offset \\ @tray_left_offset) when is_integer(gear_start_x) do
    {_, _, _, skill_num_guess} = get_tray_bounds(gear_start_x, tray_left_offset)
    gear_start_x = gear_start_x - Map.get(@gear_x_correction, skill_num_guess, 0)
    {tray_start_x, tray_end_x, length, skill_num} = get_tray_bounds(gear_start_x, tray_left_offset)
    top_row_y = @top_row_y + case skill_num  do
      6 -> -3
      5 -> -3
      4 -> -4
      3 -> -4
      2 -> -6
      1 -> -6
      _ -> -1
    end

    top_row_h = @top_row_h + case skill_num  do
      6 -> -2
      5 -> -2
      4 -> -2
      3 -> -2
      2 -> -3
      1 -> -3
      _ -> 0
    end

    %__MODULE__{
      gear_start_x: gear_start_x,
      tray_start_x: tray_start_x,
      tray_end_x: tray_end_x,
      bin_width: length / skill_num,
      skill_num: skill_num,
      sinner_of_slot: nil,
      chain_top_y: round(top_row_y + top_row_h / 2 + @chain_top_y_offset),
      chain_bottom_y: round(@bottom_row_y + @bottom_row_h / 2 + @chain_bottom_y_offset),
      top_row:
        row(
          tray_start_x,
          tray_end_x,
          skill_num,
          top_row_y,
          top_row_h,
          @top_row_inset_def,
          @top_cell_inset_pct,
          @top_hue_scan_offset,
          @top_hue_inset_x_pct
        ),
      bottom_row:
        row(
          tray_start_x,
          tray_end_x,
          skill_num,
          @bottom_row_y,
          @bottom_row_h,
          @bottom_row_inset_def,
          @bottom_cell_inset_pct,
          @bottom_hue_scan_offset,
          @bottom_hue_inset_x_pct
        )
    }
  end

  defp row(tray_start_x, tray_end_x, skill_num, y, h, inset_def, cell_inset_pct, hue_scan_offset, hue_inset_x_pct) do
    [base_inset, multiplier, inverse_proportional] = inset_def
    inset = base_inset + (skill_num * multiplier) + (inverse_proportional / Float.pow(skill_num * 1.0, 0.8))
    start_x = tray_start_x + inset
    end_x = tray_end_x - inset

    %{
      y: y,
      h: h,
      hue_scan_y: y + hue_scan_offset,
      start_x: start_x,
      end_x: end_x,
      bin_width: (end_x - start_x) / skill_num,
      columns: skill_num,
      cell_inset_pct: cell_inset_pct,
      hue_inset_x_pct: hue_inset_x_pct
    }
  end

  @spec background_region(t()) :: {integer, integer, integer, integer}
  def background_region(%__MODULE__{tray_start_x: tray_start_x, tray_end_x: tray_end_x}) do
    {tray_start_x, @top_row_y - @bg_strip_gap_above_top_row, tray_end_x - tray_start_x, @bg_strip_h}
  end

  @spec chain_grid(t()) :: [{float, integer, integer}]
  def chain_grid(%__MODULE__{skill_num: skill_num, tray_start_x: tray_start_x, bin_width: bin_width} = tray) do
    for i <- 0..(skill_num - 1) do
      {tray_start_x + bin_width * (i + 0.5), tray.chain_top_y, tray.chain_bottom_y}
    end
  end

  @spec row_columns(row) :: [{integer, integer}]
  def row_columns(%{cell_inset_pct: cell_inset_pct} = row), do: columns_with_inset(row, cell_inset_pct)

  @spec hue_scan_columns(row) :: [{integer, integer}]
  def hue_scan_columns(%{cell_inset_pct: cell_inset_pct, hue_inset_x_pct: hue_inset_x_pct} = row),
    do: columns_with_inset(row, cell_inset_pct + hue_inset_x_pct)

  defp columns_with_inset(%{start_x: start_x, bin_width: bin_width, columns: columns}, inset_pct) do
    inset = bin_width * inset_pct

    for i <- 0..(columns - 1) do
      {round(start_x + bin_width * i + inset), round(start_x + bin_width * (i + 1) - inset)}
    end
  end

  defp assign_sinner_of_slot(%__MODULE__{} = tray, %Frame{mat: mat}) do
    case HookRegistry.find(@hp_hook) do
      {:ok, hook} -> {:ok, sinner_of_slot(tray.skill_num, first_action_bins(tray, mat, hook))}
      {:error, :not_found} -> {:error, {:hook_missing, @hp_hook}}
    end
  end

  @spec first_action_bins(t(), term, map) :: MapSet.t(non_neg_integer)
  def first_action_bins(%__MODULE__{} = tray, mat, %{region: {_hx, hy, _hw, hh}} = hook) do
    width = tray.tray_end_x - tray.tray_start_x
    strip = Evision.Mat.roi(mat, {tray.tray_start_x, hy, width, hh})
    tolerance = Matcher.confidence_to_hsv_tolerance(hook.confidence)
    min_area = hook.min_cluster_size || 0

    strip
    |> Matcher.color_cluster_rects(hook.color, tolerance)
    |> Enum.filter(fn {area, _rect} -> area >= min_area end)
    |> Enum.map(fn {_area, {rx, _ry, rw, _rh}} -> bin_index(tray, rx + rw / 2) end)
    |> MapSet.new()
  end

  defp bin_index(%__MODULE__{skill_num: skill_num, bin_width: bin_width}, x_in_strip) do
    x_in_strip
    |> Kernel./(bin_width)
    |> Float.floor()
    |> trunc()
    |> max(0)
    |> min(skill_num - 1)
  end

  @spec sinner_of_slot(pos_integer, MapSet.t(non_neg_integer)) :: [non_neg_integer]
  def sinner_of_slot(skill_num, first_action_bins) do
    1..(skill_num - 1)//1
    |> Enum.reduce([0], fn i, [prev | _] = acc ->
      sinner_id = if MapSet.member?(first_action_bins, i), do: prev + 1, else: prev
      [sinner_id | acc]
    end)
    |> Enum.reverse()
  end
end
