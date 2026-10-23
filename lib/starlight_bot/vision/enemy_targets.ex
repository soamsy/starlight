defmodule StarlightBot.Vision.EnemyTargets do
  alias StarlightBot.Vision.{Frame, Matcher}

  @icon_hook :enemy_target_part_icon_white
  @body_hooks [:enemy_target_part_icon_red, :enemy_target_staggered]

  @same_icon_px 50
  @under_dx_px 24
  @under_max_dy_px 180
  @target_x_ratio 0.4
  @target_y_ratio 0.75
  @max_x_past_icon_px -10

  defstruct [:point, :icon]

  @type t :: %__MODULE__{point: {number, number}, icon: {number, number}}

  @spec find(Frame.t()) :: [t()]
  def find(%Frame{} = frame) do
    from_icons(Matcher.find_all(frame, @icon_hook), Enum.flat_map(@body_hooks, &Matcher.find_all(frame, &1)))
  end

  @spec from_icons([rect], [rect]) :: [t()] when rect: {number, number, number, number}
  def from_icons(icon_rects, body_rects) do
    icon_rects
    |> Enum.sort_by(fn {_x, _y, w, h} -> -(w * h) end)
    |> Enum.map(&center/1)
    |> Enum.reduce([], fn point, kept -> if Enum.any?(kept, &same_icon?(&1, point)), do: kept, else: [point | kept] end)
    |> Enum.flat_map(fn icon ->
      case Enum.filter(body_rects, &underneath?(&1, icon)) do
        [] -> []
        reds -> [{icon, Enum.max_by(reds, fn {_x, _y, w, h} -> w * h end)}]
      end
    end)
    |> Enum.uniq_by(fn {_icon, red} -> red end)
    |> Enum.map(fn {{ix, _iy} = icon, {x, y, w, h}} ->
      target_x = min(round(x + w * @target_x_ratio), ix + @max_x_past_icon_px)
      %__MODULE__{point: {target_x, round(y + h * @target_y_ratio)}, icon: icon}
    end)
    |> Enum.sort_by(fn %__MODULE__{point: {x, _y}} -> x end)
  end

  defp underneath?({x, y, w, h}, {ix, iy}) do
    dx = Enum.max([x - ix, 0, ix - (x + w)])
    dy = y + h / 2 - iy
    dx <= @under_dx_px and dy > 0 and y - iy <= @under_max_dy_px
  end

  defp same_icon?({ax, ay}, {bx, by}), do: :math.sqrt((ax - bx) ** 2 + (ay - by) ** 2) < @same_icon_px

  defp center({x, y, w, h}), do: {round(x + w / 2), round(y + h / 2)}
end
