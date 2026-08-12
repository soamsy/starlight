defmodule StarlightBot.Automation.BattleChainTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Automation.BattleChain
  alias StarlightBot.Vision.SkillTray

  describe "pick_row/2" do
    test "prefers skill2 over skill1 and skill3, regardless of position" do
      assert BattleChain.pick_row(:skill2, :skill1) == :top
      assert BattleChain.pick_row(:skill1, :skill2) == :bottom
      assert BattleChain.pick_row(:skill2, :skill3) == :top
      assert BattleChain.pick_row(:skill3, :skill2) == :bottom
    end

    test "prefers skill1 over skill3 when skill2 isn't available" do
      assert BattleChain.pick_row(:skill1, :skill3) == :top
      assert BattleChain.pick_row(:skill3, :skill1) == :bottom
    end

    test "breaks ties by choosing the bottom option" do
      assert BattleChain.pick_row(:skill1, :skill1) == :bottom
      assert BattleChain.pick_row(:skill2, :skill2) == :bottom
      assert BattleChain.pick_row(:skill3, :skill3) == :bottom
    end
  end

  describe "waypoints/3" do
    test "one waypoint per skill slot, each pinned to its chosen row's chain grid y and the slot's x center" do
      tray = SkillTray.geometry(400)

      top_tiers = List.duplicate(:skill3, tray.skill_num)
      bottom_tiers = List.duplicate(:skill2, tray.skill_num)

      picks = BattleChain.waypoints(tray, top_tiers, bottom_tiers)

      assert length(picks) == tray.skill_num
      assert Enum.all?(picks, fn {row, _x, y} -> row == :bottom and y == tray.chain_bottom_y end)

      xs = Enum.map(picks, fn {_row, x, _y} -> x end)
      assert xs == Enum.sort(xs)
      assert Enum.min(xs) > tray.tray_start_x
      assert Enum.max(xs) < tray.tray_end_x
    end

    test "picks top or bottom independently per slot based on that slot's tiers" do
      tray = SkillTray.geometry(400)
      top_tiers = [:skill2, :skill3, :skill1, :skill1, :skill3, :skill2, :skill1]
      bottom_tiers = [:skill1, :skill1, :skill3, :skill1, :skill2, :skill2, :skill3]

      picks = BattleChain.waypoints(tray, top_tiers, bottom_tiers)
      rows = Enum.map(picks, fn {row, _x, _y} -> row end)

      assert rows == [:top, :bottom, :top, :bottom, :bottom, :bottom, :top]
    end
  end

  describe "expand_diagonals/1" do
    test "leaves same-y legs untouched" do
      points = [{0, 0}, {10, 0}, {20, 0}]
      assert BattleChain.expand_diagonals(points) == points
    end

    test "inserts a bias midpoint before a row change, at 70% of the x gap and 20% of the y gap from the point just left" do
      points = [{0, 0}, {10, 0}, {20, 5}]

      assert BattleChain.expand_diagonals(points) == [
               {0, 0},
               {10, 0},
               {17.0, 1.0},
               {20, 5}
             ]
    end

    test "inserts one midpoint per row change, even back-to-back" do
      points = [{0, 0}, {10, 5}, {20, 0}]

      assert BattleChain.expand_diagonals(points) == [
               {0, 0},
               {7.0, 1.0},
               {10, 5},
               {17.0, 4.0},
               {20, 0}
             ]
    end

    test "no-op on empty or single-point paths" do
      assert BattleChain.expand_diagonals([]) == []
      assert BattleChain.expand_diagonals([{0, 0}]) == [{0, 0}]
    end
  end
end
