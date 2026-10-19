defmodule StarlightBot.Vision.NumberScannerTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Vision.NumberScanner

  describe "from_hits/1" do
    test "orders digits by x regardless of hit order" do
      hits = [{46, "8", 0.95}, {5, "9", 0.95}, {26, "3", 0.95}]

      assert NumberScanner.from_hits(hits) == {:ok, 938}
    end

    test "handles repeated digits" do
      hits = [{0, "8", 0.95}, {20, "8", 0.95}, {40, "8", 0.95}]

      assert NumberScanner.from_hits(hits) == {:ok, 888}
    end

    test "keeps narrow neighbours like a 1 next to another digit" do
      assert NumberScanner.from_hits([{863, "1", 0.93}, {878, "5", 0.95}]) == {:ok, 15}
    end

    test "overlapping hits from different digits keep only the best score" do
      hits = [{878, "4", 0.96}, {898, "8", 0.97}, {901, "0", 0.91}, {919, "8", 0.96}]

      assert NumberScanner.from_hits(hits) == {:ok, 488}
    end

    test "returns :not_found for no hits" do
      assert NumberScanner.from_hits([]) == :not_found
    end
  end
end
