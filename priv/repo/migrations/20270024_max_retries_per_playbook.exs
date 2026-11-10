defmodule StarlightBot.Repo.Migrations.MaxRetriesPerPlaybook do
  use Ecto.Migration

  def up do
    %{rows: rows} = repo().query!(~s|SELECT id, data FROM battle_plans WHERE data LIKE '%"playbooks"%'|)

    for [id, json] <- rows do
      data = json |> Jason.decode!() |> convert()
      repo().query!("UPDATE battle_plans SET data = ? WHERE id = ?", [Jason.encode!(data), id])
    end
  end

  def down, do: :ok

  defp convert(%{"playbooks" => playbooks} = data) when is_list(playbooks) do
    {retries, rest} = Map.pop(data, "max_retries")
    retries = if is_integer(retries) and retries >= 0, do: retries, else: 5
    %{rest | "playbooks" => Enum.map(playbooks, &Map.put_new(&1, "max_retries", retries))}
  end

  defp convert(data), do: data
end
