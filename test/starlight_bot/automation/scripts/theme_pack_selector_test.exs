defmodule StarlightBot.Automation.Scripts.ThemePackSelectorTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Automation.Scripts.ThemePackSelector

  defp pack(id, normal_floors, hard_floors) do
    %{id: id, hook_name: "sleeve_#{id}", normal_floors: Jason.encode!(normal_floors), hard_floors: Jason.encode!(hard_floors)}
  end

  describe "packs_with_priority/5" do
    setup do
      %{
        packs: [
          pack("thm_hunt", [1, 2], [1, 2]),
          pack("thm_fine", [1, 2], [1, 2]),
          pack("thm_banned", [1, 2], [1, 2]),
          pack("thm_hard_only", [], [1, 2])
        ]
      }
    end

    test "filters by resolved priority at the given floor", %{packs: packs} do
      plan = %{
        "packs" => %{
          "thm_hunt" => %{"hard" => %{"priority" => "hunt"}},
          "thm_banned" => %{"hard" => %{"priority" => "banned"}}
        }
      }

      assert ThemePackSelector.packs_with_priority(plan, packs, "hard", 1, "hunt") |> Enum.map(& &1.id) == ["thm_hunt"]
      assert ThemePackSelector.packs_with_priority(plan, packs, "hard", 1, "banned") |> Enum.map(& &1.id) == ["thm_banned"]

      assert ThemePackSelector.packs_with_priority(plan, packs, "hard", 1, "fine") |> Enum.map(& &1.id) ==
               ["thm_fine", "thm_hard_only"]
    end

    test "excludes packs that don't appear in this mode at all", %{packs: packs} do
      assert ThemePackSelector.packs_with_priority(%{}, packs, "normal", 1, "fine") |> Enum.map(& &1.id) ==
               ["thm_hunt", "thm_fine", "thm_banned"]
    end

    test "respects per-floor scoping" do
      packs = [pack("thm_scoped", [1, 2, 3], [1, 2, 3])]
      plan = %{"packs" => %{"thm_scoped" => %{"normal" => %{"priority" => "hunt", "floors" => [2, 3]}}}}

      assert ThemePackSelector.packs_with_priority(plan, packs, "normal", 1, "hunt") == []
      assert ThemePackSelector.packs_with_priority(plan, packs, "normal", 2, "hunt") |> Enum.map(& &1.id) == ["thm_scoped"]
    end
  end

  describe "pick_winner/5" do
    test "returns :none for no matches" do
      assert ThemePackSelector.pick_winner([], %{}, %{}, "hard", 1) == :none
    end

    test "bonus beats hunt beats fine" do
      plan = %{
        "packs" => %{
          "thm_bonus" => %{"hard" => %{"priority" => "bonus"}},
          "thm_hunt" => %{"hard" => %{"priority" => "hunt"}}
        }
      }

      pack_a = pack("thm_hunt", [1], [1])
      pack_b = pack("thm_bonus", [1], [1])
      matched_pairs = [{pack_a, :hook_hunt}, {pack_b, :hook_bonus}]
      matched_hooks = %{hook_hunt: {1, 1, 10, 10}, hook_bonus: {2, 2, 10, 10}}

      assert ThemePackSelector.pick_winner(matched_pairs, matched_hooks, plan, "hard", 1) == {:ok, pack_b, {2, 2, 10, 10}}
    end

    test "falls back through the tiers when a higher one has no match" do
      plan = %{"packs" => %{"thm_hunt" => %{"hard" => %{"priority" => "hunt"}}}}
      pack_fine = pack("thm_fine", [1], [1])
      pack_hunt = pack("thm_hunt", [1], [1])

      matched_pairs = [{pack_fine, :hook_fine}, {pack_hunt, :hook_hunt}]
      matched_hooks = %{hook_fine: {0, 0, 5, 5}, hook_hunt: {9, 9, 5, 5}}

      assert ThemePackSelector.pick_winner(matched_pairs, matched_hooks, plan, "hard", 1) == {:ok, pack_hunt, {9, 9, 5, 5}}
    end

    test "ties within a tier keep the first match" do
      plan = %{"packs" => %{}}
      pack_a = pack("thm_a", [1], [1])
      pack_b = pack("thm_b", [1], [1])

      matched_pairs = [{pack_a, :hook_a}, {pack_b, :hook_b}]
      matched_hooks = %{hook_a: {0, 0, 1, 1}, hook_b: {1, 1, 1, 1}}

      assert ThemePackSelector.pick_winner(matched_pairs, matched_hooks, plan, "hard", 1) == {:ok, pack_a, {0, 0, 1, 1}}
    end
  end
end
