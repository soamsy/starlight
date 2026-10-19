defmodule StarlightBot.Automation.BattleChainTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Automation.BattleChain
  alias StarlightBot.Vision.SkillTray

  defp pick_row(top, bottom) do
    [{row, _x, _y}] = BattleChain.waypoints(SkillTray.geometry(400), [top], [bottom])
    row
  end

  describe "single-column row choice" do
    test "prefers skill2 over skill1 and skill3, regardless of position or threshold margin" do
      assert pick_row({:skill2, 0.9}, {:skill1, 0.1}) == :top
      assert pick_row({:skill1, 0.1}, {:skill2, 0.9}) == :bottom
      assert pick_row({:skill2, 0.9}, {:skill3, 0.1}) == :top
      assert pick_row({:skill3, 0.1}, {:skill2, 0.9}) == :bottom
    end

    test "prefers skill1 over skill3 when skill2 isn't available" do
      assert pick_row({:skill1, 0.9}, {:skill3, 0.1}) == :top
      assert pick_row({:skill3, 0.1}, {:skill1, 0.9}) == :bottom
    end

    test "breaks same-tier ties by choosing the smaller margin over the tier threshold" do
      assert pick_row({:skill1, 0.30}, {:skill1, 0.40}) == :top
      assert pick_row({:skill2, 0.55}, {:skill2, 0.50}) == :bottom
      assert pick_row({:skill3, 0.70}, {:skill3, 0.90}) == :top
    end

    test "breaks exact ties by choosing the bottom option" do
      assert pick_row({:skill1, 0.4}, {:skill1, 0.4}) == :bottom
      assert pick_row({:skill2, 0.5}, {:skill2, 0.5}) == :bottom
      assert pick_row({:skill3, 0.8}, {:skill3, 0.8}) == :bottom
    end
  end

  describe "waypoints/3" do
    test "one waypoint per skill slot, each pinned to its chosen row's chain grid y and the slot's x center" do
      tray = SkillTray.geometry(400)

      top_tiers = List.duplicate({:skill3, 0.8}, tray.skill_num)
      bottom_tiers = List.duplicate({:skill2, 0.5}, tray.skill_num)

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
      top_tiers = [{:skill2, 0.5}, {:skill3, 0.8}, {:skill1, 0.3}, {:skill1, 0.3}, {:skill3, 0.8}, {:skill2, 0.4}, {:skill1, 0.3}]
      bottom_tiers = [{:skill1, 0.3}, {:skill1, 0.3}, {:skill3, 0.8}, {:skill1, 0.2}, {:skill2, 0.5}, {:skill2, 0.5}, {:skill3, 0.8}]

      picks = BattleChain.waypoints(tray, top_tiers, bottom_tiers)
      rows = Enum.map(picks, fn {row, _x, _y} -> row end)

      assert rows == [:top, :bottom, :top, :bottom, :bottom, :top, :top]
    end
  end

  describe "waypoints/3 row steadiness" do
    test "same-tier columns stay on the current row even when the margin prefers the other one" do
      tray = SkillTray.geometry(400)
      top_tiers = [{:skill2, 0.5}, {:skill1, 0.9}, {:skill2, 0.5}]
      bottom_tiers = [{:skill3, 0.8}, {:skill1, 0.1}, {:skill3, 0.8}]

      rows = BattleChain.waypoints(tray, top_tiers, bottom_tiers) |> Enum.map(&elem(&1, 0))

      assert rows == [:top, :top, :top]
    end

    test "leading same-tier columns start on the row the first decided column needs" do
      tray = SkillTray.geometry(400)
      top_tiers = [{:skill1, 0.1}, {:skill1, 0.1}, {:skill3, 0.8}]
      bottom_tiers = [{:skill1, 0.9}, {:skill1, 0.9}, {:skill2, 0.5}]

      rows = BattleChain.waypoints(tray, top_tiers, bottom_tiers) |> Enum.map(&elem(&1, 0))

      assert rows == [:bottom, :bottom, :bottom]
    end

    test "never trades a better tier for fewer row changes" do
      tray = SkillTray.geometry(400)
      top_tiers = [{:skill2, 0.5}, {:skill1, 0.3}, {:skill2, 0.5}]
      bottom_tiers = [{:skill1, 0.3}, {:skill2, 0.5}, {:skill1, 0.3}]

      rows = BattleChain.waypoints(tray, top_tiers, bottom_tiers) |> Enum.map(&elem(&1, 0))

      assert rows == [:top, :bottom, :top]
    end

    test "same-tier columns next to a pin follow the pinned row" do
      tray = SkillTray.geometry(400)
      top_tiers = [{:skill1, 0.1}, {:skill1, 0.1}, {:skill1, 0.1}]
      bottom_tiers = [{:skill1, 0.9}, {:skill1, 0.9}, {:skill1, 0.9}]

      rows = BattleChain.waypoints(tray, top_tiers, bottom_tiers, %{1 => :bottom}) |> Enum.map(&elem(&1, 0))

      assert rows == [:bottom, :bottom, :bottom]
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

  describe "waypoints/4 with forced columns" do
    test "forced columns override the tier choice" do
      tray = SkillTray.geometry(400)
      top_tiers = List.duplicate({:skill2, 0.5}, tray.skill_num)
      bottom_tiers = List.duplicate({:skill3, 0.8}, tray.skill_num)

      rows = BattleChain.waypoints(tray, top_tiers, bottom_tiers, %{0 => :bottom}) |> Enum.map(&elem(&1, 0))

      assert hd(rows) == :bottom
      assert Enum.all?(tl(rows), &(&1 == :top))
    end
  end
end
