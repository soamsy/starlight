defmodule StarlightBot.PlanClipboardTest do
  use ExUnit.Case, async: true

  alias StarlightBot.{BattlePlans, PlanClipboard}

  test "round trips a plan of the matching type" do
    text = PlanClipboard.encode(:gift_plans, "Saikai", %{"a" => 1})
    assert PlanClipboard.decode(text, :gift_plans) == {:ok, %{"a" => 1}}
  end

  test "rejects another plan type, other JSON and non-JSON" do
    text = PlanClipboard.encode(:gift_plans, "Saikai", %{})
    assert {:error, "That clipboard holds a gift plan, not a pack plan."} = PlanClipboard.decode(text, :pack_plans)
    assert {:error, _} = PlanClipboard.decode(~s({"x": 1}), :pack_plans)
    assert {:error, _} = PlanClipboard.decode("hello", :pack_plans)
  end

  test "rejects battle plans the editor can't load" do
    assert {:ok, _} = :battle_plans |> PlanClipboard.encode("T", BattlePlans.blank()) |> PlanClipboard.decode(:battle_plans)
    assert {:error, _} = :battle_plans |> PlanClipboard.encode("T", %{"version" => 3}) |> PlanClipboard.decode(:battle_plans)
    assert {:error, _} = :battle_plans |> PlanClipboard.encode("T", Map.put(BattlePlans.blank(), "profiles", [])) |> PlanClipboard.decode(:battle_plans)
  end
end
