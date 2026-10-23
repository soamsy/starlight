defmodule StarlightBot.Navigation.NavigatorMachineTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.{Ctx, FakeWorld}
  alias StarlightBot.Navigation.{Navigator, ScriptTask}

  def slow_script(test, ctx) do
    send(test, :script_started)
    Process.sleep(300)
    Ctx.log(ctx, :info, "script log")
    {:ok, RunMemory.get(ctx, :team, nil)}
  end

  test "localize runs as a supervised machine and reports back to the navigator" do
    FakeWorld.start!()
    start_supervised!({Navigator, []})
    Navigator.subscribe()

    Navigator.localize()

    assert_receive {:nav_state, %{phase: :localizing}}
    assert_receive {:nav_state, %{phase: :idle, current_screen: :unknown}}, 2_000
  end

  test "a script task seeds run memory, logs through ctx data and replies with its kind" do
    ctx = Ctx.new(log_to: {self(), :nav_log})
    ScriptTask.run(self(), :run_script, {__MODULE__, :slow_script, [self()]}, ctx, put_team: %{id: 7})

    assert_received {:nav_log, :info, "script log"}
    assert_received {:nav_result, :run_script, {:ok, %{id: 7}}}
  end

  test "a script keeps running when the navigator's code is reloaded twice" do
    args = [self(), :run_script, {__MODULE__, :slow_script, [self()]}, Ctx.new(), nil]
    {pid, ref} = spawn_monitor(ScriptTask, :run, args)

    assert_receive :script_started

    for _ <- 1..2 do
      :code.purge(Navigator)
      {:module, Navigator} = :code.load_file(Navigator)
    end

    assert_receive {:nav_result, :run_script, {:ok, nil}}, 1_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end
end
