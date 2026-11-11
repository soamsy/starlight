defmodule StarlightBot.Vision.SkillTrayTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Vision.SkillTray

  @color_hsv2bgr 54

  describe "geometry/1" do
    test "tray_end_x mirrors tray_start_x by a constant inset, regardless of gear position" do
      insets =
        for gear_start_x <- [200, 400, 700, 960] do
          tray = SkillTray.geometry(gear_start_x)
          1920 - tray.tray_start_x - tray.tray_end_x
        end

      assert insets |> Enum.uniq() |> length() == 1
    end

    test "never produces a zero or negative skill count for a narrow tray" do
      tray = SkillTray.geometry(900)
      assert tray.skill_num >= 1
    end
  end

  describe "chain_grid/1" do
    test "one {x, chain_top_y, chain_bottom_y} triple per skill slot, x centers increasing across the tray" do
      tray = SkillTray.geometry(400)
      grid = SkillTray.chain_grid(tray)

      assert length(grid) == tray.skill_num
      assert Enum.all?(grid, fn {_x, top_y, bottom_y} -> top_y == tray.chain_top_y and bottom_y == tray.chain_bottom_y end)

      xs = Enum.map(grid, fn {x, _top_y, _bottom_y} -> x end)
      assert xs == Enum.sort(xs)
      assert Enum.min(xs) > tray.tray_start_x
      assert Enum.max(xs) < tray.tray_end_x
    end

    test "chain_top_y/chain_bottom_y sit well below the static (pre-drag) row positions" do
      tray = SkillTray.geometry(400)

      assert tray.chain_top_y > tray.top_row.y + tray.top_row.h
      assert tray.chain_bottom_y > tray.bottom_row.y + tray.bottom_row.h
      assert tray.chain_bottom_y > tray.chain_top_y
    end
  end

  describe "row_columns/1" do
    test "tiles a row's own span into `columns` contiguous, increasing segments" do
      tray = SkillTray.geometry(400)

      for row <- [tray.top_row, tray.bottom_row] do
        columns = SkillTray.row_columns(row)
        assert length(columns) == row.columns

        cell_inset = row.bin_width * row.cell_inset_pct

        {x0, _} = List.first(columns)
        assert_in_delta x0, row.start_x + cell_inset - 2, 1

        {_, x1} = List.last(columns)
        assert_in_delta x1, row.end_x - cell_inset + 2, 1

        assert Enum.all?(columns, fn {a, b} -> a < b end)
      end
    end

    test "cell_inset_pct shrinks each column symmetrically by that fraction of its width" do
      row = %{start_x: 100, bin_width: 100.0, columns: 3, cell_inset_pct: 0.1}

      assert SkillTray.row_columns(row) == [{110, 190}, {210, 290}, {310, 390}]
    end

    test "cell_inset_pct of 0.0 reproduces the untrimmed tiling" do
      row = %{start_x: 100, bin_width: 100.0, columns: 3, cell_inset_pct: 0.0}

      assert SkillTray.row_columns(row) == [{100, 200}, {200, 300}, {300, 400}]
    end

    test "top_row and bottom_row each carry their own cell_inset_pct" do
      tray = SkillTray.geometry(400)

      assert is_float(tray.top_row.cell_inset_pct)
      assert is_float(tray.bottom_row.cell_inset_pct)
    end

    test "bottom_row's hue_scan_y is pushed below its own y, top_row's is not" do
      tray = SkillTray.geometry(400)

      assert tray.top_row.hue_scan_y == tray.top_row.y
      assert tray.bottom_row.hue_scan_y > tray.bottom_row.y
    end

    test "hue_scan_columns/1 adds hue_inset_x_pct on top of cell_inset_pct, narrower than row_columns/1" do
      row = %{start_x: 100, bin_width: 100.0, columns: 3, cell_inset_pct: 0.1, hue_inset_x_pct: 0.05}

      assert SkillTray.hue_scan_columns(row) == [{115, 185}, {215, 285}, {315, 385}]
    end

    test "hue_scan_columns/1 matches row_columns/1 when hue_inset_x_pct is 0.0" do
      row = %{start_x: 100, bin_width: 100.0, columns: 3, cell_inset_pct: 0.1, hue_inset_x_pct: 0.0}

      assert SkillTray.hue_scan_columns(row) == SkillTray.row_columns(row)
    end

    test "top row insets more than bottom row at the same skill_num, per perspective" do
      tray = SkillTray.geometry(400)
      top_inset = tray.top_row.start_x - tray.tray_start_x
      bottom_inset = tray.bottom_row.start_x - tray.tray_start_x

      assert top_inset > bottom_inset
    end
  end

  describe "sinner_of_slot/2" do
    test "assigns every slot to sinner 0 when no first-action bins are detected" do
      assert SkillTray.sinner_of_slot(4, MapSet.new()) == [0, 0, 0, 0]
    end

    test "increments the sinner id at each first-action boundary" do
      first_actions = MapSet.new([3, 6])
      assert SkillTray.sinner_of_slot(8, first_actions) == [0, 0, 0, 1, 1, 1, 2, 2]
    end

    test "ignores a first-action flag on bin 0 — it always starts sinner 0" do
      first_actions = MapSet.new([0, 2])
      assert SkillTray.sinner_of_slot(3, first_actions) == [0, 0, 1]
    end

    test "handles a single-slot tray" do
      assert SkillTray.sinner_of_slot(1, MapSet.new()) == [0]
    end
  end

  describe "first_action_bins/3" do
    test "buckets detected HP-color clusters into the correct skill slots" do
      tray = SkillTray.geometry(400)
      hook = %{region: {13, 1025, 1885, 25}, color: {6, 200, 228}, tolerance: {14, 14, 14}, min_cluster_size: 12}
      {_hx, hy, _hw, hh} = hook.region

      blob_bgr = hsv_to_bgr(hook.color)
      mat = blank_mat(1920, 1080)

      # Paint a blob inside bins 1 and 5 (well clear of bin edges), leave the
      # rest of the strip untouched so only those two bins should be flagged.
      mat = paint_blob(mat, bin_center_x(tray, 1), hy + div(hh, 2), blob_bgr)
      mat = paint_blob(mat, bin_center_x(tray, 5), hy + div(hh, 2), blob_bgr)

      assert SkillTray.first_action_bins(tray, mat, hook) == MapSet.new([1, 5])
    end

    test "returns no bins when nothing matches the HP color" do
      tray = SkillTray.geometry(400)
      hook = %{region: {13, 1025, 1885, 25}, color: {6, 200, 228}, tolerance: {14, 14, 14}, min_cluster_size: 12}
      mat = blank_mat(1920, 1080)

      assert SkillTray.first_action_bins(tray, mat, hook) == MapSet.new()
    end
  end

  defp bin_center_x(tray, bin_index) do
    round(tray.tray_start_x + tray.bin_width * (bin_index + 0.5))
  end

  defp hsv_to_bgr({h, s, v}) do
    hsv = Evision.Mat.from_binary(<<h, s, v>>, {:u, 8}, 1, 1, 3)
    bgr = Evision.cvtColor(hsv, @color_hsv2bgr)
    <<b, g, r>> = Evision.Mat.to_binary(bgr)
    {b, g, r}
  end

  defp blank_mat(w, h) do
    Evision.Mat.from_binary(:binary.copy(<<0>>, w * h * 3), {:u, 8}, h, w, 3)
  end

  defp paint_blob(mat, cx, cy, {b, g, r}) do
    Evision.rectangle(mat, {cx - 5, cy - 5}, {cx + 5, cy + 5}, {b, g, r}, thickness: -1)
  end

  describe "slot helpers" do
    test "column_at maps an x inside a slot back to that slot, clamped to the tray" do
      tray = SkillTray.geometry(400)

      for column <- 0..(tray.skill_num - 1) do
        assert SkillTray.column_at(tray, SkillTray.slot_x(tray, column)) == column
      end

      assert SkillTray.column_at(tray, 0) == 0
      assert SkillTray.column_at(tray, 5_000) == tray.skill_num - 1
    end

    test "owned_columns lists every slot belonging to the same sinner" do
      tray = %{SkillTray.geometry(400) | sinner_of_slot: [0, 0, 0, 1, 1, 2]}

      assert SkillTray.owned_columns(tray, 0) == [0, 1, 2]
      assert SkillTray.owned_columns(tray, 4) == [3, 4]
      assert SkillTray.owned_columns(tray, 5) == [5]
    end

    test "columns_under names every slot whose center a cluster covers, or only the nearest slot when it covers none" do
      tray = %{SkillTray.geometry(400) | skill_num: 6}
      center = &SkillTray.slot_x(tray, &1)
      one = {round(center.(1)) - 20, 886, 40, 17}
      merged = {round(center.(3)) - 20, 886, round(center.(5) - center.(3)) + 40, 17}

      assert SkillTray.columns_under(tray, [one]) == [1]
      assert SkillTray.columns_under(tray, [one, merged]) == [1, 3, 4, 5]
      assert SkillTray.columns_under(tray, []) == []

      off_center = {round(center.(2)) - 40, 886, 17, 15}
      assert SkillTray.columns_under(tray, [off_center]) == [2]

      straddling = {round(center.(2) + tray.bin_width / 2) - 8, 886, 17, 15}
      assert SkillTray.columns_under(tray, [straddling]) == [3]
      assert SkillTray.columns_under(tray, [off_center, straddling]) == [2, 3]
    end

    test "sinner action y sits below the bottom skill row" do
      tray = SkillTray.geometry(400)
      assert tray.sinner_action_y > tray.bottom_row.y + tray.bottom_row.h
    end
  end
end
