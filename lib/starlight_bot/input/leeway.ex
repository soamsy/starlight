defmodule StarlightBot.Input.Leeway do
  @click_radius_px 5

  @min_box_px 10

  def click(point), do: point(point, @click_radius_px)

  def in_rect({x, y, w, h}) do
    cx = x + w / 2
    cy = y + h / 2

    if w / 2 >= @min_box_px and h / 2 >= @min_box_px do
      {cx + gaussian_offset(w / 10, w / 4), cy + gaussian_offset(h / 10, h / 4)}
    else
      point({cx, cy}, @click_radius_px)
    end
  end

  defp gaussian_offset(sigma, limit), do: :rand.normal(0.0, sigma) |> max(-limit) |> min(limit)

  def point({x, y}, radius) do
    angle = :rand.uniform() * 2 * :math.pi()
    dist = min(abs(:rand.normal(0.0, radius / 2.2)), radius)
    {round(x + dist * :math.cos(angle)), round(y + dist * :math.sin(angle))}
  end
end
