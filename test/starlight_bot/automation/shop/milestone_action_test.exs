defmodule StarlightBot.Automation.Shop.Actions.MilestoneTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Shop.Actions.{Milestone, Sell}
  alias StarlightBot.{Ctx, GiftPlans}

  defp entry(id, subject, segment, fusion \\ nil) do
    %{"id" => id, "subject" => subject, "fusion" => fusion, "floors" => [Map.merge(GiftPlans.default_segment(), segment)]}
  end

  setup do
    {:ok, pid} = RunMemory.start_link()
    ctx = Ctx.new(run_memory: pid)
    RunMemory.put_cost(ctx, 300)

    tiered = %{"type" => "tiered", "routes" => []}

    milestone = %{
      "id" => "ms_main",
      "name" => "Main",
      "goals" => [%{"letter" => "A", "min" => 1}],
      "entries" => [
        entry("me_3", %{"gift" => "Three"}, %{"fuse" => true}, tiered),
        entry("me_4", %{"gift" => "Four"}, %{"fuse" => true}, tiered),
        entry("me_owned", %{"gift" => "Owned"}, %{"goal" => "A", "uptie" => 2}),
        entry("me_fixed", %{"gift" => "Fixed"}, %{"goal" => "A", "fuse" => true}, %{"type" => "fixed"}),
        entry("me_x", %{"gift" => "X"}, %{"goal" => "optional", "buy" => false}),
        entry("me_t1", GiftPlans.tier_subject([1]), %{"disposition" => "sell", "buy" => false, "goal" => nil, "max" => 1})
      ]
    }

    gifts = [
      %{id: "g_3", name: "Three", tier: 3},
      %{id: "g_4", name: "Four", tier: 4},
      %{id: "g_fixed", name: "Fixed", tier: 4, ingredients: "g_x"},
      %{id: "g_owned", name: "Owned", tier: 2},
      %{id: "g_x", name: "X", tier: 2},
      %{id: "g_j1", name: "Junk One", tier: 1, selling_cost: 30},
      %{id: "g_j2", name: "Junk Two", tier: 1, selling_cost: 60}
    ]

    plan = %{"milestones" => [milestone]}

    state = %{
      plan: plan,
      floor: 1,
      reserve: 0,
      sell_popup_open: false,
      gifts_by_name: Map.new(gifts, &{&1.name, &1}),
      gifts_by_id: Map.new(gifts, &{&1.id, &1})
    }

    %{ctx: ctx, state: state, milestone: milestone}
  end

  test "preview lists each pass in order, buying what's wanted and fusing required targets", %{ctx: ctx, state: state, milestone: milestone} do
    assert {:would_run, detail, _} = Milestone.preview(%{}, milestone, state, ctx)
    assert detail == "would uptie Owned; buy if on the shelf Three, Four, Owned, Fixed; fuse Fixed; fuse T4 Four, T3 Three, then uptie again"
  end

  test "preview lists the heal entries it would check first, skipping abandoned ones", %{ctx: ctx, state: state, milestone: milestone} do
    heal = entry("me_heal", %{"action" => "heal"}, %{"disposition" => "ignore", "buy" => false, "goal" => nil, "sinners" => ["yi_sang", "faust"]})
    gone = entry("me_gone", %{"action" => "heal_all"}, %{"disposition" => "ignore", "buy" => false, "goal" => nil, "abandoned" => true})
    milestone = Map.update!(milestone, "entries", &([heal, gone] ++ &1))

    replace = entry("me_replace", %{"action" => "skill_replace"}, %{"disposition" => "ignore", "buy" => false, "goal" => nil, "sinners" => ["faust"], "options" => ["s1_s3"]})
    milestone = Map.update!(milestone, "entries", &([replace] ++ &1))

    assert {:would_run, "check heals: Greatly Heal yi_sang, faust; check skill replace for faust; would uptie Owned" <> _, _} = Milestone.preview(%{}, milestone, state, ctx)
  end

  test "a reached milestone never consults its refresh cases", %{ctx: ctx, state: state, milestone: milestone} do
    for {id, name} <- [{"g_fixed", "Fixed"}, {"g_3", "Three"}, {"g_4", "Four"}], do: RunMemory.add_ego_gift(ctx, id, name)
    state = Map.put(state, :refreshes, 0)
    late = %{"id" => "rc_late", "condition" => %{"op" => "refreshes_gte", "value" => 5}, "action" => "refresh"}
    leave = %{"id" => "rc_leave", "condition" => nil, "action" => "leave"}

    assert {:skipped, "Main already reached", state_after} = Milestone.run(%{}, Map.put(milestone, "refresh", [late]), state, ctx)
    refute Map.get(state_after, :left)

    milestone = Map.put(milestone, "refresh", [late, leave])
    assert {:skipped, "Main already reached", state_after} = Milestone.run(%{}, milestone, state, ctx)
    refute Map.get(state_after, :left)
    assert {:would_run, "Main already reached", _} = Milestone.preview(%{}, milestone, state, ctx)
  end

  test "a partway uptie commits its goal, so the goal's other entries are dropped", %{ctx: ctx, state: state, milestone: milestone} do
    RunMemory.add_ego_gift(ctx, "g_owned", "Owned")

    assert {:would_run, "would uptie Owned; buy if on the shelf Three, Four; fuse T4 Four, T3 Three, then uptie again", _} =
             Milestone.preview(%{}, milestone, state, ctx)
  end

  test "a done goal drops its other entries, and a reached milestone is skipped", %{ctx: ctx, state: state, milestone: milestone} do
    RunMemory.add_ego_gift(ctx, "g_fixed", "Fixed")
    assert {:would_run, "would buy if on the shelf Three, Four; fuse T4 Four, T3 Three, then uptie again", _} = Milestone.preview(%{}, milestone, state, ctx)

    for {id, name} <- [{"g_3", "Three"}, {"g_4", "Four"}], do: RunMemory.add_ego_gift(ctx, id, name)
    assert {:skipped, "Main already reached", _} = Milestone.run(%{}, milestone, state, ctx)
  end

  test "optional and Ignore + Buy entries are listed separately and never hold the milestone back", %{ctx: ctx, state: state, milestone: milestone} do
    milestone =
      Map.update!(milestone, "entries", fn entries ->
        entries ++
          [
            entry("me_extra", %{"gift" => "Extra"}, %{"goal" => "optional"}),
            entry("me_t2", GiftPlans.tier_subject([2]), %{"disposition" => "ignore", "goal" => nil})
          ]
      end)

    state = %{state | plan: %{"milestones" => [milestone]}}

    assert {:would_run, detail, _} = Milestone.preview(%{}, milestone, state, ctx)
    assert detail =~ "; optionals if possible: buy Extra, Any T2"

    for {id, name} <- [{"g_fixed", "Fixed"}, {"g_3", "Three"}, {"g_4", "Four"}], do: RunMemory.add_ego_gift(ctx, id, name)
    assert {:skipped, "Main already reached", _} = Milestone.run(%{}, milestone, state, ctx)
  end

  test "sells go first, priciest first, up to the entry's max per floor", %{ctx: ctx, state: state, milestone: milestone} do
    for {id, name} <- [{"g_j1", "Junk One"}, {"g_j2", "Junk Two"}], do: RunMemory.add_ego_gift(ctx, id, name)

    assert {:would_run, "sell Junk Two; would uptie" <> _, _} = Milestone.preview(%{}, milestone, state, ctx)

    entries = GiftPlans.resolved_entries(milestone, 1)
    sells = GiftPlans.sell_entries(entries)
    assert [{%{name: "Junk Two"}, %{id: "me_t1"}}] = Sell.plan(sells, entries, MapSet.new(), state, ctx)
    assert Sell.plan(sells, entries, MapSet.new(), Map.put(state, :sold, %{"me_t1" => 1}), ctx) == []
    assert [{%{name: "Junk One"}, _}] = Sell.plan(sells, entries, MapSet.new(["Junk Two"]), state, ctx)

    ignored = entries ++ [%{id: "me_j2", subject: %{"gift" => "Junk Two"}, disposition: "ignore"}]
    assert [{%{name: "Junk One"}, _}] = Sell.plan(sells, ignored, MapSet.new(), state, ctx)
  end

  test "upties skip an ingredient waiting to be fused into a fixed fusion", %{ctx: ctx, state: state, milestone: milestone} do
    milestone = put_in(milestone, ["entries", Access.at(4), "floors", Access.at(0), "uptie"], 2)
    state = %{state | plan: %{"milestones" => [milestone]}}
    RunMemory.add_ego_gift(ctx, "g_x", "X")

    assert {:would_run, detail, _} = Milestone.preview(%{}, milestone, state, ctx)
    refute detail =~ "uptie X"
  end
end
