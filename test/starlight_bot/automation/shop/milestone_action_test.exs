defmodule StarlightBot.Automation.Shop.Actions.MilestoneTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Shop.Actions.Milestone
  alias StarlightBot.{Ctx, GiftPlans}

  setup do
    {:ok, pid} = RunMemory.start_link()
    ctx = Ctx.new(run_memory: pid)
    RunMemory.put_cost(ctx, 300)

    ref = &GiftPlans.entry_ref/3

    plan = %{
      "milestones" => [
        %{"id" => "ms_sub", "name" => "Sub", "condition" => nil, "blocks" => [%{"type" => "entry", "ref" => ref.("lists", "ls_1", "Sub Gift")}]},
        %{"id" => "ms_main", "name" => "Main", "condition" => nil, "blocks" => [
          %{"type" => "entry", "ref" => ref.("fusions", "fu_t3", nil)},
          %{"type" => "entry", "ref" => ref.("fusions", "fu_t4", nil)},
          %{"type" => "group", "letter" => "A", "min" => 1, "refs" => [ref.("upties", "up_1", nil), ref.("fusions", "fu_fixed", nil)]},
          %{"type" => "entry", "ref" => ref.("milestones", "ms_sub", nil)}
        ]}
      ],
      "library" => %{
        "fusions" => [
          %{"id" => "fu_t3", "name" => "T3 thing", "type" => "tiered", "target" => "Three"},
          %{"id" => "fu_t4", "name" => "T4 thing", "type" => "tiered", "target" => "Four"},
          %{"id" => "fu_fixed", "name" => "Fixed thing", "type" => "fixed", "target" => "Fixed"}
        ],
        "upties" => [%{"id" => "up_1", "gift" => "Owned", "target_level" => 2}],
        "lists" => [%{"id" => "ls_1", "name" => "Buys", "gifts" => ["Sub Gift"]}]
      }
    }

    gifts = [%{name: "Three", tier: 3}, %{name: "Four", tier: 4}, %{name: "Fixed", tier: 4}, %{name: "Owned", tier: 2}]
    state = %{plan: plan, reserve: 0, gifts_by_name: Map.new(gifts, &{&1.name, &1})}
    %{ctx: ctx, state: state, milestone: Enum.at(plan["milestones"], 1)}
  end

  test "preview lists each pass in order, sub-milestone entries first, uptie gifts and fusion targets as buys", %{ctx: ctx, state: state, milestone: milestone} do
    assert {:would_run, detail, _} = Milestone.preview(%{}, milestone, state, ctx)
    assert detail == "would uptie Owned; buy if on the shelf Sub Gift, Three, Four, Owned, Fixed; fuse Fixed; fuse T4 Four, T3 Three, then uptie again"
  end

  test "a partway uptie commits its group, so the group's other entries are dropped", %{ctx: ctx, state: state, milestone: milestone} do
    RunMemory.add_ego_gift(ctx, "g_owned", "Owned")

    assert {:would_run, "would uptie Owned; buy if on the shelf Sub Gift, Three, Four; fuse T4 Four, T3 Three, then uptie again", _} =
             Milestone.preview(%{}, milestone, state, ctx)
  end

  test "a done group drops its other entries, and a reached milestone is skipped", %{ctx: ctx, state: state, milestone: milestone} do
    RunMemory.add_ego_gift(ctx, "g_fixed", "Fixed")
    assert {:would_run, "would buy if on the shelf Sub Gift, Three, Four; fuse T4 Four, T3 Three, then uptie again", _} = Milestone.preview(%{}, milestone, state, ctx)

    for {id, name} <- [{"g_sub", "Sub Gift"}, {"g_3", "Three"}, {"g_4", "Four"}], do: RunMemory.add_ego_gift(ctx, id, name)
    assert {:skipped, "Main already reached", _} = Milestone.run(%{}, milestone, state, ctx)
  end

  test "optionals are listed separately and never stop the milestone from being reached", %{ctx: ctx, state: state, milestone: milestone} do
    state = %{state | plan: put_in(state.plan, ["library", "lists", Access.at(0), "gifts"], ["Sub Gift", "Extra"])}
    state = %{state | plan: GiftPlans.add_entry(state.plan, "ms_main", GiftPlans.entry_ref("lists", "ls_1", "Extra"))}
    state = %{state | plan: GiftPlans.set_entry_group(state.plan, "ms_main", GiftPlans.entry_ref("lists", "ls_1", "Extra"), "optional")}
    milestone = GiftPlans.find_milestone(state.plan, "ms_main")

    assert {:would_run, detail, _} = Milestone.preview(%{}, milestone, state, ctx)
    assert detail =~ "; optionals if possible: buy Extra"

    for {id, name} <- [{"g_fixed", "Fixed"}, {"g_sub", "Sub Gift"}, {"g_3", "Three"}, {"g_4", "Four"}], do: RunMemory.add_ego_gift(ctx, id, name)
    assert {:skipped, "Main already reached", _} = Milestone.run(%{}, milestone, state, ctx)
  end

  test "optional tier and affinity entries preview as labelled buys", %{ctx: ctx, state: state} do
    plan = put_in(state.plan, ["library", "lists", Access.at(0), "gifts"], ["Sub Gift", "affinity:burn:3"])
    plan = GiftPlans.add_entry(plan, "ms_main", GiftPlans.entry_ref("lists", "ls_1", "affinity:burn:3"))
    state = %{state | plan: plan}

    assert {:would_run, detail, _} = Milestone.preview(%{}, GiftPlans.find_milestone(plan, "ms_main"), state, ctx)
    assert detail =~ "optionals if possible: buy Any burn T3"
  end
end
