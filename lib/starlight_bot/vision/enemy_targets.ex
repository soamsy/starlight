defmodule StarlightBot.Vision.EnemyTargets do
  alias StarlightBot.Vision.{Frame, Matcher}

  @icon_hook :enemy_target_part_icon_white
  @red_hook :enemy_target_part_icon_red
  @backup_hooks [
    :enemy_target_part_icon_brown,
    :enemy_target_part_icon_wrath,
    :enemy_target_part_icon_lust,
    :enemy_target_part_icon_sloth,
    :enemy_target_part_icon_gluttony,
    :enemy_target_part_icon_gloom,
    :enemy_target_part_icon_pride,
    :enemy_target_part_icon_envy
  ]
  @body_hooks [@red_hook, :enemy_target_staggered]

  @same_icon_px 50
  @white_max_px 40
  @white_scale_cap_px 18
  @white_merge_gap_px 10
  @icon_body_max_dx_heights 1.5
  @red_min_dy_heights 2
  @red_max_dy_heights 7
  @reserve_max_dy_heights 8
  @reserve_width_ratio 0.9
  @target_x_ratio 0.4
  @target_y_ratio 0.75
  @max_x_past_icon_px -10
  @brown_red_max_gap_px 30
  @backup_reserve_pad_px 20

  defstruct [:point, :icon, :zone]

  @type t :: %__MODULE__{point: {number, number}, icon: {number, number}, zone: {number, number, number, number} | nil}

  @spec find(Frame.t()) :: [t()]
  def find(%Frame{} = frame) do
    from_icons(
      Matcher.find_all(frame, @icon_hook),
      Enum.flat_map(@body_hooks, &Matcher.find_all(frame, &1)),
      Enum.flat_map(@backup_hooks, &Matcher.find_all(frame, &1)),
      Matcher.find_all(frame, @red_hook)
    )
  end

  @spec from_icons([rect], [rect], [rect], [rect]) :: [t()] when rect: {number, number, number, number}
  def from_icons(icon_rects, body_rects, brown_rects \\ [], red_rects \\ []) do
    whites = icon_rects |> Enum.filter(fn {_x, _y, w, h} -> w <= @white_max_px and h <= @white_max_px end) |> merge_whites()
    icons = Enum.map(whites, fn {x, y, _s} -> {x, y} end)
    icon_bodies = assign(brown_rects, whites, &icon_body_fits?/2)
    plain_bodies = assign(body_rects, whites, &underneath?/2)

    white_pairs =
      Enum.flat_map(whites, fn {ix, iy, _s} = white ->
        case Map.get(icon_bodies, white) || Map.get(plain_bodies, white) do
          nil -> []
          rects -> [{{ix, iy}, union_all(rects), {:white, zone(white)}}]
        end
      end)

    brown_pairs =
      brown_rects
      |> dedupe_icons()
      |> Enum.reject(fn brown -> Enum.any?(icons, &same_icon?(&1, brown)) end)
      |> Enum.flat_map(fn brown ->
        case Enum.filter(red_rects, &(gap(&1, brown) <= @brown_red_max_gap_px)) do
          [] -> []
          reds -> [{brown, Enum.min_by(reds, &gap(&1, brown)), :brown}]
        end
      end)

    claimed_whites = Enum.filter(whites, &(Map.has_key?(icon_bodies, &1) or Map.has_key?(plain_bodies, &1)))

    brown_pairs =
      brown_pairs
      |> Enum.reject(fn {_icon, red, _kind} -> Enum.any?(claimed_whites, &reserved?(red, &1)) end)
      |> Enum.sort_by(fn {_icon, {x, _y, w, h}, :brown} -> {-(w * h), x} end)
      |> Enum.reduce([], fn {icon, red, :brown}, kept ->
        if Enum.any?(kept, fn {_, _, {:brown, zone}} -> in_rect?(red, zone) end),
          do: kept,
          else: kept ++ [{icon, red, {:brown, pad(red, @backup_reserve_pad_px)}}]
      end)

    (white_pairs ++ brown_pairs)
    |> Enum.uniq_by(fn {_icon, red, _kind} -> red end)
    |> Enum.map(fn {{ix, _iy} = icon, {x, y, w, h}, kind} ->
      red_x = round(x + w * @target_x_ratio)

      {target_x, zone} =
        case kind do
          {:white, zone} -> {min(red_x, ix + @max_x_past_icon_px), zone}
          {:brown, zone} -> {red_x, zone}
        end

      %__MODULE__{point: {target_x, round(y + h * @target_y_ratio)}, icon: icon, zone: zone}
    end)
    |> Enum.sort_by(fn %__MODULE__{point: {x, _y}} -> x end)
  end

  defp merge_whites(rects) do
    rects
    |> Enum.reduce([], &absorb/2)
    |> Enum.map(fn {_x, _y, w, h} = rect ->
      {cx, cy} = center(rect)
      {cx, cy, Enum.min([w, h, @white_scale_cap_px])}
    end)
  end

  defp absorb(rect, clusters) do
    {near, far} = Enum.split_with(clusters, &(rect_gap(&1, rect) <= @white_merge_gap_px))
    [Enum.reduce(near, rect, &union/2) | far]
  end

  defp rect_gap({ax, ay, aw, ah}, {bx, by, bw, bh}) do
    dx = Enum.max([bx - (ax + aw), ax - (bx + bw), 0])
    dy = Enum.max([by - (ay + ah), ay - (by + bh), 0])
    :math.sqrt(dx * dx + dy * dy)
  end

  defp union({ax, ay, aw, ah}, {bx, by, bw, bh}) do
    x = min(ax, bx)
    y = min(ay, by)
    {x, y, max(ax + aw, bx + bw) - x, max(ay + ah, by + bh) - y}
  end

  defp union_all([first | rest]), do: Enum.reduce(rest, first, &union/2)

  defp icon_body_fits?({x, _y, w, _h} = rect, {ix, _iy, s} = white) do
    underneath?(rect, white) and abs(x + w / 2 - ix) <= s * @icon_body_max_dx_heights
  end

  defp assign(rects, whites, fits?) do
    rects
    |> Enum.flat_map(fn {x, _y, w, _h} = rect ->
      case Enum.filter(whites, &fits?.(rect, &1)) do
        [] -> []
        candidates -> [{Enum.min_by(candidates, fn {ix, _iy, _s} -> abs(x + w / 2 - ix) end), rect}]
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp dedupe_icons(rects) do
    rects
    |> Enum.sort_by(fn {_x, _y, w, h} -> -(w * h) end)
    |> Enum.map(&center/1)
    |> Enum.reduce([], fn point, kept -> if Enum.any?(kept, &same_icon?(&1, point)), do: kept, else: [point | kept] end)
  end

  defp gap({x, y, w, h}, {px, py}) do
    dx = Enum.max([x - px, 0, px - (x + w)])
    dy = Enum.max([y - py, 0, py - (y + h)])
    :math.sqrt(dx * dx + dy * dy)
  end

  defp zone({ix, iy, icon_h}) do
    min_dy = icon_h * @red_min_dy_heights
    max_dx = max_dx(icon_h) * @reserve_width_ratio
    {round(ix - max_dx), round(iy + min_dy), round(max_dx * 2), round(icon_h * @reserve_max_dy_heights - min_dy)}
  end

  defp max_dx(icon_h), do: icon_h * (@red_max_dy_heights - @red_min_dy_heights) / 2

  defp reserved?({x, y, w, h}, {ix, iy, icon_h}) do
    dy = y + h / 2 - iy
    dx = x + w / 2 - ix
    dy >= icon_h * @red_min_dy_heights and dy <= icon_h * @reserve_max_dy_heights and abs(dx) <= max_dx(icon_h) * @reserve_width_ratio
  end

  defp pad({x, y, w, h}, by), do: {x - by, y - by, w + 2 * by, h + 2 * by}

  defp in_rect?({x, y, w, h}, {zx, zy, zw, zh}) do
    cx = x + w / 2
    cy = y + h / 2
    cx >= zx and cx <= zx + zw and cy >= zy and cy <= zy + zh
  end

  defp underneath?({x, y, w, h}, {ix, iy, icon_h}) do
    min_dy = icon_h * @red_min_dy_heights
    max_dy = icon_h * @red_max_dy_heights
    max_dx = max_dx(icon_h)
    dy = y + h / 2 - iy
    dx = x + w / 2 - ix
    dy >= min_dy and dy <= max_dy and abs(dx) <= max_dx
  end

  defp same_icon?({ax, ay}, {bx, by}), do: :math.sqrt((ax - bx) ** 2 + (ay - by) ** 2) < @same_icon_px

  defp center({x, y, w, h}), do: {round(x + w / 2), round(y + h / 2)}
end
