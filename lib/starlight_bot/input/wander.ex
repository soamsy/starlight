defmodule StarlightBot.Input.Wander do
  @margin 15.0
  @arrival_px 28.0
  @min_speed 160.0
  @max_speed 420.0
  @max_accel 1600.0
  @min_leg_fraction 0.4
  @goal_tries 8
  @dwell_chance 0.12
  @dwell_min_s 0.15
  @dwell_max_s 0.5
  @max_dt_s 0.05

  defstruct [:area, :pos, :goal, :speed, vel: {0.0, 0.0}, dwell: 0.0]

  def margin, do: @margin

  def area(within, window) do
    screen = inset(window)

    case within do
      nil -> screen
      {bx, by, bw, bh} -> intersect({bx - @margin, by - @margin, bx + bw + @margin, by + bh + @margin}, screen)
    end
  end

  def new({x0, y0, x1, y1} = area, {px, py}) do
    %__MODULE__{area: area, pos: {clamp(px, x0, x1), clamp(py, y0, y1)}}
    |> pick_goal()
  end

  def step(%__MODULE__{} = w, dt_s) do
    dt = min(dt_s, @max_dt_s)
    {desired, w} = aim(w, dt)
    w |> accelerate(desired, dt) |> advance(dt)
  end

  defp aim(%{dwell: d} = w, dt) when d > 0.0, do: {{0.0, 0.0}, %{w | dwell: d - dt}}

  defp aim(w, _dt) do
    w = if distance(w.pos, w.goal) < @arrival_px, do: arrive(w), else: w

    if w.dwell > 0.0 do
      {{0.0, 0.0}, w}
    else
      {toward(w.pos, w.goal, w.speed), w}
    end
  end

  defp arrive(w) do
    w = pick_goal(w)
    if :rand.uniform() < @dwell_chance, do: %{w | dwell: @dwell_min_s + :rand.uniform() * (@dwell_max_s - @dwell_min_s)}, else: w
  end

  defp pick_goal(%{area: {x0, y0, x1, y1}} = w) do
    min_dist = @min_leg_fraction * distance({x0, y0}, {x1, y1})

    goal =
      Enum.reduce_while(1..@goal_tries, nil, fn _, _ ->
        candidate = {x0 + :rand.uniform() * (x1 - x0), y0 + :rand.uniform() * (y1 - y0)}
        if distance(w.pos, candidate) >= min_dist, do: {:halt, candidate}, else: {:cont, candidate}
      end)

    %{w | goal: goal, speed: @min_speed + :rand.uniform() * (@max_speed - @min_speed)}
  end

  defp accelerate(%{vel: {vx, vy}} = w, {dx, dy}, dt) do
    ex = dx - vx
    ey = dy - vy
    mag = :math.sqrt(ex * ex + ey * ey)
    limit = @max_accel * dt
    {ax, ay} = if mag > limit, do: {ex / mag * limit, ey / mag * limit}, else: {ex, ey}
    %{w | vel: {vx + ax, vy + ay}}
  end

  defp advance(%{pos: {px, py}, vel: {vx, vy}, area: {x0, y0, x1, y1}} = w, dt) do
    nx = px + vx * dt
    ny = py + vy * dt
    cx = clamp(nx, x0, x1)
    cy = clamp(ny, y0, y1)
    %{w | pos: {cx, cy}, vel: {if(cx == nx, do: vx, else: 0.0), if(cy == ny, do: vy, else: 0.0)}}
  end

  defp toward({px, py}, {gx, gy}, speed) do
    dx = gx - px
    dy = gy - py
    mag = max(:math.sqrt(dx * dx + dy * dy), 1.0e-6)
    {dx / mag * speed, dy / mag * speed}
  end

  defp distance({ax, ay}, {bx, by}), do: :math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by))

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  defp inset(nil), do: nil
  defp inset({wx, wy, ww, wh}), do: {wx + @margin, wy + @margin, wx + ww - @margin, wy + wh - @margin}

  defp intersect(box, nil), do: box

  defp intersect({ax0, ay0, ax1, ay1}, {bx0, by0, bx1, by1} = screen) do
    x0 = max(ax0, bx0)
    y0 = max(ay0, by0)
    x1 = min(ax1, bx1)
    y1 = min(ay1, by1)
    if x1 > x0 and y1 > y0, do: {x0, y0, x1, y1}, else: screen
  end
end
