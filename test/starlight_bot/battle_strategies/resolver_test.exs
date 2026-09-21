defmodule StarlightBot.BattleStrategies.ResolverTest do
  use ExUnit.Case, async: true

  alias StarlightBot.BattleStrategies.Resolver

  describe "type_for/2" do
    test "reads the type for the requested context" do
      data = %{"mirror_dungeon" => %{"type" => "chain"}, "luxcavation" => %{"type" => "win_rate"}}

      assert Resolver.type_for(data, :mirror_dungeon) == "chain"
      assert Resolver.type_for(data, :luxcavation) == "win_rate"
    end

    test "defaults to chain when the context is missing from the data" do
      data = %{"mirror_dungeon" => %{"type" => "win_rate"}}

      assert Resolver.type_for(data, :luxcavation) == "chain"
    end

    test "defaults to chain for empty data" do
      assert Resolver.type_for(%{}, :mirror_dungeon) == "chain"
      assert Resolver.type_for(%{}, :luxcavation) == "chain"
    end

    test "defaults to chain for non-map data" do
      assert Resolver.type_for(nil, :mirror_dungeon) == "chain"
      assert Resolver.type_for("garbage", :luxcavation) == "chain"
    end
  end
end
