defmodule StarlightBot.Input.Dwell do
  alias StarlightBot.Input.Leeway

  @tick_ms 12
  @min_ms 20

  def run(ms, _anchor, radius, _step_fun) when ms < @min_ms or radius <= 0 do
    if ms > 0, do: :timer.sleep(ms)
    :ok
  end

  def run(ms, {ax, ay} = anchor, radius, step_fun) do
    deadline = System.monotonic_time(:millisecond) + ms
    last = loop(deadline, {ax * 1.0, ay * 1.0}, anchor, radius, step_fun)
    if last != anchor, do: step_fun.(last, {ax * 1.0, ay * 1.0})
    :ok
  end

  defp loop(deadline, pos, anchor, radius, step_fun) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= @tick_ms do
      if remaining > 0, do: :timer.sleep(remaining)
      pos
    else
      :timer.sleep(@tick_ms)
      next = Leeway.point(anchor, radius)
      step_fun.(pos, next)
      loop(deadline, next, anchor, radius, step_fun)
    end
  end
end
