defmodule StarlightBot.Vision.EnemyTargets do
  alias StarlightBot.Vision.{Frame, Matcher}

  @icon_hook :enemy_target_part_icon_white
  @red_hook :enemy_target_part_icon_red
  @brown_hook :enemy_target_part_icon_brown
  @body_hooks [@red_hook, :enemy_target_staggered]

  @same_icon_px 50
  @red_min_dy_heights 2
  @red_max_dy_heights 7
  @target_x_ratio 0.4
  @target_y_ratio 0.75
  @max_x_past_icon_px -10
  @brown_red_max_gap_px 30

  defstruct [:point, :icon]

  @type t :: %__MODULE__{point: {number, number}, icon: {number, number}}

  @spec find(Frame.t()) :: [t()]
  def find(%Frame{} = frame) do
    from_icons(
      Matcher.find_all(frame, @icon_hook),
      Enum.flat_map(@body_hooks, &Matcher.find_all(frame, &1)),
      Matcher.find_all(frame, @brown_hook),
      Matcher.find_all(frame, @red_hook)
    )
  end

  @spec from_icons([rect], [rect], [rect], [rect]) :: [t()] when rect: {number, number, number, number}
  def from_icons(icon_rects, body_rects, brown_rects \\ [], red_rects \\ []) do
    whites = dedupe_whites(icon_rects)
    icons = Enum.map(whites, fn {x, y, _h} -> {x, y} end)

    white_pairs =
      Enum.flat_map(whites, fn {ix, iy, _h} = white ->
        case Enum.filter(body_rects, &underneath?(&1, white)) do
          [] -> []
          reds -> [{{ix, iy}, Enum.max_by(reds, fn {x, _y, w, h} -> {w * h, -abs(x + w / 2 - ix)} end), :white}]
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

    (white_pairs ++ brown_pairs)
    |> Enum.uniq_by(fn {_icon, red, _kind} -> red end)
    |> Enum.map(fn {{ix, _iy} = icon, {x, y, w, h}, kind} ->
      red_x = round(x + w * @target_x_ratio)
      target_x = if kind == :white, do: min(red_x, ix + @max_x_past_icon_px), else: red_x
      %__MODULE__{point: {target_x, round(y + h * @target_y_ratio)}, icon: icon}
    end)
    |> Enum.sort_by(fn %__MODULE__{point: {x, _y}} -> x end)
  end

  defp dedupe_whites(rects) do
    rects
    |> Enum.sort_by(fn {_x, _y, w, h} -> -(w * h) end)
    |> Enum.map(fn {_x, _y, _w, h} = rect ->
      {cx, cy} = center(rect)
      {cx, cy, h}
    end)
    |> Enum.reduce([], fn {cx, cy, _h} = white, kept ->
      if Enum.any?(kept, fn {kx, ky, _} -> same_icon?({kx, ky}, {cx, cy}) end), do: kept, else: [white | kept]
    end)
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

  defp underneath?({x, y, w, h}, {ix, iy, icon_h}) do
    min_dy = icon_h * @red_min_dy_heights
    max_dy = icon_h * @red_max_dy_heights
    max_dx = (max_dy - min_dy) / 2
    dy = y + h / 2 - iy
    dx = x + w / 2 - ix
    dy >= min_dy and dy <= max_dy and abs(dx) <= max_dx
  end

  defp same_icon?({ax, ay}, {bx, by}), do: :math.sqrt((ax - bx) ** 2 + (ay - by) ** 2) < @same_icon_px

  defp center({x, y, w, h}), do: {round(x + w / 2), round(y + h / 2)}
end
