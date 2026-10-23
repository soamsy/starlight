defmodule StarlightBot.Automation.RunMemoryInventoryLogTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Ctx

  setup do
    {:ok, pid} = RunMemory.start_link()
    me = self()
    %{ctx: Ctx.new(run_memory: pid, log_to: {me, :log})}
  end

  defp logs do
    receive do
      {:log, _kind, text} -> [text | logs()]
    after
      0 -> []
    end
  end

  test "logs real inventory changes only", %{ctx: ctx} do
    RunMemory.add_ego_gift(ctx, "gift_21", "Fiery Down")
    RunMemory.add_ego_gift(ctx, "gift_21", "Fiery Down")
    RunMemory.add_ego_gift(ctx, "gift_66", "Illusory Hunt")
    RunMemory.set_ego_gift_uptie(ctx, "gift_21", 2)
    RunMemory.set_ego_gift_uptie(ctx, "gift_21", 1)
    RunMemory.remove_ego_gift(ctx, "gift_66")
    RunMemory.remove_ego_gift(ctx, "gift_66")

    assert logs() == [
             "inventory: + Fiery Down (gift_21), now 1 gift(s)",
             "inventory: + Illusory Hunt (gift_66), now 2 gift(s)",
             "inventory: Fiery Down uptie 0 -> 2, now 2 gift(s)",
             "inventory: - Illusory Hunt (gift_66), now 1 gift(s)"
           ]
  end
end
