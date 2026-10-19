defmodule StarlightBot.Repo.Migrations.TrayCountConditions do
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
        |> Map.update("condition", nil, &upgrade_node/1)
        |> Map.update("then", [], &upgrade_actions/1)
        |> Map.update("else", [], &upgrade_actions/1)

      action ->
        action
    end)
  end

  defp upgrade_node(%{"children" => children} = node), do: %{node | "children" => Enum.map(children, &upgrade_node/1)}

  defp upgrade_node(%{"op" => "tray_has_sin", "sin" => sin}),
    do: %{"op" => "tray_count", "match" => sin, "cmp" => "gte", "value" => 1, "profile_id" => nil}

  defp upgrade_node(node), do: node
end
