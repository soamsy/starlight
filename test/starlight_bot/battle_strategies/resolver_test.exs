defmodule StarlightBot.BattleStrategies.ResolverTest do
  use ExUnit.Case, async: true

  alias StarlightBot.BattleStrategies.Resolver

  @data %{
    "playbooks" => [
      %{"id" => "fast", "kind" => "chain", "phases" => [%{"from_turn" => 1, "actions" => [%{"type" => "chain_fast"}]}]},
      %{
        "id" => "boss",
        "kind" => "chain",
        "phases" => [
          %{"from_turn" => 1, "actions" => [%{"type" => "dodge"}, %{"type" => "chain_a_res"}]},
          %{"from_turn" => 5, "actions" => [%{"type" => "win_rate"}, %{"type" => "commit"}]}
        ]
      }
    ],
    "tracks" => %{
      "hard_chain" => [%{"from_floor" => 1, "playbook" => "fast"}, %{"from_floor" => 5, "playbook" => "boss"}]
    }
  }

  describe "playbook_id_at/2" do
    test "applies a change point until the next one" do
      entries = @data["tracks"]["hard_chain"]

      assert Resolver.playbook_id_at(entries, 1) == "fast"
      assert Resolver.playbook_id_at(entries, 4) == "fast"
      assert Resolver.playbook_id_at(entries, 5) == "boss"
      assert Resolver.playbook_id_at(entries, 15) == "boss"
    end

    test "returns nil for a missing track" do
      assert Resolver.playbook_id_at(nil, 3) == nil
    end
  end

  describe "phase_for/2" do
    test "the split turn itself adopts the new phase" do
      boss = Resolver.playbook_for(@data, "hard_chain", 5)

      assert Resolver.phase_for(boss, 4)["from_turn"] == 1
      assert Resolver.phase_for(boss, 5)["from_turn"] == 5
      assert Resolver.phase_for(boss, 9)["from_turn"] == 5
    end
  end
end
