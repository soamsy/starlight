defmodule StarlightBot.Vision.SkillTrayTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Vision.SkillTray

  @color_hsv2bgr 54

  describe "geometry/1" do
    test "mirrors tray_start_x around screen center and derives bin count/width" do
      tray = SkillTray.geometry(400)

      assert tray.gear_start_x == 400
      assert tray.tray_start_x == 495
      assert tray.tray_end_x == 1324
      assert tray.skill_num == 7
      assert_in_delta tray.bin_width, 829 / 7, 0.0001
    end

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

  describe "row_columns/1" do
    test "tiles a row's own span into `columns` contiguous, increasing segments" do
      tray = SkillTray.geometry(400)

      for row <- [tray.top_row, tray.bottom_row] do
        columns = SkillTray.row_columns(row)
        assert length(columns) == row.columns

        cell_inset = row.bin_width * row.cell_inset_pct

        {x0, _} = List.first(columns)
        assert_in_delta x0, row.start_x + cell_inset, 1

        {_, x1} = List.last(columns)
        assert_in_delta x1, row.end_x - cell_inset, 1

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

    test "each row's inset scales with skill_num at a constant per-slot rate, regardless of gear position" do
      trays = Enum.map([200, 400, 700, 960], &SkillTray.geometry/1)

      top_rates = Enum.map(trays, &((&1.top_row.start_x - &1.tray_start_x) / &1.skill_num))
      bottom_rates = Enum.map(trays, &((&1.bottom_row.start_x - &1.tray_start_x) / &1.skill_num))

      assert_all_close(top_rates)
      assert_all_close(bottom_rates)
    end

    test "reproduces the previously flat-tuned insets at skill_num=7" do
      tray = SkillTray.geometry(400)
      assert tray.skill_num == 7

      assert_in_delta tray.top_row.start_x - tray.tray_start_x, 73, 0.01
      assert_in_delta tray.bottom_row.start_x - tray.tray_start_x, 26.35, 0.01
    end

    test "top row insets more than bottom row at the same skill_num, per perspective" do
      tray = SkillTray.geometry(400)
      top_inset = tray.top_row.start_x - tray.tray_start_x
      bottom_inset = tray.bottom_row.start_x - tray.tray_start_x

      assert top_inset > bottom_inset
    end

    test "fewer skill slots need less inset than more skill slots" do
      few = SkillTray.geometry(700)
      many = SkillTray.geometry(400)
      assert few.skill_num < many.skill_num

      assert few.top_row.start_x - few.tray_start_x < many.top_row.start_x - many.tray_start_x
      assert few.bottom_row.start_x - few.tray_start_x < many.bottom_row.start_x - many.tray_start_x
    end
  end

  defp assert_all_close([first | rest]) do
    Enum.each(rest, &assert_in_delta(&1, first, 0.001))
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
      hook = %{region: {13, 1025, 1885, 25}, color: {6, 200, 228}, confidence: 0.52, min_cluster_size: 12}
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
      hook = %{region: {13, 1025, 1885, 25}, color: {6, 200, 228}, confidence: 0.52, min_cluster_size: 12}
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
end
