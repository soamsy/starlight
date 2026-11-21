defmodule StarlightBot.Input.Dwell do
  alias StarlightBot.Input.Wander

  @tick_ms 12
  @min_ms 20
  @max_converge_ms 100
  @converge_fraction 0.3

  def run(ms, anchor, radius, step_fun, opts \\ [])

  def run(ms, anchor, radius, _step_fun, _opts) when ms < @min_ms or radius <= 0 do
    if ms > 0, do: :timer.sleep(ms)
    anchor
  end

  def run(ms, {ax, ay} = anchor, radius, step_fun, opts) do
    converge_ms = if Keyword.get(opts, :converge, false), do: min(@max_converge_ms, round(ms * @converge_fraction)), else: 0
    start = System.monotonic_time(:millisecond)
    deadline = start + ms
    origin = {ax * 1.0, ay * 1.0}
    area = {ax - radius * 1.0, ay - radius * 1.0, ax + radius * 1.0, ay + radius * 1.0}
    wander = Wander.new(area, origin, held: true)
    loop(deadline, start, origin, wander, anchor, radius, step_fun, converge_ms)
  end

  defp loop(deadline, prev_t, pos, wander, anchor, radius, step_fun, converge_ms) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= @tick_ms do
      if remaining > 0, do: :timer.sleep(remaining)
      finish(pos, anchor, step_fun, converge_ms)
    else
      :timer.sleep(@tick_ms)
      now = System.monotonic_time(:millisecond)
      wander = Wander.step(wander, (now - prev_t) / 1000)
      next = within_radius(wander.pos, anchor, tapered_radius(radius, remaining, converge_ms))
      step_fun.(pos, next)
      loop(deadline, now, next, wander, anchor, radius, step_fun, converge_ms)
    end
  end

  defp tapered_radius(radius, remaining, converge_ms) when converge_ms > 0 and remaining < converge_ms do
    radius * remaining / converge_ms
  end

  defp tapered_radius(radius, _remaining, _converge_ms), do: radius

  defp finish(pos, {ax, ay}, step_fun, converge_ms) when converge_ms > 0 do
    target = {ax * 1.0, ay * 1.0}
    if pos != target, do: step_fun.(pos, target)
    target
  end

  defp finish(pos, _anchor, _step_fun, _converge_ms), do: pos

  defp within_radius({x, y}, {ax, ay}, radius) do
    dx = x - ax
    dy = y - ay
    dist = :math.sqrt(dx * dx + dy * dy)

    if dist <= radius do
      {x * 1.0, y * 1.0}
    else
      scale = radius / dist
      {ax + dx * scale, ay + dy * scale}
    end
  end
end
