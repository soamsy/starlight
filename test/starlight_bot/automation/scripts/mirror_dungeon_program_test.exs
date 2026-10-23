defmodule StarlightBot.Automation.Scripts.MirrorDungeonProgramTest do
  use ExUnit.Case, async: false

  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Scripts.MirrorDungeonRunner
  alias StarlightBot.{Ctx, FakeWorld, Repo, Teams}
  alias StarlightBot.Navigation.Runner

  @moduletag :capture_log

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    {:ok, run_memory} = RunMemory.start_link()
    %{ctx: Ctx.new(run_memory: run_memory)}
  end

  test "rejects bad arguments before touching the game", %{ctx: ctx} do
    FakeWorld.start!()
    assert Runner.run_steps(MirrorDungeonRunner.program([], 1, %{weekly_bonus?: false}), ctx) == {:error, :invalid_arguments}
    assert FakeWorld.inputs() == []
  end

  test "a missing team stops the run", %{ctx: ctx} do
    FakeWorld.start!()
    assert Runner.run_steps(MirrorDungeonRunner.program([%{id: 999_999, hook: "team_burn"}], 1, %{weekly_bonus?: false}), ctx) == {:error, :team_not_found}
  end

  test "with no runs left it locates the screen, sets up the run and finishes at home", %{ctx: ctx} do
    {:ok, team_id} = Teams.save_team(%{name: "Program Team", hooks: ["team_burn"]})
    FakeWorld.start!(hooks: [:home_lunacy], visible: [:home_lunacy])

    program = MirrorDungeonRunner.program([%{id: team_id, hook: "team_burn"}], 0, %{weekly_bonus?: false})

    assert {:ok, home} = Runner.run_steps(program, ctx)
    assert home in [:home, :home_unknown]
    assert RunMemory.get(ctx, :run_progress, nil) == %{current: 0, total: 0}
    assert %{name: "Program Team", hook: "team_burn"} = RunMemory.get(ctx, :team, nil)
    assert FakeWorld.inputs() == []
  end
end
