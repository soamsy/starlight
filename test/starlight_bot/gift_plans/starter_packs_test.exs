defmodule StarlightBot.GiftPlans.StarterPacksTest do
  use ExUnit.Case, async: true

  alias StarlightBot.GiftPlans

  defp entry(id, name, goal \\ "required", extra \\ %{}) do
    Map.merge(%{"id" => id, "subject" => %{"gift" => name}, "fusion" => nil, "floors" => [%{GiftPlans.default_segment() | "goal" => goal}]}, extra)
  end

  defp pack(entries, goals \\ []) do
    %{ref: "b:1", data: %{"version" => 6, "sections" => [%{"id" => "ms_pack", "goals" => goals, "entries" => entries, "refresh" => []}]}}
  end

  defp plan(stage_entries, stage_goals \\ [], packs \\ [%{"id" => "sp_1", "ref" => "b:1"}]) do
    %{
      "version" => 6,
      "sections" => [%{"id" => "ms_root", "goals" => stage_goals, "entries" => stage_entries, "refresh" => [], "packs" => packs}]
    }
  end

  defp resolver(pack), do: fn "b:1" -> pack; _ -> nil end
  defp root(data), do: hd(data["sections"])
  defp goal_of(entry), do: hd(entry["floors"])["goal"]

  test "pack entries are appended with deterministic ids" do
    data = plan([entry("me_1", "Own")])
    expanded = GiftPlans.expand_packs(data, resolver(pack([entry("pe_1", "Packed")])))

    assert [%{"id" => "me_1"}, %{"id" => "ms_root~sp_1~pe_1", "subject" => %{"gift" => "Packed"}}] = root(expanded)["entries"]
    assert GiftPlans.expand_packs(data, resolver(pack([entry("pe_1", "Packed")]))) == expanded
  end

  test "a stage entry for the same gift replaces the pack entry wholesale" do
    data = plan([entry("me_1", "Shared", "optional")])
    view = data |> GiftPlans.pack_views(resolver(pack([entry("pe_1", "Shared"), entry("pe_2", "Other")]))) |> Map.fetch!("ms_root") |> hd()

    assert [%{shadowed: true}, %{shadowed: false}] = view.entries

    names = data |> GiftPlans.expand_packs(resolver(pack([entry("pe_1", "Shared"), entry("pe_2", "Other")]))) |> root() |> Map.fetch!("entries") |> Enum.map(& &1["subject"]["gift"])
    assert names == ["Shared", "Other"]
  end

  test "an earlier pack beats a later one for the same gift" do
    first = %{ref: "b:1", data: pack([entry("a", "Shared")]).data}
    second = %{ref: "b:2", data: pack([entry("b", "Shared")]).data}
    data = plan([], [], [%{"id" => "sp_1", "ref" => "b:1"}, %{"id" => "sp_2", "ref" => "b:2"}])
    lookup = fn "b:1" -> first; "b:2" -> second end

    assert [%{"id" => "ms_root~sp_1~a"}] = data |> GiftPlans.expand_packs(lookup) |> root() |> Map.fetch!("entries")
  end

  test "pack goals get letters the stage does not use and count only pack members" do
    source = pack([entry("pe_1", "One", "A"), entry("pe_2", "Two", "A"), entry("pe_3", "Three", "A")], [%{"letter" => "A", "min" => 2}])
    data = plan([entry("me_1", "Own", "A")], [%{"letter" => "A", "min" => 1}])
    section = data |> GiftPlans.expand_packs(resolver(source)) |> root()

    assert Enum.map(section["goals"], & &1["letter"]) == ["A", "B"]
    assert Enum.find(section["goals"], &(&1["letter"] == "B"))["min"] == 2
    assert Enum.map(section["entries"], &goal_of/1) == ["A", "B", "B", "B"]
  end

  test "goal minimums shrink to the surviving members and empty goals disappear" do
    source = pack([entry("pe_1", "One", "A"), entry("pe_2", "Two", "A"), entry("pe_3", "Three", "B")], [%{"letter" => "A", "min" => 2}, %{"letter" => "B", "min" => 1}])
    data = plan([entry("me_1", "One"), entry("me_2", "Three")])
    section = data |> GiftPlans.expand_packs(resolver(source)) |> root()

    assert [%{"letter" => "A", "min" => 1}] = section["goals"]
    assert section["entries"] |> Enum.map(&goal_of/1) |> Enum.take(-1) == ["A"]
  end

  test "a missing pack is skipped and reported" do
    data = plan([entry("me_1", "Own")])

    assert GiftPlans.expand_packs(data, fn _ -> nil end) |> root() |> Map.fetch!("entries") |> length() == 1
    assert ["Shopping list: a starter pack no longer exists."] = GiftPlans.issues(data)
  end

  test "schedules in pack entries survive expansion with their group prefixed" do
    scheduled = entry("pe_1", "Timed", "required", %{"group" => "grp_x", "scheduled" => true, "floors" => [%{GiftPlans.default_segment() | "from" => 1}, %{GiftPlans.default_segment() | "from" => 4, "disposition" => "ignore"}]})
    [expanded] = plan([]) |> GiftPlans.expand_packs(resolver(pack([scheduled]))) |> root() |> Map.fetch!("entries")

    assert expanded["group"] == "ms_root~sp_1~grp_x"
    assert length(expanded["floors"]) == 2
  end

  test "unpacking copies the unshadowed entries with fresh ids and real goals, then drops the reference" do
    source = pack([entry("pe_1", "Shared", "A"), entry("pe_2", "Other", "A")], [%{"letter" => "A", "min" => 2}])
    data = plan([entry("me_1", "Shared")], [%{"letter" => "A", "min" => 1}])
    unpacked = GiftPlans.unpack(data, "ms_root", "sp_1", resolver(source))
    section = root(unpacked)

    assert Map.has_key?(section, "packs") == false
    assert Enum.map(section["entries"], & &1["subject"]["gift"]) == ["Shared", "Other"]
    assert [%{"letter" => "A"}, %{"letter" => "B", "min" => 1}] = section["goals"]
    assert goal_of(List.last(section["entries"])) == "B"
    refute List.last(section["entries"])["id"] =~ "~"
  end

  test "normalizing keeps pack references" do
    assert [%{"ref" => "b:1"}] = plan([]) |> GiftPlans.normalize() |> root() |> Map.fetch!("packs")
  end

  test "add_pack ignores a pack already in the stage and remove_pack clears it" do
    data = plan([], [], [])
    added = data |> GiftPlans.add_pack("ms_root", "b:1") |> GiftPlans.add_pack("ms_root", "b:1")

    assert [%{"ref" => "b:1", "id" => id}] = root(added)["packs"]
    refute Map.has_key?(root(GiftPlans.remove_pack(added, "ms_root", id)), "packs")
  end

  defp two_stage_plan(packs) do
    %{
      "version" => 6,
      "sections" => [
        %{"id" => "ms_root", "goals" => [], "entries" => [], "refresh" => [], "packs" => packs},
        %{"id" => "ms_stage", "stage_of" => "ms_root", "name" => "Stage 2", "goals" => [], "entries" => [], "refresh" => []}
      ]
    }
  end

  test "moving a pack to another stage keeps its id and follows the given order" do
    data = two_stage_plan([%{"id" => "sp_1", "ref" => "b:1"}, %{"id" => "sp_2", "ref" => "b:2"}])
    moved = GiftPlans.move_pack(data, "ms_root", "ms_stage", "sp_1", ["sp_1"])

    assert [%{"id" => "sp_2"}] = GiftPlans.packs(GiftPlans.find_section(moved, "ms_root"))
    assert [%{"id" => "sp_1", "ref" => "b:1"}] = GiftPlans.packs(GiftPlans.find_section(moved, "ms_stage"))
  end

  test "moving a pack onto a stage already holding it just removes the source reference" do
    data = two_stage_plan([%{"id" => "sp_1", "ref" => "b:1"}])
    data = GiftPlans.add_pack(data, "ms_stage", "b:1")
    moved = GiftPlans.move_pack(data, "ms_root", "ms_stage", "sp_1", ["sp_1"])

    assert GiftPlans.packs(GiftPlans.find_section(moved, "ms_root")) == []
    assert [%{"ref" => "b:1"}] = GiftPlans.packs(GiftPlans.find_section(moved, "ms_stage"))
  end

  test "reordering packs changes which one wins an overlap" do
    data = two_stage_plan([%{"id" => "sp_1", "ref" => "b:1"}, %{"id" => "sp_2", "ref" => "b:2"}])
    first = %{ref: "b:1", data: pack([entry("a", "Shared", "required")]).data}
    second = %{ref: "b:2", data: pack([entry("b", "Shared", "optional")]).data}
    lookup = fn "b:1" -> first; "b:2" -> second end
    winner = fn data -> data |> GiftPlans.expand_packs(lookup) |> root() |> Map.fetch!("entries") |> hd() |> goal_of() end

    assert winner.(data) == "required"
    assert winner.(GiftPlans.reorder_packs(data, "ms_root", ["sp_2", "sp_1"])) == "optional"
  end
end
