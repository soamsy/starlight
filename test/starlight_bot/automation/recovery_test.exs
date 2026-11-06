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

  describe "goto recovery" do
    @then {__MODULE__, :then, []}
    @ctx StarlightBot.Ctx.new()

    test "a failed verification relocalizes" do
      err = {:error, {:verification_failed, :home}}
      assert {:steps, [_ | _]} = Recovery.goto_delivered(:home, @then, 3, err, nil, @ctx)
    end

    test "no attempts left delivers the error" do
      err = {:error, {:verification_failed, :home}}
      assert {:steps, [{:call, {__MODULE__, :then, [^err]}}]} = Recovery.goto_delivered(:home, @then, 0, err, nil, @ctx)
    end

    test "errors relocalizing cannot fix are delivered as is" do
      for err <- [{:error, {:no_path, :a, :b}}, {:error, :window_not_focused}] do
        assert {:steps, [{:call, {__MODULE__, :then, [^err]}}]} = Recovery.goto_delivered(:home, @then, 3, err, nil, @ctx)
      end
    end

    test "success is delivered as is" do
      assert {:steps, [{:call, {__MODULE__, :then, [{:ok, :home}]}}]} = Recovery.goto_delivered(:home, @then, 3, {:ok, :home}, nil, @ctx)
    end

    test "relocalizing onto the target delivers it" do
      assert {:steps, [{:call, {__MODULE__, :then, [{:ok, :home}]}}]} = Recovery.goto_relocated(:home, @then, 3, :err, {:ok, :home}, nil, @ctx)
    end

    test "relocalizing elsewhere replans with one fewer attempt" do
      assert {:steps, [{:goto, :battle, :home, @then, 2}]} = Recovery.goto_relocated(:home, @then, 3, :err, {:ok, :battle}, nil, @ctx)
    end

    test "failing to relocalize delivers the original error" do
      err = {:error, {:verification_failed, :home}}
      assert {:steps, [{:call, {__MODULE__, :then, [^err]}}]} = Recovery.goto_relocated(:home, @then, 3, err, :unknown, nil, @ctx)
    end
  end
end
