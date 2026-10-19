defmodule StarlightBot.Navigation.ScreenTimes do
  @keys [:screen, :task, :step, :run, :floor]
  @blank Map.new(@keys, &{&1, nil})

  defstruct segments: [], current: nil

  def track(%__MODULE__{current: nil} = times, key, at_ms, wall), do: %{times | current: open(key, at_ms, wall)}

  def track(%__MODULE__{current: current} = times, key, at_ms, wall) do
    if Map.take(current, @keys) == normalize(key) do
      times
    else
      %{times | segments: close(times.segments, current, at_ms), current: open(key, at_ms, wall)}
    end
  end

  def current_run(%__MODULE__{current: nil}), do: nil
  def current_run(%__MODULE__{current: current}), do: current.run

  def segments(%__MODULE__{current: nil} = times, _elapsed_ms), do: Enum.reverse(times.segments)
  def segments(%__MODULE__{} = times, elapsed_ms), do: times.segments |> close(times.current, elapsed_ms) |> Enum.reverse()

  def breakdown(segments) do
    segments
    |> visits()
    |> Enum.group_by(& &1.screen)
    |> Enum.map(fn {screen, visits} ->
      visit_ms = Enum.map(visits, & &1.ms)

      details =
        visits
        |> Enum.flat_map(& &1.segments)
        |> Enum.group_by(&detail/1)
        |> Enum.map(fn {detail, segs} -> %{detail: detail, ms: total_ms(segs), count: length(segs)} end)
        |> Enum.reject(&(&1.ms <= 0))
        |> Enum.sort_by(& &1.ms, :desc)

      %{screen: screen, ms: Enum.sum(visit_ms), visits: length(visits), longest_ms: Enum.max(visit_ms), details: details}
    end)
    |> Enum.reject(&(&1.ms <= 0))
    |> Enum.sort_by(& &1.ms, :desc)
  end

  def timeline(segments) do
    segments
    |> Enum.chunk_by(& &1.run)
    |> Enum.map(fn [first | _] = run_segments ->
      %{
        run: first.run,
        start_ms: first.start_ms,
        ms: total_ms(run_segments),
        visits: visits(run_segments),
        floors: run_segments |> Enum.chunk_by(& &1.floor) |> Enum.map(&%{floor: hd(&1).floor, start_ms: hd(&1).start_ms, ms: total_ms(&1)})
      }
    end)
  end

  def visits(segments) do
    segments
    |> Enum.chunk_by(&{&1.run, &1.screen})
    |> Enum.map(fn [first | _] = segs -> %{screen: first.screen, floor: first.floor, start_ms: first.start_ms, ms: total_ms(segs), segments: segs} end)
  end

  def detail(%{task: task, step: step}), do: [task, step] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")

  def duration_ms(segment), do: segment.end_ms - segment.start_ms

  defp total_ms(segments), do: segments |> Enum.map(&duration_ms/1) |> Enum.sum()

  defp normalize(key), do: Map.merge(@blank, Map.take(key, @keys))

  defp open(key, at_ms, wall), do: key |> normalize() |> Map.merge(%{start_ms: at_ms, started_at: wall})

  defp close(segments, current, end_ms) when end_ms > current.start_ms, do: [Map.put(current, :end_ms, end_ms) | segments]
  defp close(segments, _current, _end_ms), do: segments
end
