defmodule StarlightBot.Automation.Scripts.LuxcavationRunnerTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Automation.Scripts.LuxcavationRunner

  describe "batches/2" do
    test "zero repeats yields no batches" do
      assert LuxcavationRunner.batches(5, 0) == []
    end

    test "repeats the consecutive count that many times" do
      assert LuxcavationRunner.batches(2, 1) == [2]
      assert LuxcavationRunner.batches(2, 4) == [2, 2, 2, 2]
      assert LuxcavationRunner.batches(10, 3) == [10, 10, 10]
    end
  end
end
