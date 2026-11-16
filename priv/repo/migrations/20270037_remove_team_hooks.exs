defmodule StarlightBot.Repo.Migrations.RemoveTeamHooks do
  use Ecto.Migration

  @pick_fields [{"team_ids", "team_hooks"}, {"reserve_ids", "reserve_hooks"}, {"exp_team_ids", "exp_team_hooks"}, {"thread_team_ids", "thread_team_hooks"}]

  def up do
    flush()

    team_hooks =
      "SELECT id, hooks FROM teams"
      |> repo().query!()
      |> Map.fetch!(:rows)
      |> Map.new(fn [id, json] -> {id, decode_list(json)} end)

    "SELECT runner, params FROM runner_forms"
    |> repo().query!()
    |> Map.fetch!(:rows)
    |> Enum.each(fn [runner, json] ->
      params = backfill(Jason.decode!(json), team_hooks)
      repo().query!("UPDATE runner_forms SET params = ?1 WHERE runner = ?2", [Jason.encode!(params), runner])
    end)

    alter table(:teams) do
      remove :hooks
    end
  end

  def down do
    alter table(:teams) do
      add :hooks, :text, null: false, default: "[]"
    end
  end

  defp backfill(params, team_hooks) do
    Enum.reduce(@pick_fields, params, fn {ids_key, hooks_key}, acc ->
      case Map.get(acc, ids_key) do
        ids when is_list(ids) ->
          hooks = List.wrap(Map.get(acc, hooks_key)) ++ List.duplicate(nil, length(ids))
          Map.put(acc, hooks_key, ids |> Enum.zip(hooks) |> Enum.map(fn {id, hook} -> resolve(id, hook, team_hooks) end))

        _ ->
          acc
      end
    end)
  end

  defp resolve(id, hook, team_hooks) do
    available =
      case Integer.parse(to_string(id)) do
        {n, ""} -> Map.get(team_hooks, n, [])
        _ -> []
      end

    if hook in available, do: hook, else: List.first(available) || ""
  end

  defp decode_list(json) do
    case Jason.decode(json || "") do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end
end
