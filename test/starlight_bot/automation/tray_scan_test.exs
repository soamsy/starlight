defmodule StarlightBot.Automation.TrayScanTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Automation.TrayScan

  defp profile(id, sinner, hook), do: %{id: id, sinner: sinner, locator_hook: hook, base_locator_hook: nil}

  defp all do
    [
      profile(1, "faust", "faust_a"),
      profile(2, "faust", "faust_b"),
      profile(3, "ryoshu", "ryoshu_a"),
      profile(4, "ryoshu", "ryoshu_b"),
      profile(5, "gregor", nil)
    ]
  end

  defp holder(who, sinners, extra \\ %{}), do: Map.merge(%{"who" => who, "sinners" => sinners, "row" => "top"}, extra)

  defp ids(wanted, planned), do: wanted |> TrayScan.candidates(all(), planned) |> Enum.map(& &1.id)

  test "everyone needs no scan at all" do
    assert ids(TrayScan.wanted([holder("everyone", [])]), %{}) == []
  end

  test "a sinner with a profile subset scans only that subset" do
    assert ids(TrayScan.wanted([holder("only", ["faust"])]), %{"faust" => [2]}) == [2]
  end

  test "a sinner with no profile in the plan scans every profile of that sinner" do
    assert ids(TrayScan.wanted([holder("only", ["ryoshu"])]), %{"faust" => [1]}) == [3, 4]
  end

  test "sinners from the entry and its remaining skills are scanned together, once each" do
    entry = holder("only", ["faust"], %{"rest" => holder("except", ["ryoshu", "faust"])})
    wanted = TrayScan.wanted([entry])

    assert wanted.sinners == ["faust", "ryoshu"]
    assert ids(wanted, %{"faust" => [1]}) == [1, 3, 4]
  end

  test "a-res+def or an affinity dodge anywhere scans every profile that has a hook" do
    a_res_def = holder("only", ["faust"], %{"mode" => "a_res_def"})
    affinity = holder("everyone", [], %{"priority" => %{"order" => ["dodge+wrath"]}})
    nested = holder("only", ["faust"], %{"rest" => affinity})

    for entry <- [a_res_def, nested] do
      wanted = TrayScan.wanted([entry])
      assert wanted.defense?
      assert ids(wanted, %{"faust" => [1]}) == [1, 2, 3, 4]
    end
  end

  test "pins are merged into one request" do
    wanted = TrayScan.wanted([holder("only", ["faust"]), holder("only", ["ryoshu"], %{"mode" => "a_res_def"})])

    assert wanted.defense?
    assert wanted.sinners == ["faust", "ryoshu"]
  end

  test "a chain in a-res+def mode needs the defense scan even with no pins" do
    assert TrayScan.wanted([], defense?: true).defense?
  end
end
