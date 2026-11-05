defmodule StarlightBot.Automation.RecoveryTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Automation.Recovery
  alias StarlightBot.Navigation.Catalog

  test "scheduled maintenance is a known screen" do
    assert %{identity_hook: :scheduled_maintenance} = Catalog.find_screen(:scheduled_maintenance)
  end

  test "cannot operate game is a known screen" do
    assert %{identity_hook: :cannot_operate_game} = Catalog.find_screen(:cannot_operate_game)
  end

  for screen <- [:scheduled_maintenance, :cannot_operate_game] do
    test "landing on #{screen} dismisses both popups and cancels the run" do
      assert {:steps, steps} = Recovery.located({__MODULE__, :keep?}, 3, {__MODULE__, :then, []}, {:ok, unquote(screen)}, nil, StarlightBot.Ctx.new())
      assert {:call, {Recovery, :cancel_run, []}} in steps
      assert Enum.any?(steps, &match?({:attempt, [{:click, :scheduled_maintenance}], []}, &1))
      assert Enum.any?(steps, &match?({:attempt, [{:click, :cannot_operate_game}], []}, &1))
    end
  end
end
