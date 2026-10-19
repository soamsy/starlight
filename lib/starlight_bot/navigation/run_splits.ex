defmodule StarlightBot.Navigation.RunSplits do
  def track(splits, run, floor, at_ms, team \\ nil)

  def track([], run, floor, _at_ms, team) when is_integer(run) and is_integer(floor), do: [split(run, floor, 0, team)]

  def track(splits, run, floor, at_ms, team) when is_integer(run) and is_integer(floor) do
    case List.last(splits) do
      %{run: ^run, floor: ^floor} -> splits
      _ -> splits ++ [split(run, floor, at_ms, team)]
    end
  end

  def track(splits, _run, _floor, _at_ms, _team), do: splits

  defp split(run, floor, start_ms, nil), do: %{run: run, floor: floor, start_ms: start_ms}
  defp split(run, floor, start_ms, team), do: %{run: run, floor: floor, start_ms: start_ms, team: team}

  def summary(splits, elapsed_ms, failed_runs \\ [], picked_packs \\ %{}) do
    ends = Enum.map(Enum.drop(splits, 1), & &1.start_ms) ++ [elapsed_ms]

    splits
    |> Enum.zip(ends)
    |> Enum.map(fn {split, end_ms} -> Map.put(split, :ms, max(end_ms - split.start_ms, 0)) end)
    |> Enum.chunk_by(& &1.run)
    |> Enum.map(fn [%{run: run} = first | _] = chunk ->
      floors =
        chunk
        |> Enum.chunk_by(& &1.floor)
        |> Enum.map(fn [%{floor: floor} | _] = same ->
          %{floor: floor, ms: same |> Enum.map(& &1.ms) |> Enum.sum(), pack: picked_packs[{run, floor}]}
        end)

      %{run: run, team: first[:team], failed?: run in failed_runs, ms: floors |> Enum.map(& &1.ms) |> Enum.sum(), floors: floors}
    end)
  end
end
