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
end
