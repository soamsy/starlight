defmodule StarlightBot.BattleStrategiesTest do
  use ExUnit.Case, async: true

  alias StarlightBot.BattleStrategies

  defp entry(floor, id), do: %{"from_floor" => floor, "playbook" => id}

  describe "blank/0" do
    test "every track starts with a floor 1 change point of the matching kind" do
      data = BattleStrategies.blank()
      kinds = Map.new(data["playbooks"], &{&1["id"], &1["kind"]})

      for track <- BattleStrategies.tracks() do
        assert [%{"from_floor" => 1, "playbook" => id}] = data["tracks"][track]
        assert kinds[id] == BattleStrategies.track_kind(track)
      end
    end
  end

  describe "paint/3" do
    test "adds a change point that runs until the next one" do
      assert BattleStrategies.paint([entry(1, "a")], 4, "b") == [entry(1, "a"), entry(4, "b")]
    end

    test "painting the playbook already covering a floor is a no-op" do
      assert BattleStrategies.paint([entry(1, "a"), entry(4, "b")], 6, "b") == [entry(1, "a"), entry(4, "b")]
    end

    test "merges into the next change point when it would repeat" do
      assert BattleStrategies.paint([entry(1, "a"), entry(4, "b")], 2, "b") == [entry(1, "a"), entry(2, "b")]
    end

    test "repainting floor 1 replaces it" do
      assert BattleStrategies.paint([entry(1, "a"), entry(4, "b")], 1, "b") == [entry(1, "b")]
    end
  end

  describe "erase/2" do
    test "removes a change point so its floors inherit" do
      assert BattleStrategies.erase([entry(1, "a"), entry(4, "b"), entry(6, "a")], 4) == [entry(1, "a")]
    end

    test "never removes floor 1" do
      assert BattleStrategies.erase([entry(1, "a")], 1) == [entry(1, "a")]
    end
  end

  describe "split_phase/2" do
    test "copies the covering phase's actions into the new phase" do
      playbook = BattleStrategies.new_playbook("focused", "Win rate")
      split = BattleStrategies.split_phase(playbook, 5)

      assert Enum.map(split["phases"], & &1["from_turn"]) == [1, 5]
      [first, second] = split["phases"]
      assert Enum.map(first["actions"], & &1["type"]) == Enum.map(second["actions"], & &1["type"])
      refute Enum.map(first["actions"], & &1["id"]) == Enum.map(second["actions"], & &1["id"])
    end
  end

  describe "profile_ids_used/1" do
    test "collects profiles from actions and pins" do
      data = %{
        "playbooks" => [
          %{
            "phases" => [
              %{
                "actions" => [
                  %{"type" => "dodge", "profile_id" => 1},
                  %{"type" => "chain_a_res", "pins" => [%{"profile_id" => 2}, %{"profile_id" => nil}]}
                ]
              }
            ]
          }
        ]
      }

      assert BattleStrategies.profile_ids_used(data) == MapSet.new([1, 2])
    end
  end
end
