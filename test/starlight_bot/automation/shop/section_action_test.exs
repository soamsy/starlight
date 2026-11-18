defmodule StarlightBot.Automation.Shop.Actions.SectionTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Shop.Actions.{Section, Sell, TeamReplace}
  alias StarlightBot.{Ctx, GiftPlans}

  defp entry(id, subject, segment, fusion \\ nil) do
    %{"id" => id, "subject" => subject, "fusion" => fusion, "floors" => [Map.merge(GiftPlans.default_segment(), segment)]}
  end

  setup do
    {:ok, pid} = RunMemory.start_link()
    ctx = Ctx.new(run_memory: pid)
    RunMemory.put_cost(ctx, 300)

    tiered = %{"type" => "tiered", "routes" => []}

    section = %{
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

    plan = %{"sections" => [section]}

    state = %{
      plan: plan,
      floor: 1,
      reserve: 0,
      sell_popup_open: false,
      gifts_by_name: Map.new(gifts, &{&1.name, &1}),
      gifts_by_id: Map.new(gifts, &{&1.id, &1}),
      shop_type: :normal
    }

    %{ctx: ctx, state: state, section: section}
  end

  test "preview lists each pass in order, buying what's wanted and fusing required targets", %{ctx: ctx, state: state, section: section} do
    assert {:would_run, detail, _} = Section.preview(%{}, section, state, ctx)
    assert detail == "would uptie Owned; buy if on the shelf Three, Four, Owned, Fixed; fuse Fixed; fuse T4 Four, T3 Three, then uptie again"
  end

  test "a stage checks its section's heal entries and leaves the heal-only run to the section", %{ctx: ctx, state: state, section: section} do
    heal = entry("me_heal", %{"action" => "heal"}, %{"disposition" => "ignore", "buy" => false, "goal" => nil, "sinners" => ["yi_sang"]})
    root = Map.update!(section, "entries", &[heal | &1])
    stage = Map.merge(GiftPlans.new_section(), %{"id" => "ms_stage", "stage_of" => "ms_main"})
    state = %{state | plan: %{"sections" => [root, stage]}}
    assert {:would_run, "check heals: Greatly Heal yi_sang" <> _, _} = Section.preview(%{}, stage, state, ctx)
    assert Section.heals?(root, state, ctx)
    refute Section.heals?(stage, state, ctx)
  end

  test "preview lists the heal entries it would check first, skipping abandoned ones", %{ctx: ctx, state: state, section: section} do
    heal = entry("me_heal", %{"action" => "heal"}, %{"disposition" => "ignore", "buy" => false, "goal" => nil, "sinners" => ["yi_sang", "faust"]})
    gone = entry("me_gone", %{"action" => "heal_all"}, %{"disposition" => "ignore", "buy" => false, "goal" => nil, "abandoned" => true})
    section = Map.update!(section, "entries", &([heal, gone] ++ &1))

    replace = entry("me_replace", %{"action" => "skill_replace"}, %{"disposition" => "ignore", "buy" => false, "goal" => nil, "sinners" => ["faust"]})
    section = Map.update!(section, "entries", &([replace] ++ &1))

    assert {:would_run, "check heals: Greatly Heal yi_sang, faust; check skill replace for faust; would uptie Owned" <> _, _} = Section.preview(%{}, section, state, ctx)
  end

  test "team replace targets skip sinners already replaced, ones without an identity and anything past three", %{ctx: ctx, state: state, section: section} do
    replacements = for {sinner, profile} <- [{"yi_sang", 1}, {"faust", 2}, {"ryoshu", nil}, {"meursault", 4}, {"outis", 5}], do: %{"sinner" => sinner, "profile" => profile}
    team = entry("me_team", %{"action" => "team_replace"}, %{"disposition" => "ignore", "buy" => false, "goal" => nil, "replacements" => replacements})
    entries = GiftPlans.resolved_entries(Map.update!(section, "entries", &[team | &1]), 1)

    assert Enum.map(TeamReplace.pending(entries, state, ctx), & &1["sinner"]) == ["yi_sang", "faust", "meursault"]

    RunMemory.put_team_replace(ctx, "yi_sang", 1)
    assert Enum.map(TeamReplace.pending(entries, state, ctx), & &1["sinner"]) == ["faust", "meursault", "outis"]

    RunMemory.put_team_replace(ctx, "faust", 9)
    assert Enum.map(TeamReplace.pending(entries, state, ctx), & &1["sinner"]) == ["faust", "meursault", "outis"]

    state = Map.put(state, :team_replaced, MapSet.new(["faust", "meursault"]))
    assert Enum.map(TeamReplace.pending(entries, state, ctx), & &1["sinner"]) == ["outis"]
  end

  test "skill replace entries count toward the section until each sinner reaches the wanted distribution", %{ctx: ctx, state: state, section: section} do
    for {id, name} <- [{"g_fixed", "Fixed"}, {"g_3", "Three"}, {"g_4", "Four"}, {"g_owned", "Owned"}], do: RunMemory.add_ego_gift(ctx, id, name)
    RunMemory.set_ego_gift_uptie(ctx, "g_owned", 2)
    replace = entry("me_replace", %{"action" => "skill_replace"}, %{"disposition" => "ignore", "buy" => false, "goal" => "required", "sinners" => ["faust"], "target" => %{"s1" => 1, "s2" => 2, "s3" => 3}})
    plan = %{"sections" => [Map.update!(section, "entries", &[replace | &1])]}
    env = fn -> %{plan: plan, floor: 1, gifts: state.gifts_by_name, inventory: RunMemory.ego_gifts(ctx), skill_replaces: RunMemory.skill_replaces(ctx)} end

    refute GiftPlans.section_reached?(plan, "ms_main", env.())

    RunMemory.add_skill_replace(ctx, "faust", "s1_s3")
    refute GiftPlans.section_reached?(plan, "ms_main", env.())

    RunMemory.add_skill_replace(ctx, "faust", "s1_s3")
    assert GiftPlans.section_reached?(plan, "ms_main", env.())
  end

  test "overshooting the wanted distribution still counts as complete" do
    target = %{"s1" => 1, "s2" => 2, "s3" => 3}
    replaces = %{"s1_s3" => 3, "s2_s3" => 1}
    assert GiftPlans.skill_distribution(replaces) == %{"s1" => 0, "s2" => 1, "s3" => 5}
    assert GiftPlans.skill_complete?(GiftPlans.skill_distribution(replaces), target)
    refute GiftPlans.skill_complete?(GiftPlans.skill_distribution(%{"s1_s3" => 1}), target)
    assert GiftPlans.useful_skill_options(GiftPlans.skill_distribution(%{"s1_s3" => 1}), target, false) == ["s1_s3", "s2_s3", "s1_s2"]
    assert GiftPlans.useful_skill_options(GiftPlans.skill_distribution(%{}), target, true) == ["s1_s3"]
    assert GiftPlans.useful_skill_options(GiftPlans.skill_distribution(%{"s1_s3" => 1}), %{"s1" => 0, "s2" => 3, "s3" => 3}, true) == ["s1_s3", "s1_s2"]
    assert GiftPlans.useful_skill_options(GiftPlans.skill_distribution(%{"s1_s2" => 1, "s1_s3" => 1}), %{"s1" => 0, "s2" => 3, "s3" => 3}, true) == ["s1_s3"]
  end

  test "a reached section never consults its refresh cases", %{ctx: ctx, state: state, section: section} do
    for {id, name} <- [{"g_fixed", "Fixed"}, {"g_3", "Three"}, {"g_4", "Four"}], do: RunMemory.add_ego_gift(ctx, id, name)
    state = Map.put(state, :refreshes, 0)
    late = %{"id" => "rc_late", "condition" => %{"op" => "refreshes", "cmp" => "gte", "value" => 5}, "action" => "refresh"}
    leave = %{"id" => "rc_leave", "condition" => nil, "action" => "leave"}

    assert {:skipped, "Main already reached", state_after} = Section.run(%{}, Map.put(section, "refresh", [late]), state, ctx)
    refute Map.get(state_after, :left)

    section = Map.put(section, "refresh", [late, leave])
    assert {:skipped, "Main already reached", state_after} = Section.run(%{}, section, state, ctx)
    refute Map.get(state_after, :left)
    assert {:would_run, "Main already reached", _} = Section.preview(%{}, section, state, ctx)
  end

  test "a partway uptie commits its goal, so the goal's other entries are dropped", %{ctx: ctx, state: state, section: section} do
    RunMemory.add_ego_gift(ctx, "g_owned", "Owned")

    assert {:would_run, "would uptie Owned; buy if on the shelf Three, Four; fuse T4 Four, T3 Three, then uptie again", _} =
             Section.preview(%{}, section, state, ctx)
  end

  test "a done goal drops its other entries, and a reached section is skipped", %{ctx: ctx, state: state, section: section} do
    RunMemory.add_ego_gift(ctx, "g_fixed", "Fixed")
    assert {:would_run, "would buy if on the shelf Three, Four; fuse T4 Four, T3 Three, then uptie again", _} = Section.preview(%{}, section, state, ctx)

    for {id, name} <- [{"g_3", "Three"}, {"g_4", "Four"}], do: RunMemory.add_ego_gift(ctx, id, name)
    assert {:skipped, "Main already reached", _} = Section.run(%{}, section, state, ctx)
  end

  test "optional and Ignore + Buy entries are listed separately and never hold the section back", %{ctx: ctx, state: state, section: section} do
    section =
      Map.update!(section, "entries", fn entries ->
        entries ++
          [
            entry("me_extra", %{"gift" => "Extra"}, %{"goal" => "optional"}),
            entry("me_t2", GiftPlans.tier_subject([2]), %{"disposition" => "ignore", "goal" => nil})
          ]
      end)

    state = %{state | plan: %{"sections" => [section]}}

    assert {:would_run, detail, _} = Section.preview(%{}, section, state, ctx)
    assert detail =~ "; optionals if possible: buy Extra, Any T2"

    for {id, name} <- [{"g_fixed", "Fixed"}, {"g_3", "Three"}, {"g_4", "Four"}], do: RunMemory.add_ego_gift(ctx, id, name)
    assert {:skipped, "Main already reached", _} = Section.run(%{}, section, state, ctx)
  end

  test "sells go first, priciest first, up to the entry's max per floor", %{ctx: ctx, state: state, section: section} do
    for {id, name} <- [{"g_j1", "Junk One"}, {"g_j2", "Junk Two"}], do: RunMemory.add_ego_gift(ctx, id, name)

    assert {:would_run, "sell Junk Two; would uptie" <> _, _} = Section.preview(%{}, section, state, ctx)

    entries = GiftPlans.resolved_entries(section, 1)
    sells = GiftPlans.sell_entries(entries)
    assert [{%{name: "Junk Two"}, %{id: "me_t1"}}] = Sell.plan(sells, entries, MapSet.new(), state, ctx)
    assert Sell.plan(sells, entries, MapSet.new(), Map.put(state, :sold, %{"me_t1" => 1}), ctx) == []
    assert [{%{name: "Junk One"}, _}] = Sell.plan(sells, entries, MapSet.new(["Junk Two"]), state, ctx)

    ignored = entries ++ [%{id: "me_j2", subject: %{"gift" => "Junk Two"}, disposition: "ignore"}]
    assert [{%{name: "Junk One"}, _}] = Sell.plan(sells, ignored, MapSet.new(), state, ctx)
  end

  test "sells skip gifts reserved for a pending fusion", %{ctx: ctx, state: state, section: section} do
    for {id, name} <- [{"g_j1", "Junk One"}, {"g_j2", "Junk Two"}], do: RunMemory.add_ego_gift(ctx, id, name)

    entries = GiftPlans.resolved_entries(section, 1)
    sells = GiftPlans.sell_entries(entries)
    assert [{%{name: "Junk One"}, _}] = Sell.plan(sells, entries, MapSet.new(), state, ctx, %{"g_j2" => 1})
    assert Sell.plan(sells, entries, MapSet.new(), state, ctx, %{"g_j1" => 1, "g_j2" => 1}) == []
  end

  test "upties skip an ingredient waiting to be fused into a fixed fusion", %{ctx: ctx, state: state, section: section} do
    section = put_in(section, ["entries", Access.at(4), "floors", Access.at(0), "uptie"], 2)
    state = %{state | plan: %{"sections" => [section]}}
    RunMemory.add_ego_gift(ctx, "g_x", "X")

    assert {:would_run, detail, _} = Section.preview(%{}, section, state, ctx)
    refute detail =~ "uptie X"
  end
end
