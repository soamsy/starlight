defmodule StarlightBot.GiftPlans.CombosTest do
  use ExUnit.Case, async: true

  alias StarlightBot.GiftPlans.Combos

  defp by_shops(target_tier, shops) do
    target_tier
    |> Combos.valid_combos()
    |> Enum.filter(&(&1.shops == shops))
    |> Enum.map(& &1.combo)
  end

  describe "valid_combos/1" do
    test "T4 combos usable in both shops are capped at 3 ingredients" do
      assert by_shops(4, [:normal, :super]) == [[4, 4], [4, 3], [3, 3, 3], [4, 2, 2], [3, 3, 2]]
    end

    test "T4 super-only combos use the lower threshold and up to 5 ingredients" do
      super_only = by_shops(4, [:super])
      assert [3, 2, 2] in super_only
      assert [2, 2, 2, 2] in super_only
      assert [2, 2, 2, 1, 1] in super_only
      assert Enum.all?(super_only, &(length(&1) <= 5))
      assert by_shops(4, [:normal]) == []
    end

    test "T3 3+2+2 only works in a normal shop because super pushes it to T4" do
      assert [3, 2, 2] in by_shops(3, [:normal])
      assert [2, 2, 2] in by_shops(3, [:normal, :super])
    end

    test "every listed combo is minimal" do
      for %{combo: combo, shops: shops} <- Combos.valid_combos(4), shop <- shops do
        assert Combos.allowed?(combo, 4, shop)
      end
    end
  end

  describe "allowed?/3" do
    test "rejects combos over the ingredient cap" do
      refute Combos.allowed?([2, 2, 2, 2, 2], 4, :normal)
      assert Combos.allowed?([2, 2, 2, 2, 2], 4, :super)
    end

    test "rejects combos that land on the wrong tier" do
      refute Combos.allowed?([3, 2, 2], 4, :normal)
      assert Combos.allowed?([3, 2, 2], 4, :super)
    end
  end

  test "keyword_odds/1 follows ingredient count" do
    assert Combos.keyword_odds([4, 3]) == 60
    assert Combos.keyword_odds([3, 3, 2]) == 90
    assert Combos.keyword_odds([2, 2, 2, 2]) == 99
  end

  test "combo keys round-trip" do
    assert [3, 3, 2] |> Combos.combo_key() |> Combos.parse_combo_key() == [3, 3, 2]
  end
end
