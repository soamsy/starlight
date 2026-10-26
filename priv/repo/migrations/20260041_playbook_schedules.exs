defmodule StarlightBot.Repo.Migrations.PlaybookSchedules do
  use Ecto.Migration

  def up do
    %{rows: rows} = repo().query!("SELECT id, data FROM battle_plans")

    Enum.each(rows, fn [id, json] ->
      with {:ok, %{"version" => 3, "playbooks" => playbooks} = data} when is_list(playbooks) <- Jason.decode(json || "") do
        upgraded = data |> Map.put("version", 4) |> Map.put("playbooks", Enum.map(playbooks, &upgrade/1))
        repo().query!("UPDATE battle_plans SET data = ? WHERE id = ?", [Jason.encode!(upgraded), id])
      end
    end)
  end

  def down, do: :ok

  defp upgrade(%{"phases" => phases} = playbook) do
    phases = Enum.sort_by(phases, & &1["from_turn"])

    actions =
      case phases do
        [only] -> only["actions"]
        _ -> [%{"id" => new_id("sc"), "type" => "schedule", "segments" => phases}]
      end

    playbook |> Map.delete("phases") |> Map.put("actions", actions)
  end

  defp upgrade(playbook), do: playbook

  defp new_id(prefix), do: prefix <> "_" <> Base.encode32(:crypto.strong_rand_bytes(4), case: :lower, padding: false)
end
