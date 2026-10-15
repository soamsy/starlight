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
end
