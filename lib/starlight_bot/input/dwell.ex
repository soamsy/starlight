defmodule StarlightBot.Input.Dwell do
  alias StarlightBot.Input.Wander

  @tick_ms 12
  @min_ms 20

  def run(ms, anchor, radius, _step_fun) when ms < @min_ms or radius <= 0 do
    if ms > 0, do: :timer.sleep(ms)
    anchor
  end

  def run(ms, {ax, ay} = anchor, radius, step_fun) do
    start = System.monotonic_time(:millisecond)
    deadline = start + ms
    origin = {ax * 1.0, ay * 1.0}
    area = {ax - radius * 1.0, ay - radius * 1.0, ax + radius * 1.0, ay + radius * 1.0}
    wander = Wander.new(area, origin, held: true)
    loop(deadline, start, origin, wander, anchor, radius, step_fun)
  end

  defp loop(deadline, prev_t, pos, wander, anchor, radius, step_fun) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= @tick_ms do
      if remaining > 0, do: :timer.sleep(remaining)
      pos
    else
      :timer.sleep(@tick_ms)
      now = System.monotonic_time(:millisecond)
      wander = Wander.step(wander, (now - prev_t) / 1000)
      next = within_radius(wander.pos, anchor, radius)
      step_fun.(pos, next)
      loop(deadline, now, next, wander, anchor, radius, step_fun)
    end
  end

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
