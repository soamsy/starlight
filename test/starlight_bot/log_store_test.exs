defmodule StarlightBot.LogStoreTest do
  use ExUnit.Case, async: false

  alias StarlightBot.{Ctx, LogStore}

  defp sync, do: :sys.get_state(LogStore)

  test "Ctx.log lines are kept in order with a wall-clock timestamp" do
    marker = "log-store-#{System.unique_integer([:positive])}"
    Ctx.log(Ctx.new(), :info, "#{marker} first")
    Ctx.log(Ctx.new(), :error, "#{marker} second")
    sync()

    [first, second] = LogStore.recent(2)
    assert first.text == "#{marker} first"
    assert {second.kind, second.text} == {:error, "#{marker} second"}
    assert second.seq == first.seq + 1
    assert %NaiveDateTime{} = second.at
    assert LogStore.format(second) =~ ~r/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3} \[error\] #{marker} second$/
  end

  test "before/2 pages backwards from a sequence number" do
    marker = "page-#{System.unique_integer([:positive])}"
    for n <- 1..5, do: LogStore.append(:info, "#{marker} #{n}")
    sync()

    [newest] = LogStore.recent(1)
    assert Enum.map(LogStore.before(newest.seq, 2), & &1.text) == ["#{marker} 3", "#{marker} 4"]
  end

  test "subscribers get each new line" do
    LogStore.subscribe()
    LogStore.append(:ok, "broadcast check")
    assert_receive {:log_entry, %{kind: :ok, text: "broadcast check"}}
  end

  test "prune deletes logs and timeout screenshots older than a week, but never the file being written" do
    dir = Path.join(System.tmp_dir!(), "starlight_prune_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "timeouts"))
    old = {{2020, 1, 1}, {0, 0, 0}}

    paths = %{
      old_log: Path.join(dir, "starlight_old.log"),
      new_log: Path.join(dir, "starlight_new.log"),
      current: Path.join(dir, "starlight_current.log"),
      old_png: Path.join([dir, "timeouts", "old.png"]),
      new_png: Path.join([dir, "timeouts", "new.png"]),
      other: Path.join(dir, "notes.txt")
    }

    Enum.each(paths, fn {_name, path} -> File.write!(path, "x") end)
    for name <- [:old_log, :current, :old_png, :other], do: File.touch!(paths[name], old)

    LogStore.prune(dir, Path.expand(paths.current))

    refute File.exists?(paths.old_log)
    refute File.exists?(paths.old_png)
    assert File.exists?(paths.new_log)
    assert File.exists?(paths.new_png)
    assert File.exists?(paths.current)
    assert File.exists?(paths.other)
    File.rm_rf!(dir)
  end

  test "Ctx.log from a running machine records the machine chain that wrote it" do
    marker = "lineage-#{System.unique_integer([:positive])}"
    Ctx.log(Ctx.new(), :info, "#{marker} outside")
    sync()

    assert [%{lineage: []}] = LogStore.recent(1)
  end
end
