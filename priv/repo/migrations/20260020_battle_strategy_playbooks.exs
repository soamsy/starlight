defmodule StarlightBot.Repo.Migrations.BattleStrategyPlaybooks do
  use Ecto.Migration

  @chain_playbooks %{
    "chain" => {"Chain fast", [%{"type" => "chain_fast", "pins" => []}]},
    "chain_a_res" => {"Chain A-Res", [%{"type" => "chain_a_res", "pins" => []}]},
    "win_rate" => {"Win rate (chain)", [%{"type" => "win_rate"}, %{"type" => "commit"}]}
  }

  def up do
    %{rows: rows} = repo().query!("SELECT id, data FROM battle_strategies")

    Enum.each(rows, fn [id, json] ->
      data =
        case json && Jason.decode(json) do
          {:ok, %{} = decoded} -> decoded
          _ -> %{}
        end

      unless data["version"] == 3 do
        repo().query!("UPDATE battle_strategies SET data = ? WHERE id = ?", [Jason.encode!(upgrade(data)), id])
      end
    end)
  end

  defp upgrade(data) do
    md_type = chain_type(get_in(data, ["mirror_dungeon", "type"]))
    lux_type = chain_type(get_in(data, ["luxcavation", "type"]))

    chain_playbooks =
      [md_type, lux_type]
      |> Enum.uniq()
      |> Enum.map(fn type ->
        {name, actions} = @chain_playbooks[type]
        playbook("pb_" <> type, name, "chain", actions)
      end)

    focused = playbook("pb_focused", "Win rate", "focused", [%{"type" => "win_rate"}, %{"type" => "commit"}])

    %{
      "version" => 3,
      "playbooks" => chain_playbooks ++ [focused],
      "tracks" => %{
        "normal_chain" => [entry("pb_" <> md_type)],
        "hard_chain" => [entry("pb_" <> md_type)],
        "lux_chain" => [entry("pb_" <> lux_type)],
        "normal_focused" => [entry("pb_focused")],
        "hard_focused" => [entry("pb_focused")],
        "lux_focused" => [entry("pb_focused")]
      }
    }
  end

  defp chain_type(type) when type in ["chain", "chain_a_res", "win_rate"], do: type
  defp chain_type(_type), do: "chain"

  defp playbook(id, name, kind, actions) do
    actions = actions |> Enum.with_index(1) |> Enum.map(fn {action, i} -> Map.put(action, "id", "#{id}_ac#{i}") end)
    %{"id" => id, "name" => name, "kind" => kind, "phases" => [%{"from_turn" => 1, "actions" => actions}]}
  end

  defp entry(playbook_id), do: %{"from_floor" => 1, "playbook" => playbook_id}
end
