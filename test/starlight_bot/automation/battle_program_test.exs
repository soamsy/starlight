defmodule StarlightBot.Automation.BattleProgramTest do
  use ExUnit.Case, async: false

  alias StarlightBot.Automation.{Engine, PlaybookRunner, RunMemory}
  alias StarlightBot.{Ctx, FakeWorld}
  alias StarlightBot.Navigation.{DSL, Runner}

  @moduletag :capture_log

  @hooks [:battle_turn, :battle_settings, :battle_pause_button, :battle_safe_click_spot, :battle_over_black_confirm]

  defp game_inputs, do: Enum.filter(FakeWorld.inputs(), &match?({kind, _} when kind in [:key, :click, :mouse], &1))

  defp run_memory_ctx do
    {:ok, run_memory} = RunMemory.start_link()
    Ctx.new(run_memory: run_memory)
  end

  test "a battle plays from the turn screen through to the battle-over confirm" do
    FakeWorld.start!(hooks: @hooks, visible: [:battle_turn, :battle_settings])
    FakeWorld.react({:key, :enter}, hide: [:battle_turn], show: [:battle_pause_button])
    FakeWorld.react({:key, :enter}, hide: [:battle_pause_button], show: [:battle_over_black_confirm], after: 600)
    FakeWorld.react({:click, :battle_over_black_confirm}, hide: [:battle_over_black_confirm, :battle_settings])

    assert Engine.play_battle(:battle_turn) == {:ok, :battle_turn_or_over}

    assert game_inputs() == [
             {:key, :p},
             {:key, :enter},
             {:mouse, :down},
             {:mouse, :up},
             {:click, :battle_over_black_confirm}
           ]
  end

  describe "playbook actions" do
    test "commit presses enter, sees the turn start and counts the turn" do
      FakeWorld.start!(hooks: @hooks, visible: [:battle_turn])
      FakeWorld.react({:key, :enter}, hide: [:battle_turn], show: [:battle_pause_button])
      ctx = run_memory_ctx()

      turn = %{kind: "chain", scan: :skip, number: 3}
      steps = [DSL.call(PlaybookRunner, :run_actions, [[%{"type" => "commit"}, %{"type" => "commit"}], turn])]

      assert {:ok, _} = Runner.run_steps(steps, ctx)
      assert game_inputs() == [{:key, :enter}]
      assert RunMemory.battle_turn(ctx) == 4
    end

    test "unknown actions are skipped and an already started turn needs no keys" do
      FakeWorld.start!(hooks: @hooks, visible: [:battle_pause_button])
      ctx = run_memory_ctx()

      steps = [DSL.call(PlaybookRunner, :run_actions, [[%{"type" => "nonsense"}], %{kind: "chain", scan: :skip, number: 1}])]

      assert {:ok, _} = Runner.run_steps(steps, ctx)
      assert game_inputs() == []
      assert RunMemory.battle_turn(ctx) == 2
    end

    test "an if block runs its chosen branch before the remaining actions" do
      FakeWorld.start!(hooks: @hooks, visible: [:battle_turn])
      FakeWorld.react({:key, :enter}, hide: [:battle_turn], show: [:battle_pause_button])
      ctx = run_memory_ctx()

      block = %{"type" => "if", "condition" => nil, "then" => [%{"type" => "commit"}], "else" => []}
      steps = [DSL.call(PlaybookRunner, :run_actions, [[block, %{"type" => "commit"}], %{kind: "chain", scan: :skip, number: 1}])]

      assert {:ok, _} = Runner.run_steps(steps, ctx)
      assert game_inputs() == [{:key, :enter}]
    end
  end
end
