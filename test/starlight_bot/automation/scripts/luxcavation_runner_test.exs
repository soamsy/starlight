defmodule StarlightBot.Automation.Scripts.LuxcavationRunnerTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Automation.Scripts.LuxcavationRunner

  describe "batches/1" do
    test "zero waves yields no batches" do
      assert LuxcavationRunner.batches(0) == []
    end

    test "up to ten waves is a single batch" do
      assert LuxcavationRunner.batches(1) == [1]
      assert LuxcavationRunner.batches(10) == [10]
    end

    test "waves past ten spill into further batches" do
      assert LuxcavationRunner.batches(11) == [10, 1]
      assert LuxcavationRunner.batches(17) == [10, 7]
      assert LuxcavationRunner.batches(25) == [10, 10, 5]
      assert LuxcavationRunner.batches(30) == [10, 10, 10]
    end
  end
end
