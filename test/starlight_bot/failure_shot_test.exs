defmodule StarlightBot.FailureShotTest do
  use ExUnit.Case, async: false

  alias StarlightBot.{Data, FailureShot}

  test "prune deletes failure screenshots older than a week and keeps recent ones" do
    dir = Data.failure_shots_dir()
    File.mkdir_p!(dir)
    old = Path.join(dir, "prune_test_old.png")
    recent = Path.join(dir, "prune_test_recent.png")
    other = Path.join(dir, "prune_test_notes.txt")
    Enum.each([old, recent, other], &File.write!(&1, "x"))
    File.touch!(old, {{2020, 1, 1}, {0, 0, 0}})
    File.touch!(other, {{2020, 1, 1}, {0, 0, 0}})

    FailureShot.prune()

    refute File.exists?(old)
    assert File.exists?(recent)
    assert File.exists?(other)
    File.rm!(recent)
    File.rm!(other)
  end
end
