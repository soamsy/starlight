defmodule StarlightBot.Repo.Migrations.MountingTrialsSchedule do
  use Ecto.Migration

  def up do
    %{rows: rows} = repo().query!("SELECT id, data FROM gift_plans")

    Enum.each(rows, fn [id, json] ->
      with {:ok, %{} = data} <- Jason.decode(json || ""), false <- Map.has_key?(data, "mounting_trials") do
        data = Map.put(data, "mounting_trials", [%{"from_floor" => 1, "mode" => "avoid_hp"}])
        repo().query!("UPDATE gift_plans SET data = ? WHERE id = ?", [Jason.encode!(data), id])
      end
    end)
  end

  def down, do: :ok
end
