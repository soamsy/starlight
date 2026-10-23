defmodule StarlightBot.Automation.Scripts.ShopRunnerProgramTest do
  use ExUnit.Case, async: false

  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Scripts.ShopRunner
  alias StarlightBot.{Ctx, FakeWorld}
  alias StarlightBot.Navigation.{DSL, Runner}

  @moduletag :capture_log

  defp budget(id, amount, extra \\ %{}), do: Map.merge(%{"id" => id, "kind" => "budget", "amount" => amount}, extra)

  defp plan(main_steps, workflows) do
    %{
      "workflows" => [%{"id" => "main", "name" => "Main", "steps" => main_steps} | workflows],
      "milestones" => [],
      "library" => %{}
    }
  end

  defp shop_state(plan, done \\ %{}) do
    %{
      plan: plan,
      workflow: hd(plan["workflows"]),
      floor: 2,
      shop_type: :normal,
      reserve: 0,
      refreshes: 0,
      replaced: MapSet.new(),
      gifts_by_name: %{},
      gifts_by_id: %{},
      protected: MapSet.new(),
      sell_popup_open: false,
      heal_menu_open: false,
      last_heal: nil,
      call_stack: ["main"],
      label_prefix: "",
      bailed: false,
      left: false,
      steps: [],
      done: done,
      track_progress?: true
    }
  end

  defp run_walk(state, ctx), do: Runner.run_steps([DSL.call(ShopRunner, :walk, [[{:steps, state.workflow["steps"]}], state, :run])], ctx)

  setup do
    FakeWorld.start!()
    {:ok, run_memory} = RunMemory.start_link()
    %{ctx: Ctx.new(run_memory: run_memory)}
  end

  test "repeats, nested workflows, if blocks, bail and leave all play out in order", %{ctx: ctx} do
    main = [
      budget("b10", 10, %{"repeat" => 2}),
      %{"id" => "w", "kind" => "workflow", "workflow" => "sub"},
      %{"id" => "if", "kind" => "if", "condition" => nil, "then" => [budget("b5", 5)], "else" => [budget("b500", 500)]},
      %{"id" => "out", "kind" => "leave"},
      budget("b99", 99)
    ]

    sub = %{"id" => "sub", "name" => "Sub", "steps" => [budget("b1", 1), %{"id" => "stop", "kind" => "bail"}, budget("b1000", 1000)]}

    assert {:ok, %{reserve: 36, steps: steps}} = run_walk(shop_state(plan(main, [sub])), ctx)
    assert Enum.all?(steps, &(&1.outcome == :done))
    assert length(steps) == 9
  end

  test "a repeat runs its between-workflow between passes", %{ctx: ctx} do
    main = [budget("b10", 10, %{"repeat" => 1, "between" => "btw"})]
    btw = %{"id" => "btw", "name" => "Between", "steps" => [budget("b100", 100)]}

    assert {:ok, %{reserve: 120}} = run_walk(shop_state(plan(main, [btw])), ctx)
  end

  test "steps already handled are skipped on resume", %{ctx: ctx} do
    main = [budget("b10", 10), budget("b20", 20)]

    assert {:ok, %{reserve: 20, steps: [%{id: "b20"}]}} = run_walk(shop_state(plan(main, []), %{"b10" => :done}), ctx)
  end

  test "a pause between steps holds without recording anything until resumed", %{ctx: ctx} do
    pause_flag = :atomics.new(1, [])
    :atomics.put(pause_flag, 1, 1)
    paused = %{ctx | pause_flag: pause_flag}
    state = shop_state(plan([budget("b10", 10)], []))
    run = Task.async(fn -> run_walk(state, paused) end)

    Process.sleep(300)
    assert RunMemory.shop_progress(ctx) == nil

    :atomics.put(pause_flag, 1, 0)
    assert {:ok, %{reserve: 10}} = Task.await(run)
    assert %{done: %{"b10" => :done}} = RunMemory.shop_progress(ctx)
  end
end
