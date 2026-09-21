defmodule StarlightBot.Repo.Migrations.UpgradeBattleStrategyContext do
  use Ecto.Migration

  def up do
    %{rows: rows} = repo().query!("SELECT id, data FROM battle_strategies")

    Enum.each(rows, fn [id, json] ->
      new_data =
        case json && Jason.decode(json) do
          {:ok, %{"type" => type}} ->
            %{version: 2, mirror_dungeon: %{type: type}, luxcavation: %{type: type}}

          _ ->
            %{version: 2, mirror_dungeon: %{type: "chain"}, luxcavation: %{type: "chain"}}
        end

      repo().query!("UPDATE battle_strategies SET data = ? WHERE id = ?", [Jason.encode!(new_data), id])
    end)
  end
end
