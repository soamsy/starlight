defmodule StarlightBot.Repo.Migrations.BattleStrategyLineups do
  use Ecto.Migration

  @venues ~w(md_battle md_boss lux)

  def up do
    %{rows: team_rows} = repo().query!("SELECT battle_strategy_id, sinner_order FROM teams WHERE battle_strategy_id IS NOT NULL ORDER BY id")

    orders =
      Enum.reduce(team_rows, %{}, fn [strategy_id, json], acc ->
        case Jason.decode(json || "") do
          {:ok, [_ | _] = order} -> Map.put_new(acc, strategy_id, order)
          _ -> acc
        end
      end)

    %{rows: rows} = repo().query!("SELECT id, data FROM battle_strategies")

    Enum.each(rows, fn [id, json] ->
      with {:ok, %{} = data} <- Jason.decode(json || ""),
           false <- Map.has_key?(data, "lineups") do
        lineup = %{"id" => "ln_" <> Base.encode32(:crypto.strong_rand_bytes(4), case: :lower, padding: false), "name" => "Lineup", "sinners" => Map.get(orders, id, [])}

        upgraded =
          data
          |> Map.put("lineups", [lineup])
          |> Map.put("lineup_tracks", Map.new(@venues, &{&1, [%{"from_floor" => 1, "lineup" => lineup["id"]}]}))

        repo().query!("UPDATE battle_strategies SET data = ? WHERE id = ?", [Jason.encode!(upgraded), id])
      end
    end)

    alter table(:teams) do
      remove :sinner_order
    end
  end

  def down do
    alter table(:teams) do
      add :sinner_order, :string
    end
  end
end
