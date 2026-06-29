defmodule StarlightBot.Automation.Scripts.LuxcavationRunnerTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Automation.Scripts.LuxcavationRunner

  describe "batches/1" do
    test "zero yields no batches" do
      assert LuxcavationRunner.batches(0) == []
    end

    test "a count at or under the cap is a single batch" do
      assert LuxcavationRunner.batches(1) == [1]
      assert LuxcavationRunner.batches(10) == [10]
    end

    test "splits into max-sized chunks, remainder last" do
      assert LuxcavationRunner.batches(16) == [10, 6]
      assert LuxcavationRunner.batches(20) == [10, 10]
      assert LuxcavationRunner.batches(21) == [10, 10, 1]
    end
  end
end
