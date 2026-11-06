defmodule StarlightBot.Navigation.RunArchive do
  alias StarlightBot.Navigation.RunSplits

  @window_seconds 24 * 3600

  def entry(%{run_times_kind: kind, run_splits: [_ | _] = splits, run_started_at: %DateTime{} = started_at} = state, elapsed_ms) when not is_nil(kind) do
    memory = state.run_memory || %{}

    %{
      kind: kind,
      started_at: started_at,
      runs: RunSplits.summary(splits, elapsed_ms, Map.get(memory, :failed_runs, []), Map.get(memory, :picked_packs, %{}))
    }
  end

  def entry(_state, _elapsed_ms), do: nil

  def push(archive, nil, now), do: prune(archive, now)
  def push(archive, entry, now), do: prune(archive ++ [entry], now)

  def prune(archive, now) do
    cutoff = DateTime.add(now, -@window_seconds)
    Enum.filter(archive, &(DateTime.compare(&1.started_at, cutoff) != :lt))
  end

  def groups(entries) do
    entries
    |> Enum.chunk_by(& &1.kind)
    |> Enum.map(fn [%{kind: kind} | _] = chunk ->
      runs = chunk |> Enum.flat_map(& &1.runs) |> number_runs(kind)
      %{kind: kind, runs: runs, ms: runs |> Enum.map(& &1.ms) |> Enum.sum()}
    end)
  end

  def total_ms(groups), do: groups |> Enum.map(& &1.ms) |> Enum.sum()

  defp number_runs(runs, :mirror_dungeon), do: runs |> Enum.with_index(1) |> Enum.map(fn {run, index} -> %{run | run: index} end)
  defp number_runs(runs, _kind), do: runs
end
