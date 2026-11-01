defmodule StarlightBot.Input.Leeway do
  @click_radius_px 5

  @min_box_px 10

  def click(point), do: point(point, @click_radius_px)

  def in_rect({x, y, w, h}) do
    cx = x + w / 2
    cy = y + h / 2

    if w / 2 >= @min_box_px and h / 2 >= @min_box_px do
      {cx + (:rand.uniform() - 0.5) * w / 2, cy + (:rand.uniform() - 0.5) * h / 2}
    else
      point({cx, cy}, @click_radius_px)
    end
  end

  def point({x, y}, radius) do
    angle = :rand.uniform() * 2 * :math.pi()
    dist = radius * :math.sqrt(:rand.uniform())
    {round(x + dist * :math.cos(angle)), round(y + dist * :math.sin(angle))}
  end
end
