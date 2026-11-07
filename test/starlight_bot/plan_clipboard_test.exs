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

  test "round trips a milestone and rejects other clipboards" do
    milestone = %{"id" => "ms_a", "name" => "Shop", "entries" => [], "goals" => []}
    assert {:ok, ^milestone} = milestone |> PlanClipboard.encode_milestone() |> PlanClipboard.decode_milestone()
    assert {:error, "That clipboard holds a whole gift plan, not a milestone."} = :gift_plans |> PlanClipboard.encode("T", %{}) |> PlanClipboard.decode_milestone()
    assert {:error, _} = PlanClipboard.decode_milestone("hello")
    assert {:error, _} = PlanClipboard.decode_milestone(~s({"starlight_milestone": {"id": "a", "name": "b", "entries": "x"}}))
    assert {:error, _} = PlanClipboard.decode_milestone(~s({"starlight_milestone": {"id": "a", "name": "b", "entries": [{"id": "e"}]}}))
  end

  test "round trips a playbook of the matching kind and rejects the rest" do
    playbook = BattlePlans.new_playbook("chain", "Chain fast")
    text = PlanClipboard.encode_playbook(playbook)
    assert {:ok, ^playbook} = PlanClipboard.decode_playbook(text, "chain")
    assert {:error, "That clipboard holds a chain playbook, not a focused playbook."} = PlanClipboard.decode_playbook(text, "focused")
    assert {:error, "That clipboard holds a whole battle plan, not a playbook."} = :battle_plans |> PlanClipboard.encode("T", BattlePlans.blank()) |> PlanClipboard.decode_playbook("chain")
    assert {:error, _} = PlanClipboard.decode_playbook("hello", "chain")

    broken = %{playbook | "actions" => [%{"type" => "if", "then" => [%{"id" => "x"}], "else" => []}]}
    assert {:error, "That playbook is malformed and can't be pasted."} = broken |> PlanClipboard.encode_playbook() |> PlanClipboard.decode_playbook("chain")
  end

  test "round trips entries and rejects other clipboards" do
    entries = [%{"id" => "me_1", "floors" => []}]
    assert {:ok, ^entries} = entries |> PlanClipboard.encode_entries() |> PlanClipboard.decode_entries()
    assert {:error, _} = PlanClipboard.decode_entries("hello")
    assert {:error, _} = PlanClipboard.decode_entries(~s({"starlight_entries": []}))
    assert {:error, _} = PlanClipboard.decode_entries(~s({"starlight_entries": [{"id": "e"}]}))
    assert {:error, _} = PlanClipboard.decode_entries(PlanClipboard.encode_milestone(%{"id" => "a", "name" => "b"}))
  end
  test "clipboard text carries a format version and rejects newer ones" do
    assert %{"v" => 1} = :gift_plans |> PlanClipboard.encode("T", %{}) |> Jason.decode!()
    assert %{"v" => 1} = %{"id" => "a", "name" => "b"} |> PlanClipboard.encode_milestone() |> Jason.decode!()
    newer = ~s({"v": 2, "starlight_milestone": {"id": "a", "name": "b"}})
    assert {:error, "That clipboard was made by a newer version" <> _} = PlanClipboard.decode_milestone(newer)
    assert {:ok, _} = PlanClipboard.decode_milestone(~s({"starlight_milestone": {"id": "a", "name": "b"}}))
  end

  test "plan data from a newer version is rejected" do
    for {table, data} <- [gift_plans: %{"version" => 99}, pack_plans: %{"version" => 99}, battle_plans: %{"version" => 99}] do
      assert {:error, "That clipboard was made by a newer version" <> _} = table |> PlanClipboard.encode("T", data) |> PlanClipboard.decode(table)
    end
  end
end
