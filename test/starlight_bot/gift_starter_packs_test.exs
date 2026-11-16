defmodule StarlightBot.GiftStarterPacksTest do
  use ExUnit.Case, async: false

  alias StarlightBot.{BaseRepo, Data, GiftStarterPacks, Repo}

  setup do
    :ok = StarlightBot.TestDB.checkout()
    Repo.query!("DELETE FROM gift_starter_packs")
    BaseRepo.query!("DELETE FROM gift_starter_packs")
    :ok
  end

  defp with_mode(mode) do
    original = Application.get_env(:starlight_bot, :data_paths)
    Application.put_env(:starlight_bot, :data_paths, %{original | mode: mode})
    Data.reset_cache()

    on_exit(fn ->
      Application.put_env(:starlight_bot, :data_paths, original)
      Data.reset_cache()
    end)
  end

  test "authoring mode writes shipped packs" do
    assert {:ok, "b:" <> _ = ref} = GiftStarterPacks.create("Burn opener", "burn")
    assert %{source: :base, editable: true, affinity: "burn", name: "Burn opener"} = GiftStarterPacks.get(ref)
    assert [%{ref: ^ref}] = GiftStarterPacks.list()
  end

  test "user mode writes user packs and locks shipped ones" do
    {:ok, shipped} = GiftStarterPacks.create("Shipped", "any")
    with_mode(:user)
    {:ok, "u:" <> _ = mine} = GiftStarterPacks.create("Mine", "slash")

    assert [%{ref: ^shipped, source: :base, editable: false}, %{ref: ^mine, source: :user, editable: true}] = GiftStarterPacks.list()
    assert {:error, :read_only} = GiftStarterPacks.save(shipped, %{name: "Changed"})
    assert {:error, :not_deletable} = GiftStarterPacks.delete(shipped)
    assert {:ok, ^mine} = GiftStarterPacks.save(mine, %{name: "Renamed", affinity: "burn"})
    assert %{name: "Renamed", affinity: "burn"} = GiftStarterPacks.get(mine)
    assert :ok = GiftStarterPacks.delete(mine)
    assert GiftStarterPacks.get(mine) == nil
  end

  test "notes default to empty and round trip" do
    {:ok, ref} = GiftStarterPacks.create("Noted", "any")
    assert GiftStarterPacks.get(ref).notes == ""
    assert {:ok, ^ref} = GiftStarterPacks.save(ref, %{notes: "Good for F1"})
    assert GiftStarterPacks.get(ref).notes == "Good for F1"
    assert {:ok, ^ref} = GiftStarterPacks.save(ref, %{name: "Renamed"})
    assert GiftStarterPacks.get(ref).notes == "Good for F1"
  end

  test "usage counts plans and shipped plan templates that reference a pack" do
    {:ok, ref} = GiftStarterPacks.create("Used", "any")
    {:ok, other} = GiftStarterPacks.create("Unused", "any")
    plan = fn refs -> %{"sections" => [%{"packs" => Enum.map(refs, &%{"id" => "sp", "ref" => &1})}]} end
    {:ok, _} = StarlightBot.Plans.save(:gift_plans, %{name: "A", data: plan.([ref])})
    {:ok, _} = StarlightBot.Plans.save(:gift_plans, %{name: "B", data: plan.([ref, other])})
    {:ok, _} = StarlightBot.Plans.save(:gift_plans, %{name: "C", data: plan.([other])})
    {:ok, _} = StarlightBot.PlanTemplates.create(:gift_plans, plan.([ref]))

    assert GiftStarterPacks.usage_count(ref) == 3
    assert GiftStarterPacks.usage_count(other) == 2
    assert GiftStarterPacks.usage_count("b:999") == 0
  end

  test "names must be unique across both layers and affinities must be valid" do
    {:ok, _} = GiftStarterPacks.create("Same", "any")
    assert {:error, :name_taken} = GiftStarterPacks.create("Same", "burn")
    assert {:error, :bad_affinity} = GiftStarterPacks.create("Other", "fire")
    assert {:error, :blank_name} = GiftStarterPacks.create("  ", "any")
  end

  test "pack data round trips and groups put the plan's affinity first" do
    {:ok, burn} = GiftStarterPacks.create("B", "burn")
    {:ok, _any} = GiftStarterPacks.create("A", "any")
    {:ok, _slash} = GiftStarterPacks.create("C", "slash")
    pack = GiftStarterPacks.get(burn)
    section = %{GiftStarterPacks.section(pack) | "entries" => [%{"id" => "me_1", "subject" => %{"gift" => "X"}, "fusion" => nil, "floors" => [%{"from" => 1}]}]}

    assert {:ok, ^burn} = GiftStarterPacks.save(burn, %{data: %{pack.data | "sections" => [section]}})
    assert [%{"id" => "me_1"}] = GiftStarterPacks.section(GiftStarterPacks.get(burn))["entries"]
    assert ["burn", "any", "slash"] == "burn" |> then(&GiftStarterPacks.grouped(GiftStarterPacks.list(), &1)) |> Enum.map(&elem(&1, 0))
    assert "New starter pack" == GiftStarterPacks.default_name()
  end
end
