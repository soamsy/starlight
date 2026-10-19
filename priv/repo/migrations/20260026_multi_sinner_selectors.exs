defmodule StarlightBot.Repo.Migrations.MultiSinnerSelectors do
  use Ecto.Migration

  def up do
    %{rows: rows} = repo().query!("SELECT id, data FROM battle_strategies")

    Enum.each(rows, fn [id, json] ->
      with {:ok, %{"playbooks" => playbooks} = data} when is_list(playbooks) <- Jason.decode(json || "") do
        upgraded = Map.put(data, "playbooks", Enum.map(playbooks, &upgrade_playbook/1))

        if upgraded != data do
          repo().query!("UPDATE battle_strategies SET data = ? WHERE id = ?", [Jason.encode!(upgraded), id])
        end
      end
    end)
  end

  def down, do: :ok

  defp upgrade_playbook(playbook) do
    Map.update(playbook, "phases", [], fn phases ->
      Enum.map(phases, fn phase -> Map.update(phase, "actions", [], &upgrade_actions/1) end)
    end)
  end

  defp upgrade_actions(actions) do
    Enum.map(actions, fn
      %{"type" => "if"} = block ->
        block
        |> Map.update("then", [], &upgrade_actions/1)
        |> Map.update("else", [], &upgrade_actions/1)

      %{"pins" => pins} = action when is_list(pins) ->
        Map.put(action, "pins", Enum.map(pins, &upgrade_selector/1))

      %{"type" => type} = action when type in ~w(dodge ego target) ->
        upgrade_selector(action)

      action ->
        action
    end)
  end

  defp upgrade_selector(holder) do
    {profile_id, holder} = Map.pop(holder, "profile_id")
    {except, holder} = Map.pop(holder, "except")

    if Map.has_key?(holder, "profile_ids") do
      holder
    else
      holder
      |> Map.put("who", if(except == true, do: "except", else: "only"))
      |> Map.put("profile_ids", if(is_integer(profile_id), do: [profile_id], else: []))
    end
  end
end
