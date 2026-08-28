defmodule StarlightBot.Vision.NumberScannerTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Vision.NumberScanner

  describe "from_hits/1" do
    test "orders digits by x regardless of hit order" do
      hits = [{46, "8"}, {5, "9"}, {26, "3"}]

      assert NumberScanner.from_hits(hits) == {:ok, 938}
    end

    test "handles repeated digits" do
      hits = [{0, "8"}, {20, "8"}, {40, "8"}]

      assert NumberScanner.from_hits(hits) == {:ok, 888}
    end

    test "returns :not_found for no hits" do
      assert NumberScanner.from_hits([]) == :not_found
    end
  end
end
