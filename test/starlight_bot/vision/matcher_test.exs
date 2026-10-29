defmodule StarlightBot.Vision.MatcherTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Vision.Matcher

  describe "color_cluster_rects/3" do
    test "a full hue tolerance finds dark blobs whatever their hue, unlike a tight one" do
      mat = two_blobs({0, 0, 40}, {40, 0, 0})

      assert [_, _] = Matcher.color_cluster_rects(mat, {90, 200, 40}, {90, 255, 6})
      assert [{_area, {10, 20, 20, 20}}] = Matcher.color_cluster_rects(mat, {0, 255, 40}, {6, 6, 6})
    end

    test "a saturation-only range separates vivid from pale at the same brightness" do
      mat = two_blobs({0, 0, 255}, {200, 200, 255})

      assert [{_area, {10, 20, 20, 20}}] = Matcher.color_cluster_rects(mat, {90, 255, 0}, {90, 6, 255})
      assert [_, _] = Matcher.color_cluster_rects(mat, {0, 0, 255}, {90, 255, 6})
    end

    test "low saturation with high value picks out white and ignores bright colors" do
      mat = two_blobs({255, 255, 255}, {0, 0, 255})

      assert [{_area, {10, 20, 20, 20}}] = Matcher.color_cluster_rects(mat, {0, 0, 255}, {90, 30, 30})
    end
  end

  describe "inner_ring_mask/2" do
    test "zeroes out the interior of a large solid region, keeping only the edge band" do
      mask = solid_mask(40, 40)

      ring = Matcher.inner_ring_mask(mask, 3)

      assert pixel(ring, 20, 20) == 0
      assert pixel(ring, 0, 0) > 0
    end

    test "ring area is smaller than the full mask but non-empty for a large solid region" do
      mask = solid_mask(60, 60)

      ring = Matcher.inner_ring_mask(mask, 3)

      assert Evision.countNonZero(ring) > 0
      assert Evision.countNonZero(ring) < Evision.countNonZero(mask)
    end

    test "a band thinner than the kernel counts entirely as ring — nothing survives the erosion to subtract away" do
      mask = thin_line_mask(40, 20)

      ring = Matcher.inner_ring_mask(mask, 5)

      assert Evision.countNonZero(ring) == Evision.countNonZero(mask)
    end
  end

  describe "top_right_wedge_mask/2" do
    test "keeps pixels right of the 45-degree diagonal from top-center, discards pixels left of it" do
      w = 60
      h = 30
      wedge = Matcher.top_right_wedge_mask(w, h)

      assert pixel(wedge, 0, 0) == 0
      assert pixel(wedge, w - 1, 0) > 0

      assert pixel(wedge, 10, 5) == 0
      assert pixel(wedge, 50, 5) > 0
    end

    test "produces a mask sized to the requested region" do
      wedge = Matcher.top_right_wedge_mask(40, 20)
      assert Evision.Mat.shape(wedge) == {20, 40}
    end

    test "bulge_pct of 0.0 reproduces the straight-line wedge exactly" do
      w = 60
      h = 30
      straight = Matcher.top_right_wedge_mask(w, h)
      explicit_zero = Matcher.top_right_wedge_mask(w, h, 0.0)

      assert Evision.Mat.to_binary(straight) == Evision.Mat.to_binary(explicit_zero)
    end

    test "bulge_pct drops the boundary straight down before continuing at 45 degrees, reclaiming area near the top" do
      w = 60
      h = 30
      straight = Matcher.top_right_wedge_mask(w, h)
      bulged = Matcher.top_right_wedge_mask(w, h, 0.1)

      assert pixel(straight, 31, 2) == 0
      assert pixel(bulged, 31, 2) > 0

      assert Evision.countNonZero(bulged) > Evision.countNonZero(straight)
    end

    test "past the drop, the boundary is a straight 45-degree line again — just starting lower" do
      w = 60
      h = 30
      bulged = Matcher.top_right_wedge_mask(w, h, 0.1)

      assert pixel(bulged, 29, 5) == 0
      assert pixel(bulged, 33, 5) > 0
    end
  end

  describe "top_right_corner_mask/3" do
    test "fills a right-triangle at the top-right corner, sized by pct of w" do
      mask = Matcher.top_right_corner_mask(60, 30, 0.2)

      assert pixel(mask, 59, 0) > 0
      assert pixel(mask, 0, 0) == 0
      assert pixel(mask, 30, 15) == 0
    end

    test "cuts at a true 45-degree angle from the top edge, not a separate h-scaled leg" do
      w = 80
      h = 20
      mask = Matcher.top_right_corner_mask(w, h, 0.25)

      assert pixel(mask, 76, 15) > 0
      assert pixel(mask, 65, 15) == 0
    end

    test "pct of 0.0 produces an empty mask" do
      mask = Matcher.top_right_corner_mask(60, 30, 0.0)
      assert Evision.countNonZero(mask) == 0
    end

    test "a bigger pct produces a bigger corner" do
      small = Matcher.top_right_corner_mask(60, 30, 0.1)
      big = Matcher.top_right_corner_mask(60, 30, 0.3)

      assert Evision.countNonZero(big) > Evision.countNonZero(small)
    end
  end

  describe "fill_holes_mask/1" do
    test "fills a hole fully enclosed inside a blob, without expanding the outer edge" do
      mask = solid_mask_with_hole(60, 40, {10, 10, 40, 20}, {25, 17, 10, 6})

      filled = Matcher.fill_holes_mask(mask)

      assert pixel(filled, 30, 20) > 0
      assert pixel(filled, 9, 20) == 0
      assert pixel(filled, 50, 20) == 0

      assert Evision.countNonZero(filled) > Evision.countNonZero(mask)
    end

    test "a blob with no holes is unchanged" do
      mask = solid_mask_with_hole(60, 40, {10, 10, 40, 20}, nil)

      filled = Matcher.fill_holes_mask(mask)

      assert Evision.countNonZero(filled) == Evision.countNonZero(mask)
    end

    test "bridges a narrow-necked cavity (not a true hole) into a hole and fills it" do
      mask = solid_mask_with_hole(60, 40, {10, 10, 40, 20}, {25, 17, 10, 6})
      mask = Evision.rectangle(mask, {29, 22}, {30, 35}, 0, thickness: -1)

      filled = Matcher.fill_holes_mask(mask)

      assert pixel(filled, 30, 20) > 0
    end

    test "fills a wide-open cavity too, once it's deep enough - width alone doesn't spare it" do
      mask = solid_mask_with_hole(60, 40, {10, 10, 40, 20}, {25, 17, 10, 6})
      mask = Evision.rectangle(mask, {20, 22}, {39, 35}, 0, thickness: -1)

      filled = Matcher.fill_holes_mask(mask)

      assert pixel(filled, 30, 20) > 0
    end

    test "leaves a wide, shallow notch alone - not narrow enough to close, not deep enough to patch" do
      mask = solid_mask_with_hole(60, 40, {10, 10, 40, 20}, nil)
      mask = Evision.rectangle(mask, {15, 27}, {34, 35}, 0, thickness: -1)

      filled = Matcher.fill_holes_mask(mask)

      assert pixel(filled, 24, 28) == 0
    end

    test "with both the closing kernel and the defect-depth pass disabled, the same neck stays unbridged" do
      mask = solid_mask_with_hole(60, 40, {10, 10, 40, 20}, {25, 17, 10, 6})
      mask = Evision.rectangle(mask, {29, 22}, {30, 35}, 0, thickness: -1)

      filled = Matcher.fill_holes_mask(mask, 1, 999)

      assert pixel(filled, 30, 20) == 0
    end
  end

  describe "fill_deep_defects_mask/2" do
    test "patches a long thin line invading toward the centroid, regardless of its width" do
      mask = solid_mask_with_hole(60, 40, {10, 10, 40, 20}, nil)
      mask = Evision.rectangle(mask, {28, 10}, {29, 25}, 0, thickness: -1)

      patched = Matcher.fill_deep_defects_mask(mask)

      assert pixel(patched, 28, 17) > 0
    end

    test "leaves a notch below the depth threshold alone" do
      mask = solid_mask_with_hole(60, 40, {10, 10, 40, 20}, nil)
      mask = Evision.rectangle(mask, {28, 10}, {29, 13}, 0, thickness: -1)

      patched = Matcher.fill_deep_defects_mask(mask)

      assert pixel(patched, 28, 11) == 0
    end

    test "a lower depth threshold picks up that same shallow notch" do
      mask = solid_mask_with_hole(60, 40, {10, 10, 40, 20}, nil)
      mask = Evision.rectangle(mask, {28, 10}, {29, 13}, 0, thickness: -1)

      patched = Matcher.fill_deep_defects_mask(mask, 2)

      assert pixel(patched, 28, 11) > 0
    end

    test "leaves a fully convex blob (no defects at all) unchanged" do
      mask = solid_mask_with_hole(60, 40, {10, 10, 40, 20}, nil)

      patched = Matcher.fill_deep_defects_mask(mask)

      assert Evision.countNonZero(patched) == Evision.countNonZero(mask)
    end
  end

  defp solid_mask_with_hole(w, h, {bx, by, bw, bh}, hole) do
    mat = Evision.Mat.from_binary(:binary.copy(<<0>>, w * h), {:u, 8}, h, w, 1)
    mat = Evision.rectangle(mat, {bx, by}, {bx + bw - 1, by + bh - 1}, 255, thickness: -1)

    case hole do
      nil -> mat
      {hx, hy, hw, hh} -> Evision.rectangle(mat, {hx, hy}, {hx + hw - 1, hy + hh - 1}, 0, thickness: -1)
    end
  end

  defp solid_mask(w, h) do
    Evision.Mat.from_binary(:binary.copy(<<255>>, w * h), {:u, 8}, h, w, 1)
  end

  defp thin_line_mask(w, h) do
    mat = Evision.Mat.from_binary(:binary.copy(<<0>>, w * h), {:u, 8}, h, w, 1)
    Evision.rectangle(mat, {0, div(h, 2)}, {w - 1, div(h, 2)}, 255, thickness: 1)
  end

  defp two_blobs(left_bgr, right_bgr) do
    Evision.Mat.from_binary(:binary.copy(<<128, 128, 128>>, 100 * 60), {:u, 8}, 60, 100, 3)
    |> Evision.rectangle({10, 20}, {29, 39}, left_bgr, thickness: -1)
    |> Evision.rectangle({70, 20}, {89, 39}, right_bgr, thickness: -1)
  end

  defp pixel(mat, x, y) do
    <<v>> = mat |> Evision.Mat.roi({x, y, 1, 1}) |> Evision.Mat.to_binary()
    v
  end
end
