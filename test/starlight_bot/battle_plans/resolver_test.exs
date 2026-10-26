defmodule StarlightBot.BattlePlans.ResolverTest do
  use ExUnit.Case, async: true

  alias StarlightBot.BattlePlans.Resolver

  @data %{
    "playbooks" => [
      %{"id" => "fast", "kind" => "chain", "actions" => [%{"type" => "chain_fast"}]},
      %{
        "id" => "boss",
        "kind" => "chain",
        "actions" => [
          %{"type" => "dodge"},
          %{
            "type" => "schedule",
            "segments" => [
              %{"from_turn" => 1, "actions" => [%{"type" => "chain_a_res"}]},
              %{"from_turn" => 5, "actions" => [%{"type" => "win_rate"}, %{"type" => "commit"}]}
            ]
          }
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

  describe "lineup_for/3" do
    @lineups %{
      "lineups" => [%{"id" => "full", "name" => "Full", "sinners" => ["ryoshu", "sinclair"]}, %{"id" => "solo", "name" => "Solo", "sinners" => ["ryoshu"]}],
      "lineup_tracks" => %{
        "md_battle" => [%{"from_floor" => 1, "lineup" => "full"}],
        "md_boss" => [%{"from_floor" => 1, "lineup" => "full"}, %{"from_floor" => 5, "lineup" => "solo"}]
      }
    }

    test "picks the lineup painted for the venue and floor" do
      assert Resolver.lineup_for(@lineups, "md_boss", 4)["id"] == "full"
      assert Resolver.lineup_for(@lineups, "md_boss", 5)["id"] == "solo"
      assert Resolver.lineup_for(@lineups, "md_battle", 5)["id"] == "full"
    end

    test "returns nil for an unassigned venue or a plan without lineups" do
      assert Resolver.lineup_for(@lineups, "lux", 1) == nil
      assert Resolver.lineup_for(%{"playbooks" => []}, "md_battle", 1) == nil
      assert Resolver.lineup_for(nil, "md_battle", 1) == nil
    end
  end

  describe "actions_for/2" do
    test "plain actions apply every turn and the split turn itself adopts the new tab" do
      boss = Resolver.playbook_for(@data, "hard_chain", 5)
      types = fn turn -> boss |> Resolver.actions_for(turn) |> Enum.map(& &1["type"]) end

      assert types.(1) == ["dodge", "chain_a_res"]
      assert types.(4) == ["dodge", "chain_a_res"]
      assert types.(5) == ["dodge", "win_rate", "commit"]
      assert types.(9) == ["dodge", "win_rate", "commit"]
    end
  end
end
