defmodule StarlightBot.BattlePlans.Resolver do
  def playbook_id_at(entries, floor), do: id_at(entries, floor, "playbook")

  def lineup_id_at(entries, floor), do: id_at(entries, floor, "lineup")

  defp id_at(entries, floor, key) when is_list(entries) do
    entries
    |> Enum.filter(&(&1["from_floor"] <= floor))
    |> Enum.max_by(& &1["from_floor"], fn -> nil end)
    |> case do
      nil -> nil
      entry -> entry[key]
    end
  end

  defp id_at(_entries, _floor, _key), do: nil

  def playbook_for(%{"tracks" => tracks, "playbooks" => playbooks}, track, floor) do
    id = playbook_id_at(tracks[track], floor)
    Enum.find(playbooks, &(&1["id"] == id))
  end

  def playbook_for(_data, _track, _floor), do: nil

  def lineup_for(data, venue, floor) when is_map(data) do
    id = lineup_id_at(get_in(data, ["lineup_tracks", venue]), floor)
    Enum.find(data["lineups"] || [], &(&1["id"] == id))
  end

  def lineup_for(_data, _venue, _floor), do: nil

  def actions_for(%{"actions" => items}, turn) do
    Enum.flat_map(items, fn
      %{"type" => "schedule"} = schedule ->
        case StarlightBot.BattlePlans.segment_at(schedule, turn) do
          nil -> []
          segment -> segment["actions"]
        end

      action ->
        [action]
    end)
  end
end
