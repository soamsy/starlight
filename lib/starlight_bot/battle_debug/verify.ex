defmodule StarlightBot.BattleDebug.Verify do
  alias StarlightBot.BattleDebug
  alias StarlightBot.BattleDebug.Detect

  def run(id) do
    with %{} = record <- BattleDebug.get(id),
         {:ok, frame} <- BattleDebug.load_frame(id),
         truth = BattleDebug.truth(id, record),
         {:ok, detected} <- Detect.run(record["kind"], frame) do
      record["kind"] |> compare(truth, normalize(detected)) |> Map.merge(%{id: id, kind: record["kind"]})
    else
      nil -> failure(id, nil, :record_missing)
      :error -> failure(id, nil, :image_unreadable)
      {:error, reason} -> failure(id, kind_of(id), reason)
    end
  end

  def compare("chain_tray", truth, detected) do
    diffs = count_diff(truth, detected) ++ slot_diffs(truth["slots"], detected["slots"])
    %{ok?: diffs == [], diffs: diffs, error: nil, summary: summarize(diffs)}
  end

  def compare("focused_enemies", truth, detected) do
    rects = truth["rects"]
    points = detected["enemies"]

    {matched, extra, claimed} =
      Enum.reduce(points, {[], [], MapSet.new()}, fn point, {matched, extra, claimed} ->
        index = rects |> Enum.with_index() |> Enum.find_index(fn {rect, i} -> not MapSet.member?(claimed, i) and inside?(rect, point) end)

        case index do
          nil -> {matched, [point | extra], claimed}
          i -> {[%{rect: Enum.at(rects, i), x: point["x"], y: point["y"]} | matched], extra, MapSet.put(claimed, i)}
        end
      end)

    missed = rects |> Enum.with_index() |> Enum.reject(fn {_rect, i} -> MapSet.member?(claimed, i) end) |> Enum.map(&elem(&1, 0))
    ok? = missed == [] and extra == []

    %{
      ok?: ok?,
      diffs: [],
      error: nil,
      matched: Enum.reverse(matched),
      missed: missed,
      extra: Enum.reverse(extra),
      summary: if(ok?, do: "ok", else: "#{length(missed)} missed, #{length(extra)} extra")
    }
  end

  def failure_count(%{kind: "chain_tray", diffs: diffs}), do: length(diffs)
  def failure_count(%{kind: "focused_enemies", missed: missed, extra: extra}), do: length(missed) + length(extra)
  def failure_count(_result), do: 1

  defp failure(id, kind, reason) do
    %{id: id, kind: kind, ok?: false, diffs: [], error: inspect(reason), summary: "detection failed: #{inspect(reason)}"}
  end

  defp kind_of(id), do: with(%{"kind" => kind} <- BattleDebug.get(id), do: kind)

  defp normalize(map), do: map |> Jason.encode!() |> Jason.decode!()

  defp inside?(%{"x" => x, "y" => y, "w" => w, "h" => h}, %{"x" => px, "y" => py}), do: px >= x and px <= x + w and py >= y and py <= y + h

  defp count_diff(%{"slots" => expected}, %{"slots" => actual}) when length(expected) != length(actual),
    do: [%{slot: nil, field: "slot_count", expected: length(expected), actual: length(actual)}]

  defp count_diff(_truth, _detected), do: []

  defp slot_diffs(expected, actual) do
    expected
    |> Enum.zip(actual)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{truth, detected}, i} -> slot_diff(truth, detected, i) end)
  end

  defp slot_diff(truth, detected, i) do
    start = field_diff(i, "sinner_start", truth["sinner_start"], detected["sinner_start"])

    start ++
      field_diff(i, "top_sin", truth["top"]["sin"], detected["top"]["sin"]) ++
      field_diff(i, "top_tier", truth["top"]["tier"], detected["top"]["tier"]) ++
      field_diff(i, "bottom_sin", truth["bottom"]["sin"], detected["bottom"]["sin"]) ++
      field_diff(i, "bottom_tier", truth["bottom"]["tier"], detected["bottom"]["tier"])
  end

  defp field_diff(_slot, _field, same, same), do: []
  defp field_diff(slot, field, expected, actual), do: [%{slot: slot, field: field, expected: expected, actual: actual}]

  defp summarize([]), do: "ok"

  defp summarize(diffs) do
    diffs
    |> Enum.frequencies_by(fn %{field: field} -> field |> String.split("_") |> List.last() end)
    |> Enum.map_join(", ", fn {kind, n} -> "#{n} #{kind}" end)
  end
end
