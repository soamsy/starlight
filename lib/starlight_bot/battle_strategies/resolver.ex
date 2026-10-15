defmodule StarlightBot.BattleStrategies.Resolver do
  def playbook_id_at(entries, floor) when is_list(entries) do
    entries
    |> Enum.filter(&(&1["from_floor"] <= floor))
    |> Enum.max_by(& &1["from_floor"], fn -> nil end)
    |> case do
      nil -> nil
      %{"playbook" => id} -> id
    end
  end

  def playbook_id_at(_entries, _floor), do: nil

  def playbook_for(%{"tracks" => tracks, "playbooks" => playbooks}, track, floor) do
    id = playbook_id_at(tracks[track], floor)
    Enum.find(playbooks, &(&1["id"] == id))
  end

  def playbook_for(_data, _track, _floor), do: nil

  def phase_for(%{"phases" => phases}, turn) do
    phases
    |> Enum.filter(&(&1["from_turn"] <= turn))
    |> Enum.max_by(& &1["from_turn"], fn -> nil end)
  end
end
