defmodule StarlightBot.GiftPlansTest do
  use ExUnit.Case, async: true

  alias StarlightBot.GiftPlans
  alias StarlightBot.GiftPlans.Routes

  defp gift(id, name, tier, opts \\ []) do
    %{
      id: id,
      name: name,
      tier: tier,
      affinity: Keyword.get(opts, :affinity, "burn"),
      ingredients: Keyword.get(opts, :ingredients),
      obtain_method: Keyword.get(opts, :obtain, "Shop"),
      selling_cost: Keyword.get(opts, :selling_cost, 10)
    }
  end

  defp gifts do
    [
      gift("g_glimpse", "Glimpse", 4),
      gift("g_drum", "Drumstick", 3, obtain: "\"Hell's Chicken\" Theme Floor and Shop"),
      gift("g_event", "Event Only", 2, obtain: "Event"),
      gift("g_soothe", "Soothe", 4, ingredients: "g_a,g_b,g_cook", obtain: "Fuse #g_a# + #g_b# + #g_cook#"),
      gift("g_cook", "Cookbook", 3, ingredients: "g_c,g_d", obtain: "Fuse #g_c# + #g_d#"),
      gift("g_a", "Ing A", 2),
      gift("g_b", "Ing B", 2),
      gift("g_c", "Ing C", 1),
      gift("g_d", "Ing D", 1),
      gift("g_e", "Ing E", 2),
      gift("g_twin", "Twin", 4, ingredients: "g_a,g_e", obtain: "Fuse #g_a# + #g_e#"),
      gift("g_lunar", "Lunar Memory", 5, affinity: "none", ingredients: "g_sm,g_pm,g_cm,gift_0,gift_0"),
      gift("g_sm", "Sundered Memory", 4, affinity: "slash"),
      gift("g_pm", "Punctured Memory", 4, affinity: "pierce"),
      gift("g_cm", "Crushed Memory", 4, affinity: "blunt"),
      gift("g_fc", "Fragment of Conceit", 4, affinity: "poise"),
      gift("g_fd", "Fragment of Decay", 4, affinity: "sinking")
    ]
  end

  defp by_name, do: Map.new(gifts(), &{&1.name, &1})
  defp by_id, do: Map.new(gifts(), &{&1.id, &1})
  defp routes_for(tier), do: Routes.defaults(tier)

  defp with_gifts(names) do
    data = GiftPlans.blank()
    id = hd(data["milestones"])["id"]
    data = Enum.reduce(names, data, &GiftPlans.add_gift(&2, id, &1, by_name(), fn tier -> routes_for(tier) end))
    {data, id}
  end

  defp entry_for(data, id, name), do: Enum.find(GiftPlans.find_milestone(data, id)["entries"], &(GiftPlans.subject_gift(&1) == name))

  defp env(data, owned, floor \\ 1) do
    inventory = Map.new(owned, fn {name, uptie} -> {by_name()[name].id, %{name: name, uptie: uptie, count: 1}} end)
    %{plan: data, floor: floor, gifts: by_name(), gifts_by_id: by_id(), inventory: inventory, owned: MapSet.new(Map.keys(owned))}
  end

  defp set_segment(data, id, name, from \\ 1, changes) do
    GiftPlans.update_segment(data, id, entry_for(data, id, name)["id"], from, &Map.merge(&1, changes))
  end

  describe "adding gifts to a milestone" do
    test "a new entry keeps and buys it, and fuses a tier fusable T4 by default" do
      {data, id} = with_gifts(["Glimpse", "Drumstick", "Event Only"])

      assert %{"fusion" => %{"type" => "tiered", "routes" => [_ | _]}, "floors" => [%{"from" => 1, "disposition" => "keep", "goal" => "required", "buy" => true, "fuse" => true, "uptie" => 0}]} =
               entry_for(data, id, "Glimpse")

      assert %{"fusion" => %{"type" => "tiered", "routes" => [%{"combo" => [2, 2, 2], "buy_up_to" => 2}, %{"combo" => [3, 2, 1]}]}, "floors" => [%{"fuse" => false}]} =
               entry_for(data, id, "Drumstick")
      assert %{"fusion" => nil, "floors" => [%{"fuse" => false}]} = entry_for(data, id, "Event Only")
    end

    test "a fixed fusion brings its ingredients along, nested fixed ones fused whatever their tier, without duplicates" do
      {data, id} = with_gifts(["Ing A", "Soothe"])
      names = Enum.map(GiftPlans.find_milestone(data, id)["entries"], &GiftPlans.subject_gift/1)

      assert names == ["Ing A", "Soothe", "Ing B", "Cookbook", "Ing C", "Ing D"]
      assert %{"fusion" => %{"type" => "fixed"}, "floors" => [%{"fuse" => true, "goal" => "required"}]} = entry_for(data, id, "Soothe")
      assert %{"fusion" => %{"type" => "fixed"}, "floors" => [%{"fuse" => true, "goal" => "optional", "buy" => true}]} = entry_for(data, id, "Cookbook")
      assert %{"floors" => [%{"goal" => "optional"}]} = entry_for(data, id, "Ing C")
      assert %{"floors" => [%{"goal" => "required"}]} = entry_for(data, id, "Ing A")
    end

    test "Lunar Memory adds its three memories and needs two Sin Fragments from the milestone" do
      {data, id} = with_gifts(["Lunar Memory"])
      milestone = GiftPlans.find_milestone(data, id)
      lunar = entry_for(data, id, "Lunar Memory")

      assert Enum.map(milestone["entries"], &GiftPlans.subject_gift/1) == ["Lunar Memory", "Sundered Memory", "Punctured Memory", "Crushed Memory"]
      assert GiftPlans.missing_ingredients(milestone, lunar, by_name()) == {[], 2}

      data = GiftPlans.add_gift(data, id, "Fragment of Conceit", by_name(), &routes_for/1)
      assert GiftPlans.missing_ingredients(GiftPlans.find_milestone(data, id), lunar, by_name()) == {[], 1}
      assert Enum.any?(GiftPlans.issues(data, by_name()), &(&1 =~ "Lunar Memory needs 1 more Sin Fragment(s)"))

      data = GiftPlans.add_gift(data, id, "Fragment of Decay", by_name(), &routes_for/1)
      assert GiftPlans.missing_ingredients(GiftPlans.find_milestone(data, id), lunar, by_name()) == {[], 0}
    end

    test "tier and affinity entries are added once and can't keep" do
      data = GiftPlans.blank()
      id = hd(data["milestones"])["id"]
      data = data |> GiftPlans.add_pattern(id, GiftPlans.tier_subject([2])) |> GiftPlans.add_pattern(id, GiftPlans.tier_subject([2]))
      data = GiftPlans.add_pattern(data, id, GiftPlans.affinity_subject("burn", [3, 2, 3]))
      [tier, affinity] = GiftPlans.find_milestone(data, id)["entries"]

      assert GiftPlans.subject_label(tier["subject"]) == "Any T2"
      assert GiftPlans.subject_label(affinity["subject"]) == "Any burn T2, T3"
      assert %{disposition: "ignore", buy: true, goal: nil} = GiftPlans.resolve(tier, 1)
      assert %{disposition: "ignore"} = GiftPlans.resolve(%{tier | "floors" => [%{hd(tier["floors"]) | "disposition" => "keep"}]}, 1)
    end
  end

  describe "heal costs" do
    test "each heal costs 100, Until healed doubles the top of the range, and Heal Everyone counts its times" do
      assert GiftPlans.action_cost_range("revive", %{"sinners" => ["a", "b", "c"]}) == {300, 300}
      assert GiftPlans.action_cost_range("heal", %{"sinners" => ["a", "b"], "repeat" => "until_full"}) == {200, 400}
      assert GiftPlans.action_cost_range("heal", %{"sinners" => ["a"], "repeat" => "once"}) == {100, 100}
      assert GiftPlans.action_cost_range("heal_all", %{"repeat" => "once"}) == {100, 100}
      assert GiftPlans.action_cost_range("heal_all", %{"repeat" => "3"}) == {300, 300}
      assert GiftPlans.action_cost_range("heal_all", %{"repeat" => "until_full"}) == {100, GiftPlans.heal_all_max() * 100}
    end
  end

  describe "floor timelines" do
    test "every default route makes its tier in both shops, except super-only extras" do
      for tier <- 1..4, route <- Routes.defaults(tier) do
        assert StarlightBot.GiftPlans.Combos.allowed?(route["combo"], tier, :super), "T#{tier} #{inspect(route["combo"])}"
      end

      assert GiftPlans.tier_fusable?(gift("g_t1", "Plain T1", 1))
      refute GiftPlans.tier_fusable?(gift("g_t5", "Plain T5", 5))
    end

    test "split copies the settings in force at that floor, and the latest segment at or below the floor applies" do
      {data, id} = with_gifts(["Glimpse"])
      entry_id = entry_for(data, id, "Glimpse")["id"]

      data = data |> GiftPlans.split_entry(id, entry_id, 5) |> set_segment(id, "Glimpse", 5, %{"disposition" => "sell", "max" => 1})
      data = GiftPlans.split_entry(data, id, entry_id, 8)
      entry = entry_for(data, id, "Glimpse")

      assert Enum.map(entry["floors"], & &1["from"]) == [1, 5, 8]
      assert %{disposition: "keep", fuse: true} = GiftPlans.resolve(entry, 4)
      assert %{disposition: "sell", fuse: false, buy: false, goal: nil, max: 1} = GiftPlans.resolve(entry, 6)
      assert %{disposition: "sell"} = GiftPlans.resolve(entry, 9)

      assert GiftPlans.keep_set(data, 4) == MapSet.new(["Glimpse"])
      assert GiftPlans.keep_set(data, 5) == MapSet.new()

      data = GiftPlans.remove_segment(data, id, entry_id, 5)
      assert %{disposition: "keep"} = GiftPlans.resolve(entry_for(data, id, "Glimpse"), 6)
      assert GiftPlans.remove_segment(data, id, entry_id, 1) == data
    end

    test "an abandoned floor ignores the gift, and a pattern's cap applies to buys as well as sells" do
      {data, id} = with_gifts(["Glimpse"])
      entry_id = entry_for(data, id, "Glimpse")["id"]
      data = data |> GiftPlans.split_entry(id, entry_id, 5) |> set_segment(id, "Glimpse", 5, %{"abandoned" => true})
      entry = entry_for(data, id, "Glimpse")

      assert %{disposition: "keep", buy: true} = GiftPlans.resolve(entry, 4)
      assert %{disposition: "ignore", buy: false, goal: nil, uptie: 0} = GiftPlans.resolve(entry, 5)
      assert GiftPlans.keep_set(data, 5) == MapSet.new()
      assert %{disposition: "ignore"} = GiftPlans.resolve(%{entry | "floors" => [%{hd(entry["floors"]) | "disposition" => "ignore"}]}, 1)

      pattern = %{"id" => "me_t1", "subject" => GiftPlans.tier_subject([1]), "floors" => [%{GiftPlans.default_segment() | "disposition" => "keep", "buy" => true, "max" => 2}]}
      assert %{disposition: "ignore", buy: true, max: 2} = GiftPlans.resolve(pattern, 1)
      assert %{buy: false, max: nil} = GiftPlans.resolve(%{pattern | "floors" => [%{hd(pattern["floors"]) | "buy" => false}]}, 1)
    end

    test "kept anywhere wins over a sell somewhere else, and issues say so" do
      {data, _id} = with_gifts(["Glimpse"])
      other = GiftPlans.new_milestone("Other")
      data = Map.update!(data, "milestones", &(&1 ++ [other]))
      data = data |> GiftPlans.add_gift(other["id"], "Glimpse", by_name(), &routes_for/1) |> set_segment(other["id"], "Glimpse", %{"disposition" => "sell"})

      assert GiftPlans.keep_set(data, 1) == MapSet.new(["Glimpse"])
      assert Enum.any?(GiftPlans.issues(data, by_name()), &(&1 =~ "Milestone Other: sells Glimpse from F1, but another milestone keeps it"))
    end

    test "the most specific matching entry rules a gift" do
      entries = [
        %{subject: GiftPlans.tier_subject([2]), disposition: "sell"},
        %{subject: GiftPlans.affinity_subject("burn", []), disposition: "ignore"},
        %{subject: GiftPlans.affinity_subject("burn", [2]), disposition: "sell"},
        %{subject: GiftPlans.gift_subject("Ing A"), disposition: "ignore"}
      ]

      assert GiftPlans.ruling_entry(entries, by_name()["Ing A"]).subject == %{"gift" => "Ing A"}
      assert GiftPlans.ruling_entry(entries, by_name()["Ing B"]).subject == %{"affinity" => "burn", "tiers" => [2]}
      assert GiftPlans.ruling_entry(entries, by_name()["Drumstick"]).subject == %{"affinity" => "burn", "tiers" => []}
      assert GiftPlans.ruling_entry(entries, by_name()["Sundered Memory"]) == nil
    end
  end

  describe "milestone goals" do
    test "required entries must be owned at their uptie level, optional ones never hold it back" do
      {data, id} = with_gifts(["Glimpse", "Drumstick"])
      data = data |> set_segment(id, "Glimpse", %{"uptie" => 2}) |> set_segment(id, "Drumstick", %{"goal" => "optional"})

      refute GiftPlans.milestone_reached?(data, id, env(data, %{}))
      refute GiftPlans.milestone_reached?(data, id, env(data, %{"Glimpse" => 1}))
      assert GiftPlans.milestone_reached?(data, id, env(data, %{"Glimpse" => 2}))
    end

    test "a goal needs its minimum, clamped to its members on that floor, and a partway member holds it" do
      {data, id} = with_gifts(["Glimpse", "Drumstick", "Event Only"])
      data = GiftPlans.add_goal(data, id)
      data = GiftPlans.set_goal_min(data, id, "A", 2)
      data = Enum.reduce(["Glimpse", "Drumstick", "Event Only"], data, &set_segment(&2, id, &1, %{"goal" => "A"}))
      data = set_segment(data, id, "Drumstick", %{"uptie" => 1})

      refute GiftPlans.milestone_reached?(data, id, env(data, %{"Glimpse" => 0}))
      refute GiftPlans.milestone_reached?(data, id, env(data, %{"Glimpse" => 0, "Drumstick" => 0}))
      assert GiftPlans.milestone_reached?(data, id, env(data, %{"Glimpse" => 0, "Event Only" => 0}))

      entry_id = entry_for(data, id, "Event Only")["id"]
      data = data |> GiftPlans.split_entry(id, entry_id, 5) |> set_segment(id, "Event Only", 5, %{"goal" => "optional"})
      entry_id = entry_for(data, id, "Drumstick")["id"]
      data = data |> GiftPlans.split_entry(id, entry_id, 5) |> set_segment(id, "Drumstick", 5, %{"disposition" => "ignore"})

      refute GiftPlans.milestone_reached?(data, id, env(data, %{"Glimpse" => 0}, 4))
      assert GiftPlans.milestone_reached?(data, id, env(data, %{"Glimpse" => 0}, 5))
    end

    test "needed? drops a goal's open members once enough are committed" do
      {data, id} = with_gifts(["Glimpse", "Drumstick"])
      data = GiftPlans.add_goal(data, id)
      data = data |> set_segment(id, "Glimpse", %{"goal" => "A"}) |> set_segment(id, "Drumstick", %{"goal" => "A", "uptie" => 1})

      progress = GiftPlans.progress(data, id, env(data, %{}))
      assert Enum.all?(progress.entries, &GiftPlans.needed?(progress, &1))

      progress = GiftPlans.progress(data, id, env(data, %{"Drumstick" => 0}))
      assert Enum.map(Enum.filter(progress.entries, &GiftPlans.needed?(progress, &1)), & &1.gift) == ["Drumstick"]
    end

    test "removing a goal makes its entries required" do
      {data, id} = with_gifts(["Glimpse"])
      data = data |> GiftPlans.add_goal(id) |> set_segment(id, "Glimpse", %{"goal" => "A"}) |> GiftPlans.remove_goal(id, "A")

      assert GiftPlans.find_milestone(data, id)["goals"] == []
      assert %{"floors" => [%{"goal" => "required"}]} = entry_for(data, id, "Glimpse")
    end

    test "an owned fixed fusion with fuse on covers every ingredient down the chain" do
      {data, id} = with_gifts(["Soothe"])
      data = Enum.reduce(["Ing B", "Cookbook", "Ing C"], data, &set_segment(&2, id, &1, %{"goal" => "required"}))

      refute GiftPlans.milestone_reached?(data, id, env(data, %{"Ing A" => 0}))
      assert GiftPlans.milestone_reached?(data, id, env(data, %{"Soothe" => 0}))

      progress = GiftPlans.progress(data, id, env(data, %{"Ing C" => 0}))
      soothe = Enum.find(progress.entries, &(&1.gift == "Soothe"))
      assert GiftPlans.status(progress, soothe) == :open
      assert MapSet.member?(progress.pending, "Ing C")

      data = set_segment(data, id, "Soothe", %{"fuse" => false})
      refute GiftPlans.milestone_reached?(data, id, env(data, %{"Soothe" => 0}))
    end

    test "issues flag missing ingredients, upties on fused ingredients, shared ingredients and empty goals" do
      {data, id} = with_gifts(["Soothe", "Twin"])
      data = data |> GiftPlans.remove_entry(id, entry_for(data, id, "Ing D")["id"]) |> set_segment(id, "Ing B", %{"uptie" => 2}) |> GiftPlans.add_goal(id)
      issues = GiftPlans.issues(data, by_name())

      assert "Milestone Shop Done: Cookbook needs Ing D in the milestone." in issues
      assert "Milestone Shop Done: Ing B is upgraded to +2 but gets fused into Soothe." in issues
      assert "Milestone Shop Done: Soothe and Twin both use Ing A; fusing one leaves the other without it." in issues
      assert "Milestone Shop Done: goal A has no entries." in issues
    end
  end

  describe "eval_condition/2" do
    setup do
      %{env: %{wallet: 250, owned: MapSet.new(["Fiery Down"])}}
    end

    test "nil always passes", %{env: env} do
      assert GiftPlans.eval_condition(nil, env)
    end

    test "evaluates and/or trees", %{env: env} do
      tree = %{
        "op" => "and",
        "children" => [
          %{"op" => "cost_gte", "value" => 200},
          %{"op" => "or", "children" => [%{"op" => "missing_gift", "gift" => "Fiery Down"}, %{"op" => "has_gift", "gift" => "Fiery Down"}]}
        ]
      }

      assert GiftPlans.eval_condition(tree, env)
      refute GiftPlans.eval_condition(put_in(tree, ["children", Access.at(0), "value"], 300), env)
    end

    test "cost checks fail when cost is unknown" do
      refute GiftPlans.eval_condition(%{"op" => "cost_gte", "value" => 0}, %{wallet: nil, owned: MapSet.new()})
      refute GiftPlans.eval_condition(%{"op" => "cost_lt", "value" => 100}, %{wallet: nil, owned: MapSet.new()})
    end

    test "cost under passes only below the value", %{env: env} do
      assert GiftPlans.eval_condition(%{"op" => "cost_lt", "value" => 251}, env)
      refute GiftPlans.eval_condition(%{"op" => "cost_lt", "value" => 250}, env)
      assert GiftPlans.condition_label(%{"op" => "cost_lt", "value" => 250}) == "cost < 250"
    end

    test "milestone leaves check the milestone on the env's floor" do
      {data, id} = with_gifts(["Glimpse"])
      leaf = %{"op" => "milestone", "milestone" => id}

      refute GiftPlans.eval_condition(leaf, env(data, %{}))
      assert GiftPlans.eval_condition(leaf, env(data, %{"Glimpse" => 0}))
      assert GiftPlans.eval_condition(%{"op" => "milestone_not", "milestone" => id}, env(data, %{}))
      assert GiftPlans.condition_label(leaf, data) == "milestone Shop Done reached"
      assert GiftPlans.condition_label(%{"op" => "milestone", "milestone" => "ms_gone"}, data) == "milestone (deleted) reached"
    end

    test "goal leaves check one goal of the milestone" do
      {data, id} = with_gifts(["Glimpse", "Fiery Down"])
      data = data |> GiftPlans.add_goal(id) |> set_segment(id, "Glimpse", %{"goal" => "A"})
      leaf = %{"op" => "goal", "milestone" => id, "goal" => "A"}
      not_leaf = %{"op" => "goal_not", "milestone" => id, "goal" => "A"}

      refute GiftPlans.eval_condition(leaf, env(data, %{}))
      assert GiftPlans.eval_condition(not_leaf, env(data, %{}))
      assert GiftPlans.eval_condition(leaf, env(data, %{"Glimpse" => 0}))
      refute GiftPlans.eval_condition(not_leaf, env(data, %{"Glimpse" => 0}))
      assert GiftPlans.eval_condition(%{leaf | "goal" => nil}, env(data, %{"Glimpse" => 0}))
      assert GiftPlans.condition_label(leaf, data) == "goal A of Shop Done reached"
    end
  end

  test "refresh count conditions read the shop's refreshes, counting none when unknown" do
    under = %{"op" => "refreshes_lt", "value" => 2}
    at_least = %{"op" => "refreshes_gte", "value" => 2}

    assert GiftPlans.eval_condition(under, %{refreshes: 1})
    refute GiftPlans.eval_condition(under, %{refreshes: 2})
    assert GiftPlans.eval_condition(at_least, %{refreshes: 2})
    assert GiftPlans.eval_condition(under, %{})
    assert GiftPlans.condition_label(under) == "refreshes < 2"
    assert GiftPlans.condition_label(at_least) == "refreshes >= 2"
  end

  test "prune_condition/1 drops empty groups and collapses an empty root to nil" do
    assert GiftPlans.prune_condition(%{"op" => "and", "children" => []}) == nil

    assert GiftPlans.prune_condition(%{
             "op" => "and",
             "children" => [%{"op" => "or", "children" => []}, %{"op" => "cost_gte", "value" => 1}]
           }) == %{"op" => "and", "children" => [%{"op" => "cost_gte", "value" => 1}]}
  end

  test "condition_label/1 renders nested groups" do
    tree = %{
      "op" => "and",
      "children" => [
        %{"op" => "cost_gte", "value" => 200},
        %{"op" => "or", "children" => [%{"op" => "missing_gift", "gift" => "A"}, %{"op" => "has_gift", "gift" => "B"}]}
      ]
    }

    assert GiftPlans.condition_label(tree) == "cost >= 200 AND (missing A OR owns B)"
  end

  test "a fused fixed fusion counts as having its ingredients for every milestone, not just its own" do
    {data, first} = with_gifts(["Ing A"])
    second = GiftPlans.new_milestone("Second")
    data = Map.update!(data, "milestones", &(&1 ++ [second]))
    data = GiftPlans.add_gift(data, second["id"], "Soothe", by_name(), fn tier -> routes_for(tier) end)

    refute GiftPlans.milestone_reached?(data, first, env(data, %{}))
    assert GiftPlans.milestone_reached?(data, first, env(data, %{"Ing A" => 0}))
    assert GiftPlans.milestone_reached?(data, first, env(data, %{"Soothe" => 0}))
  end

  test "cabinet_pick_count/1 is one pick plus one per starting-choice grace, up to three" do
    pick = fn index -> %{"index" => index, "enhance" => 0} end

    assert GiftPlans.cabinet_pick_count(%{"grace_picks" => []}) == 1
    assert GiftPlans.cabinet_pick_count(%{"grace_picks" => [pick.(0), pick.(3)]}) == 2
    assert GiftPlans.cabinet_pick_count(%{"grace_picks" => [pick.(3), pick.(9)]}) == 3
  end

  test "add_loadout_keep/4 adds an optional keep that isn't bought or fused, and skips gifts already listed" do
    {data, id} = with_gifts(["Ing A"])
    data = GiftPlans.add_loadout_keep(data, id, "Event Only", by_name())
    data = GiftPlans.add_loadout_keep(data, id, "Event Only", by_name())
    data = GiftPlans.add_loadout_keep(data, id, "Ing A", by_name())
    data = GiftPlans.add_loadout_keep(data, id, "No Such Gift", by_name())

    milestone = GiftPlans.find_milestone(data, id)
    assert length(milestone["entries"]) == 2
    assert %{"floors" => [%{"disposition" => "keep", "goal" => "optional", "buy" => false, "fuse" => false}]} = entry_for(data, id, "Event Only")
    assert %{"floors" => [%{"goal" => "required", "buy" => true}]} = entry_for(data, id, "Ing A")
  end

  describe "fodder and uptie planning" do
    setup do
      gifts = [
        %{id: "g1", name: "Keep Me", tier: 2, selling_cost: 100},
        %{id: "g2", name: "Junk T1", tier: 1, selling_cost: 50},
        %{id: "g3", name: "Pricey T1", tier: 1, selling_cost: 80},
        %{id: "g4", name: "Junk T2", tier: 2, selling_cost: 90},
        %{id: "g5", name: "Wealth", tier: 6, selling_cost: 999},
        %{id: "g6", name: "Uptied T1", tier: 1, selling_cost: 200}
      ]

      owned = %{
        "g1" => %{name: "Keep Me", uptie: 0, count: 1},
        "g2" => %{name: "Junk T1", uptie: 0, count: 1},
        "g3" => %{name: "Pricey T1", uptie: 0, count: 1},
        "g4" => %{name: "Junk T2", uptie: 0, count: 1},
        "g5" => %{name: "Wealth", uptie: 0, count: 1},
        "g6" => %{name: "Uptied T1", uptie: 1, count: 1}
      }

      %{owned: owned, by_id: Map.new(gifts, &{&1.id, &1}), by_name: Map.new(gifts, &{&1.name, &1})}
    end

    test "fodder/3 drops kept gifts, uptied gifts and tiers outside 1 to 4", %{owned: owned, by_id: by_id} do
      names = owned |> GiftPlans.fodder(MapSet.new(["Keep Me"]), by_id) |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["Junk T1", "Junk T2", "Pricey T1"]
    end

    test "fodder/3 lists a stacked gift once per copy", %{by_id: by_id} do
      owned = %{"g2" => %{name: "Junk T1", uptie: 0, count: 2}, "g4" => %{name: "Junk T2", uptie: 0, count: 1}}
      names = owned |> GiftPlans.fodder(MapSet.new(), by_id) |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["Junk T1", "Junk T1", "Junk T2"]
    end

    test "chance_comet?/1 is true only when grace 8 is picked" do
      assert GiftPlans.chance_comet?(%{"grace_picks" => [%{"index" => 0, "enhance" => 0}, %{"index" => 8, "enhance" => 2}]})
      refute GiftPlans.chance_comet?(%{"grace_picks" => [%{"index" => 0, "enhance" => 0}]})
      refute GiftPlans.chance_comet?(%{})
    end

    test "uptie_plan/5 skips unowned and finished gifts, falls back to +1, and stops when it can't pay in full", %{owned: owned, by_name: by_name} do
      defs = [
        %{"gift" => "Not Owned", "target_level" => 2},
        %{"gift" => "Uptied T1", "target_level" => 1},
        %{"gift" => "Keep Me", "target_level" => 2},
        %{"gift" => "Junk T1", "target_level" => 2}
      ]

      assert {[%{gift: %{name: "Keep Me"}, from: 0, to: 2, price: 180}, %{gift: %{name: "Junk T1"}, from: 0, to: 1, price: 50}], reason} =
               GiftPlans.uptie_plan(defs, owned, by_name, 300, 3)

      assert reason =~ "can't afford Junk T1 +2 (150, have 120), going to +1"

      assert {[%{gift: %{name: "Keep Me"}}], reason} = GiftPlans.uptie_plan(defs, owned, by_name, 220, 3)
      assert reason =~ "can't afford Junk T1 +2 (150, have 40)"

      assert {[_, _], "end of list"} = GiftPlans.uptie_plan(defs, owned, by_name, 400, 3)
      assert {[_], "reached max gifts"} = GiftPlans.uptie_plan(defs, owned, by_name, 400, 1)
    end
  end

  describe "gift search" do
    test "gift_search_starlight_cost/1 is the cumulative Starlight total for the number of picks" do
      assert Enum.map(0..3, &GiftPlans.gift_search_starlight_cost/1) == [0, 70, 160, 270]
    end

    test "gift_search_tabs/2 groups searchable gifts by tab in first-seen order and caps at 3" do
      gifts_by_name = %{
        "Bleed A" => %{id: "b1", name: "Bleed A", tier: 2, affinity: "bleed"},
        "Plain" => %{id: "n1", name: "Plain", tier: 3, affinity: "none"},
        "Bleed B" => %{id: "b2", name: "Bleed B", tier: 1, affinity: "bleed"},
        "Big" => %{id: "x1", name: "Big", tier: 4, affinity: "bleed"},
        "Slash" => %{id: "s1", name: "Slash", tier: 2, affinity: "slash"}
      }

      tabs = GiftPlans.gift_search_tabs(["Bleed A", "Big", "Plain", "Unknown", "Bleed B", "Slash"], gifts_by_name)
      assert Enum.map(tabs, fn {tab, gifts} -> {tab, Enum.map(gifts, & &1.id)} end) == [{"bleed", ["b1", "b2"]}, {"keywordless", ["n1"]}]
    end

    test "issues/2 flags tier 4 picks and more than 3 gifts" do
      gifts_by_name = %{"Big" => %{id: "g_big", name: "Big", tier: 4}, "Small" => %{id: "g_small", name: "Small", tier: 2}}
      data = Map.put(GiftPlans.blank(), "gift_search", ["Big", "Small", "Small", "Small"])

      assert Enum.filter(GiftPlans.issues(data, gifts_by_name), &(&1 =~ "Gift search")) == [
               "Gift search has 4 gifts; only 3 can be picked.",
               "Gift search: Big is T4; only T3 and under show up."
             ]
    end

    test "normalize/1 defaults gift_search to an empty list" do
      assert GiftPlans.normalize(%{"version" => 4})["gift_search"] == []
    end
  end

  test "blank/1 starts with one empty milestone" do
    data = GiftPlans.blank("burn")

    assert data["version"] == 5
    assert data["affinity"] == "burn"
    assert [%{"name" => "Shop Done", "goals" => [], "entries" => []}] = data["milestones"]
    assert GiftPlans.issues(data) == []
  end

  test "normalize/1 turns a v4 plan into a v5 plan whose first milestone is the one its first workflow runs" do
    data = %{
      "version" => 4,
      "milestones" => [GiftPlans.new_milestone("A"), %{GiftPlans.new_milestone("B") | "id" => "ms_b"}],
      "workflows" => [%{"id" => "wf_1", "name" => "Standard", "steps" => [%{"kind" => "if", "then" => [%{"kind" => "milestone", "milestone" => "ms_b"}], "else" => []}]}],
      "floor_schedule" => [%{"from_floor" => 1, "workflow" => "wf_1"}]
    }

    normalized = GiftPlans.normalize(data)
    assert normalized["version"] == 5
    assert Enum.map(normalized["milestones"], & &1["id"]) |> hd() == "ms_b"
    refute Map.has_key?(normalized, "workflows")
  end

  test "normalize/1 resets anything that isn't a v4 plan" do
    assert GiftPlans.normalize(%{"version" => 3, "library" => %{}})["milestones"] |> hd() |> Map.get("entries") == []
  end

  describe "mounting trials schedule" do
    test "plans default to avoiding enemy HP from F1, and the latest row at or below the floor wins" do
      assert GiftPlans.blank()["mounting_trials"] == [%{"from_floor" => 1, "mode" => "avoid_hp"}]
      assert GiftPlans.normalize(Map.delete(GiftPlans.blank(), "mounting_trials"))["mounting_trials"] == [%{"from_floor" => 1, "mode" => "avoid_hp"}]

      data = %{"mounting_trials" => [%{"from_floor" => 1, "mode" => "avoid_hp"}, %{"from_floor" => 5, "mode" => "best_gift"}]}
      assert GiftPlans.mounting_trials_mode(data, 4) == "avoid_hp"
      assert GiftPlans.mounting_trials_mode(data, 5) == "best_gift"
      assert GiftPlans.mounting_trials_mode(%{"mounting_trials" => []}, 3) == "best_gift"
    end
  end

  describe "import_milestone/2" do
    defp source do
      leaf = fn id -> %{"op" => "milestone", "milestone" => id} end
      refresh_case = fn id, condition -> %{"id" => id, "condition" => condition, "action" => "refresh", "affinity" => nil, "max" => nil} end

      %{
        "id" => "ms_src",
        "name" => "Shop",
        "goals" => [],
        "entries" => [
          %{"id" => "me_1", "subject" => %{"gift" => "Glimpse"}, "group" => "grp_x", "floors" => []},
          %{"id" => "me_2", "subject" => %{"gift" => "Drumstick"}, "group" => "grp_x", "floors" => []},
          %{"id" => "me_3", "subject" => %{"gift" => "Soothe"}, "floors" => []}
        ],
        "refresh" => [refresh_case.("rc_1", %{"op" => "and", "children" => [leaf.("ms_src"), leaf.("ms_here"), leaf.("ms_gone")]})],
        "refresh_floors" => [%{"from" => 3, "cases" => [refresh_case.("rc_2", leaf.("ms_src"))]}]
      }
    end

    defp target, do: %{"milestones" => [%{"id" => "ms_here", "name" => "Shop"}]}

    test "gives the copy fresh ids and keeps groups together" do
      {data, milestone, _dropped} = GiftPlans.import_milestone(target(), source())
      assert [_, ^milestone] = data["milestones"]
      refute milestone["id"] == "ms_src"
      [first, second, third] = milestone["entries"]
      assert first["group"] == second["group"]
      refute first["group"] == "grp_x"
      refute Map.has_key?(third, "group")
      ids = [first["id"], second["id"], third["id"], hd(milestone["refresh"])["id"], hd(hd(milestone["refresh_floors"])["cases"])["id"]]
      assert length(Enum.uniq(ids)) == 5
      assert Enum.all?(ids, &(&1 not in ~w(me_1 me_2 me_3 rc_1 rc_2)))
    end

    test "renames a clashing name" do
      {_data, milestone, _dropped} = GiftPlans.import_milestone(target(), source())
      assert milestone["name"] == "Shop copy"
    end

    test "points self references at the copy, keeps known ones and drops unknown ones" do
      {_data, milestone, dropped} = GiftPlans.import_milestone(target(), source())
      %{"children" => [own, known, unknown]} = hd(milestone["refresh"])["condition"]
      assert own["milestone"] == milestone["id"]
      assert known["milestone"] == "ms_here"
      assert unknown["milestone"] == nil
      assert hd(hd(milestone["refresh_floors"])["cases"])["condition"]["milestone"] == milestone["id"]
      assert dropped == 1
    end
  end
end
