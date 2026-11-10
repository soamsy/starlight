defmodule StarlightBot.Automation.RunMemoryTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Ctx

  setup do
    {:ok, pid} = RunMemory.start_link()
    %{ctx: Ctx.new(run_memory: pid)}
  end

  describe "battle_track/2" do
    test "luxcavation uses the lux tracks regardless of mode", %{ctx: ctx} do
      RunMemory.put_context(ctx, :luxcavation)
      RunMemory.put_mode(ctx, "hard")

      assert RunMemory.battle_track(ctx, "chain") == "lux_chain"
      assert RunMemory.battle_track(ctx, "focused") == "lux_focused"
    end

    test "mirror dungeon follows the recorded mode", %{ctx: ctx} do
      RunMemory.put_context(ctx, :mirror_dungeon)
      assert RunMemory.battle_track(ctx, "chain") == "normal_chain"

      RunMemory.put_mode(ctx, "hard")
      assert RunMemory.battle_track(ctx, "focused") == "hard_focused"
    end
  end

  test "battle turn defaults to 1", %{ctx: ctx} do
    assert RunMemory.battle_turn(ctx) == 1
    RunMemory.put_battle_turn(ctx, 4)
    assert RunMemory.battle_turn(ctx) == 4
  end

  test "battle retries count up and reset, and give up stays set", %{ctx: ctx} do
    assert RunMemory.battle_retries(ctx) == 0
    RunMemory.put_battle_retries(ctx, 2)
    RunMemory.reset_battle_retries(ctx)
    assert RunMemory.battle_retries(ctx) == 0

    refute RunMemory.give_up?(ctx)
    RunMemory.put_give_up(ctx, :too_many_retries)
    assert RunMemory.give_up?(ctx)
    assert RunMemory.give_up(ctx) == :too_many_retries
  end

  test "claim_battle_retry counts retries up to the limit, then gives up", %{ctx: ctx} do
    RunMemory.put_battle_turn(ctx, 5)
    assert RunMemory.claim_battle_retry(ctx) == {:retry, 1, 5}
    assert RunMemory.battle_turn(ctx) == 1

    for attempt <- 2..5 do
      assert RunMemory.claim_battle_retry(ctx) == {:retry, attempt, 5}
    end

    assert RunMemory.claim_battle_retry(ctx) == :give_up
    assert RunMemory.give_up(ctx) == :too_many_retries
    assert RunMemory.claim_battle_retry(ctx) == :give_up
  end

  test "claim_battle_retry uses the retries of the playbook that played the turn", %{ctx: ctx} do
    RunMemory.put(ctx, :battle_max_retries, 1)
    assert RunMemory.claim_battle_retry(ctx) == {:retry, 1, 1}
    assert RunMemory.claim_battle_retry(ctx) == :give_up
  end

  test "raise_floor only moves the floor up, while put_floor can reset it", %{ctx: ctx} do
    assert RunMemory.raise_floor(ctx, 3) == 3
    assert RunMemory.raise_floor(ctx, 1) == 3
    assert RunMemory.floor(ctx) == 3
    assert RunMemory.raise_floor(ctx, 4) == 4

    RunMemory.put_floor(ctx, 1)
    assert RunMemory.floor(ctx) == 1
  end
end
