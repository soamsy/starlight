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
    id = hd(data["sections"])["id"]
    data = Enum.reduce(names, data, &GiftPlans.add_gift(&2, id, &1, by_name(), fn tier -> routes_for(tier) end))
    {data, id}
  end

  defp entry_for(data, id, name), do: Enum.find(GiftPlans.find_section(data, id)["entries"], &(GiftPlans.subject_gift(&1) == name))

  defp env(data, owned, floor \\ 1) do
    inventory = Map.new(owned, fn {name, uptie} -> {by_name()[name].id, %{name: name, uptie: uptie, count: 1}} end)
    %{plan: data, floor: floor, gifts: by_name(), gifts_by_id: by_id(), inventory: inventory, owned: MapSet.new(Map.keys(owned))}
  end

  defp set_segment(data, id, name, from \\ 1, changes) do
    GiftPlans.update_segment(data, id, entry_for(data, id, name)["id"], from, &Map.merge(&1, changes))
  end

  describe "adding gifts to a section" do
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
      names = Enum.map(GiftPlans.find_section(data, id)["entries"], &GiftPlans.subject_gift/1)

      assert names == ["Ing A", "Soothe", "Ing B", "Cookbook", "Ing C", "Ing D"]
      assert %{"fusion" => %{"type" => "fixed"}, "floors" => [%{"fuse" => true, "goal" => "required"}]} = entry_for(data, id, "Soothe")
      assert %{"fusion" => %{"type" => "fixed"}, "floors" => [%{"fuse" => true, "goal" => "optional", "buy" => true}]} = entry_for(data, id, "Cookbook")
      assert %{"floors" => [%{"goal" => "optional"}]} = entry_for(data, id, "Ing C")
      assert %{"floors" => [%{"goal" => "required"}]} = entry_for(data, id, "Ing A")
    end

    test "Lunar Memory adds its three memories and needs two Sin Fragments from the section" do
      {data, id} = with_gifts(["Lunar Memory"])
      section = GiftPlans.find_section(data, id)
      lunar = entry_for(data, id, "Lunar Memory")

      assert Enum.map(section["entries"], &GiftPlans.subject_gift/1) == ["Lunar Memory", "Sundered Memory", "Punctured Memory", "Crushed Memory"]
      assert GiftPlans.missing_ingredients(section, lunar, by_name()) == {[], 2}

      data = GiftPlans.add_gift(data, id, "Fragment of Conceit", by_name(), &routes_for/1)
      assert GiftPlans.missing_ingredients(GiftPlans.find_section(data, id), lunar, by_name()) == {[], 1}
      assert Enum.any?(GiftPlans.issues(data, by_name()), &(&1 =~ "Lunar Memory needs 1 more Sin Fragment(s)"))

      data = GiftPlans.add_gift(data, id, "Fragment of Decay", by_name(), &routes_for/1)
      assert GiftPlans.missing_ingredients(GiftPlans.find_section(data, id), lunar, by_name()) == {[], 0}
    end

    test "tier and affinity entries are added once and can't keep" do
      data = GiftPlans.blank()
      id = hd(data["sections"])["id"]
      data = data |> GiftPlans.add_pattern(id, GiftPlans.tier_subject([2])) |> GiftPlans.add_pattern(id, GiftPlans.tier_subject([2]))
      data = GiftPlans.add_pattern(data, id, GiftPlans.affinity_subject("burn", [3, 2, 3]))
      [tier, affinity] = GiftPlans.find_section(data, id)["entries"]

      assert GiftPlans.subject_label(tier["subject"]) == "Any T2"
      assert GiftPlans.subject_label(affinity["subject"]) == "Any burn T2, T3"
      assert GiftPlans.subject_label(GiftPlans.affinity_subject("none", [4])) == "Any keywordless T4"
      assert GiftPlans.subject_label(GiftPlans.affinity_subject("none", [])) == "Any keywordless"
      assert GiftPlans.subject_matches?(GiftPlans.affinity_subject("none", [4]), %{affinity: "none", tier: 4})
      refute GiftPlans.subject_matches?(GiftPlans.affinity_subject("none", [4]), %{affinity: "burn", tier: 4})
      assert %{disposition: "ignore", buy: true, goal: nil} = GiftPlans.resolve(tier, 1)
      assert %{disposition: "ignore"} = GiftPlans.resolve(%{tier | "floors" => [%{hd(tier["floors"]) | "disposition" => "keep"}]}, 1)
    end
  end

  describe "heal costs" do
    test "each heal costs 100, Until healed doubles the top of the range, and Heal Everyone counts its times" do
      assert GiftPlans.action_cost_range("revive", %{"sinners" => ["a", "b", "c"]}) == {0, 600}
    assert GiftPlans.action_cost_range("revive", %{"sinners" => ["a", "b", "c"], "heal_after" => false}) == {0, 300}
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
      other = GiftPlans.new_section()
      data = Map.update!(data, "sections", &(&1 ++ [other]))
      data = data |> GiftPlans.add_gift(other["id"], "Glimpse", by_name(), &routes_for/1) |> set_segment(other["id"], "Glimpse", %{"disposition" => "sell"})

      assert GiftPlans.keep_set(data, 1) == MapSet.new(["Glimpse"])
      assert Enum.any?(GiftPlans.issues(data, by_name()), &(&1 =~ "Stage 1: sells Glimpse from F1, but another stage keeps it"))
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

  describe "run type timelines" do
    defp with_timeline(kinds) do
      {data, id} = with_gifts(["Glimpse", "Drumstick"])
      entry_id = entry_for(data, id, "Glimpse")["id"]
      {GiftPlans.add_timeline(data, id, entry_id, "tl_x", kinds), id, entry_id}
    end

    test "a new timeline copies the base tabs and only takes kinds no other timeline uses" do
      {data, id, entry_id} = with_timeline(["all_hard", "bogus"])
      entry = entry_for(data, id, "Glimpse")
      assert [%{"id" => "tl_x", "kinds" => ["all_hard"], "floors" => floors}] = entry["timelines"]
      assert floors == entry["floors"]

      assert GiftPlans.add_timeline(data, id, entry_id, "tl_y", ["all_hard"]) == data
      assert GiftPlans.add_timeline(data, id, entry_id, "tl_y", []) == data
      assert [_, %{"kinds" => ["all_normal"]}] = entry_for(GiftPlans.add_timeline(data, id, entry_id, "tl_y", ["all_normal", "all_hard"]), id, "Glimpse")["timelines"]
    end

    test "tab edits on a timeline leave the base tabs alone" do
      {data, id, entry_id} = with_timeline(["all_hard"])
      data = data |> GiftPlans.split_entry(id, entry_id, 4, "tl_x") |> GiftPlans.update_segment(id, entry_id, 4, &Map.put(&1, "disposition", "sell"), "tl_x")
      entry = entry_for(data, id, "Glimpse")

      assert Enum.map(entry["floors"], & &1["from"]) == [1]
      assert [%{"floors" => [%{"from" => 1}, %{"from" => 4, "disposition" => "sell"}]}] = entry["timelines"]

      data = data |> GiftPlans.move_segment(id, entry_id, 4, 6, "tl_x") |> GiftPlans.remove_segment(id, entry_id, 1, "tl_x")
      assert [%{"floors" => [%{"from" => 1}, %{"from" => 6}]}] = entry_for(data, id, "Glimpse")["timelines"]

      data = GiftPlans.remove_segment(data, id, entry_id, 6, "tl_x")
      assert [%{"floors" => [%{"from" => 1}]}] = entry_for(data, id, "Glimpse")["timelines"]
    end

    test "toggling kinds never shares a kind between timelines and unselecting the last one removes the timeline" do
      {data, id, entry_id} = with_timeline(["all_hard"])
      data = GiftPlans.add_timeline(data, id, entry_id, "tl_y", ["all_normal"])
      kinds = fn data, timeline -> data |> entry_for(id, "Glimpse") |> GiftPlans.find_timeline(timeline) |> Map.fetch!("kinds") end

      assert kinds.(GiftPlans.toggle_timeline_kind(data, id, entry_id, "tl_x", "extreme"), "tl_x") == ["all_hard", "extreme"]
      assert kinds.(GiftPlans.toggle_timeline_kind(data, id, entry_id, "tl_x", "all_normal"), "tl_x") == ["all_hard"]
      removed = GiftPlans.toggle_timeline_kind(data, id, entry_id, "tl_x", "all_hard")
      assert removed |> entry_for(id, "Glimpse") |> GiftPlans.find_timeline("tl_x") == nil
      assert kinds.(removed, "tl_y") == ["all_normal"]
      assert GiftPlans.toggle_timeline_kind(data, id, entry_id, "tl_x", "nonsense") == data
      assert entry_for(GiftPlans.remove_timeline(GiftPlans.remove_timeline(data, id, entry_id, "tl_x"), id, entry_id, "tl_y"), id, "Glimpse") |> Map.has_key?("timelines") == false
    end

    test "for_run swaps in the matching timeline, with extreme falling back to hard from F1" do
      {data, id, entry_id} = with_timeline(["all_hard"])
      data = GiftPlans.update_segment(data, id, entry_id, 1, &Map.put(&1, "disposition", "sell"), "tl_x")
      disposition = fn data, kind -> data |> GiftPlans.for_run(kind) |> entry_for(id, "Glimpse") |> GiftPlans.resolve(1) |> Map.fetch!(:disposition) end

      assert disposition.(data, "all_normal") == "keep"
      assert disposition.(data, "becomes_hard") == "keep"
      assert disposition.(data, "all_hard") == "sell"
      assert disposition.(data, "extreme") == "sell"
      refute Map.has_key?(entry_for(GiftPlans.for_run(data, "all_hard"), id, "Glimpse"), "timelines")

      data = GiftPlans.add_timeline(data, id, entry_id, "tl_e", ["extreme"])
      data = GiftPlans.update_segment(data, id, entry_id, 1, &Map.put(&1, "disposition", "ignore"), "tl_e")
      assert disposition.(data, "extreme") == "ignore"
      assert disposition.(data, "all_hard") == "sell"
    end

    test "a stage whose entries are all abandoned for the run is dropped, like a stage that does not apply" do
      {data, id} = with_gifts(["Glimpse"])
      {data, stage} = GiftPlans.add_stage(data, id)
      data = GiftPlans.add_gift(data, stage["id"], "Drumstick", by_name(), fn tier -> routes_for(tier) end)
      drum = entry_for(data, stage["id"], "Drumstick")
      data = GiftPlans.update_entry(data, stage["id"], drum["id"], fn entry -> %{entry | "floors" => Enum.map(entry["floors"], &Map.put(&1, "abandoned", true))} end)
      data = GiftPlans.add_timeline(data, stage["id"], drum["id"], "tl_x", ["extreme"])
      data = GiftPlans.update_segment(data, stage["id"], drum["id"], 1, &Map.put(&1, "abandoned", false), "tl_x")

      assert Enum.map(GiftPlans.for_run(data, "all_normal")["sections"], & &1["id"]) == [id]
      assert Enum.map(GiftPlans.for_run(data, "extreme")["sections"], & &1["id"]) == [id, stage["id"]]
    end

    test "a gift with timelines counts as scheduled and issues are checked per run type" do
      {data, id, _entry_id} = with_timeline(["all_hard"])
      assert GiftPlans.scheduled?(entry_for(data, id, "Glimpse"))
      refute GiftPlans.scheduled?(entry_for(data, id, "Drumstick"))
      assert is_list(GiftPlans.issues(data, by_name()))
    end

    test "joining a group copies the timelines of the group" do
      {data, id, entry_id} = with_timeline(["all_hard"])
      other_id = entry_for(data, id, "Drumstick")["id"]
      ids = [entry_id, other_id]
      data = GiftPlans.join_group(data, id, other_id, GiftPlans.group_key(entry_for(data, id, "Glimpse")), ids)
      assert [%{"id" => "tl_x", "kinds" => ["all_hard"]}] = entry_for(data, id, "Drumstick")["timelines"]
    end
  end

  describe "section goals" do
    test "required entries must be owned at their uptie level, optional ones never hold it back" do
      {data, id} = with_gifts(["Glimpse", "Drumstick"])
      data = data |> set_segment(id, "Glimpse", %{"uptie" => 2}) |> set_segment(id, "Drumstick", %{"goal" => "optional"})

      refute GiftPlans.section_reached?(data, id, env(data, %{}))
      refute GiftPlans.section_reached?(data, id, env(data, %{"Glimpse" => 1}))
      assert GiftPlans.section_reached?(data, id, env(data, %{"Glimpse" => 2}))
    end

    test "a section that pursues optional gifts is never reached, even with nothing left to own" do
      {data, id} = with_gifts(["Glimpse"])
      owned = env(data, %{"Glimpse" => 0})
      assert GiftPlans.section_reached?(data, id, owned)

      pursuing = GiftPlans.update_section(data, id, &Map.put(&1, "pursue_optional", true))
      refute GiftPlans.section_reached?(pursuing, id, owned)
      assert GiftPlans.normalize(pursuing) |> GiftPlans.find_section(id) |> Map.fetch!("pursue_optional")
    end

    test "a goal needs its minimum, clamped to its members on that floor, and a partway member holds it" do
      {data, id} = with_gifts(["Glimpse", "Drumstick", "Event Only"])
      data = GiftPlans.add_goal(data, id)
      data = GiftPlans.set_goal_min(data, id, "A", 2)
      data = Enum.reduce(["Glimpse", "Drumstick", "Event Only"], data, &set_segment(&2, id, &1, %{"goal" => "A"}))
      data = set_segment(data, id, "Drumstick", %{"uptie" => 1})

      refute GiftPlans.section_reached?(data, id, env(data, %{"Glimpse" => 0}))
      refute GiftPlans.section_reached?(data, id, env(data, %{"Glimpse" => 0, "Drumstick" => 0}))
      assert GiftPlans.section_reached?(data, id, env(data, %{"Glimpse" => 0, "Event Only" => 0}))

      entry_id = entry_for(data, id, "Event Only")["id"]
      data = data |> GiftPlans.split_entry(id, entry_id, 5) |> set_segment(id, "Event Only", 5, %{"goal" => "optional"})
      entry_id = entry_for(data, id, "Drumstick")["id"]
      data = data |> GiftPlans.split_entry(id, entry_id, 5) |> set_segment(id, "Drumstick", 5, %{"disposition" => "ignore"})

      refute GiftPlans.section_reached?(data, id, env(data, %{"Glimpse" => 0}, 4))
      assert GiftPlans.section_reached?(data, id, env(data, %{"Glimpse" => 0}, 5))
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

      assert GiftPlans.find_section(data, id)["goals"] == []
      assert %{"floors" => [%{"goal" => "required"}]} = entry_for(data, id, "Glimpse")
    end

    test "an owned fixed fusion with fuse on covers every ingredient down the chain" do
      {data, id} = with_gifts(["Soothe"])
      data = Enum.reduce(["Ing B", "Cookbook", "Ing C"], data, &set_segment(&2, id, &1, %{"goal" => "required"}))

      refute GiftPlans.section_reached?(data, id, env(data, %{"Ing A" => 0}))
      assert GiftPlans.section_reached?(data, id, env(data, %{"Soothe" => 0}))

      progress = GiftPlans.progress(data, id, env(data, %{"Ing C" => 0}))
      soothe = Enum.find(progress.entries, &(&1.gift == "Soothe"))
      assert GiftPlans.status(progress, soothe) == :open
      assert MapSet.member?(progress.pending, "Ing C")

      data = set_segment(data, id, "Soothe", %{"fuse" => false})
      refute GiftPlans.section_reached?(data, id, env(data, %{"Soothe" => 0}))
    end

    test "issues flag missing ingredients, upties on fused ingredients, shared ingredients and empty goals" do
      {data, id} = with_gifts(["Soothe", "Twin"])
      data = data |> GiftPlans.remove_entry(id, entry_for(data, id, "Ing D")["id"]) |> set_segment(id, "Ing B", %{"uptie" => 2}) |> GiftPlans.add_goal(id)
      issues = GiftPlans.issues(data, by_name())

      assert "Stage 1: Cookbook needs Ing D in this stage." in issues
      assert "Stage 1: Ing B is upgraded to +2 but gets fused into Soothe." in issues
      assert "Stage 1: Soothe and Twin both use Ing A; fusing one leaves the other without it." in issues
      assert "Stage 1: goal A has no entries." in issues
    end
  end

  describe "eval_condition/2" do
    setup do
      %{env: %{wallet: 250, owned: MapSet.new(["Fiery Down"])}}
    end

    test "nil always passes", %{env: env} do
      assert GiftPlans.eval_condition(nil, env)
    end

    test "owns reads the inventory and tolerates an env without one" do
      leaf = %{"op" => "owns", "gift" => "Downpour"}
      inventory = %{1 => %{name: "Downpour", uptie: 0, count: 1}}

      assert GiftPlans.eval_condition(leaf, %{inventory: inventory})
      refute GiftPlans.eval_condition(leaf, %{inventory: %{}})
      refute GiftPlans.eval_condition(leaf, %{floor: 1, plan: %{}})
      assert GiftPlans.eval_condition(Map.put(leaf, "not", true), %{floor: 1, plan: %{}})
    end

    test "evaluates and/or trees", %{env: env} do
      tree = %{
        "op" => "and",
        "children" => [
          %{"op" => "cost", "cmp" => "gte", "value" => 200},
          %{"op" => "or", "children" => [%{"op" => "owns", "gift" => "Fiery Down", "not" => true}, %{"op" => "owns", "gift" => "Fiery Down"}]}
        ]
      }

      assert GiftPlans.eval_condition(tree, env)
      refute GiftPlans.eval_condition(put_in(tree, ["children", Access.at(0), "value"], 300), env)
    end

    test "cost checks fail when cost is unknown" do
      refute GiftPlans.eval_condition(%{"op" => "cost", "cmp" => "gte", "value" => 0}, %{wallet: nil, owned: MapSet.new()})
      refute GiftPlans.eval_condition(%{"op" => "cost", "cmp" => "lte", "value" => 99}, %{wallet: nil, owned: MapSet.new()})
    end

    test "cost compares with eq, gte and lte, and not flips the result", %{env: env} do
      at_most = fn value -> %{"op" => "cost", "cmp" => "lte", "value" => value} end
      assert GiftPlans.eval_condition(at_most.(250), env)
      refute GiftPlans.eval_condition(at_most.(249), env)
      assert GiftPlans.eval_condition(Map.put(at_most.(249), "not", true), env)
      assert GiftPlans.eval_condition(%{"op" => "cost", "cmp" => "eq", "value" => 250}, env)
      assert GiftPlans.condition_label(at_most.(250)) == "cost <= 250"
      assert GiftPlans.condition_label(%{"op" => "cost", "cmp" => "eq", "value" => 250, "not" => true}) == "not cost = 250"
    end

    test "stage leaves check which stage the shop is on" do
      {data, id} = with_gifts(["Glimpse"])
      leaf = %{"op" => "stage", "stage" => id}
      done = %{"op" => "stage", "stage" => "done"}
      owned = env(data, %{"Glimpse" => 0})
      missing = env(data, %{})

      assert GiftPlans.eval_condition(leaf, missing)
      refute GiftPlans.eval_condition(leaf, owned)
      refute GiftPlans.eval_condition(Map.put(leaf, "not", true), missing)
      refute GiftPlans.eval_condition(done, Map.put(missing, :current_section, id))
      assert GiftPlans.eval_condition(done, Map.put(owned, :current_section, id))
      refute GiftPlans.eval_condition(done, owned)
      refute GiftPlans.eval_condition(%{"op" => "stage", "stage" => nil}, missing)
      assert GiftPlans.condition_label(leaf, data) == "on Stage 1"
      assert GiftPlans.condition_label(Map.put(leaf, "not", true), data) == "not on Stage 1"
      assert GiftPlans.condition_label(done, data) == "all stages done"
      assert GiftPlans.condition_label(%{"op" => "stage", "stage" => "ms_gone"}, data) == "on (deleted)"
    end

    test "goal leaves check one goal of the section" do
      {data, id} = with_gifts(["Glimpse", "Fiery Down"])
      data = data |> GiftPlans.add_goal(id) |> set_segment(id, "Glimpse", %{"goal" => "A"})
      leaf = %{"op" => "goal", "goal" => "A"}
      goal_env = fn owned -> Map.put(env(data, owned), :current_section, id) end
      not_leaf = %{"op" => "goal", "goal" => "A", "not" => true}

      refute GiftPlans.eval_condition(leaf, goal_env.(%{}))
      assert GiftPlans.eval_condition(not_leaf, goal_env.(%{}))
      assert GiftPlans.eval_condition(leaf, goal_env.(%{"Glimpse" => 0}))
      refute GiftPlans.eval_condition(not_leaf, goal_env.(%{"Glimpse" => 0}))
      assert GiftPlans.eval_condition(%{leaf | "goal" => nil}, goal_env.(%{"Glimpse" => 0}))
      assert GiftPlans.condition_label(leaf, data) == "goal A done"
    end
  end

  test "refresh count conditions read the shop's refreshes, counting none when unknown" do
    under = %{"op" => "refreshes", "cmp" => "lte", "value" => 1}
    at_least = %{"op" => "refreshes", "cmp" => "gte", "value" => 2}

    assert GiftPlans.eval_condition(under, %{refreshes: 1})
    refute GiftPlans.eval_condition(under, %{refreshes: 2})
    assert GiftPlans.eval_condition(at_least, %{refreshes: 2})
    assert GiftPlans.eval_condition(under, %{})
    assert GiftPlans.condition_label(under) == "refreshes <= 1"
    assert GiftPlans.condition_label(at_least) == "refreshes >= 2"
  end

  test "cost after refresh subtracts the next refresh price of the case's action" do
    after_refresh = %{"op" => "cost", "cmp" => "gte", "value" => 100, "when" => "after"}
    env = %{wallet: 150, refresh_costs: %{"refresh" => 45, "affinity_refresh" => 120}, case_action: "refresh"}

    assert GiftPlans.eval_condition(after_refresh, env)
    refute GiftPlans.eval_condition(after_refresh, %{env | case_action: "affinity_refresh"})
    assert GiftPlans.eval_condition(after_refresh, %{env | case_action: "leave"})
    assert GiftPlans.eval_condition(%{after_refresh | "when" => "before"}, %{env | case_action: "affinity_refresh"})
    assert GiftPlans.condition_label(after_refresh) == "cost after refresh >= 100"
    assert GiftPlans.condition_leaf(%{"op" => "cost", "cmp" => "gte", "value" => "5", "when" => "after"})["when"] == "after"
    refute Map.has_key?(GiftPlans.condition_leaf(%{"op" => "cost", "value" => "5", "when" => "before"}), "when")
  end

  test "prune_condition/1 drops empty groups and collapses an empty root to nil" do
    assert GiftPlans.prune_condition(%{"op" => "and", "children" => []}) == nil

    assert GiftPlans.prune_condition(%{
             "op" => "and",
             "children" => [%{"op" => "or", "children" => []}, %{"op" => "cost", "cmp" => "gte", "value" => 1}]
           }) == %{"op" => "and", "children" => [%{"op" => "cost", "cmp" => "gte", "value" => 1}]}
  end

  test "condition_label/1 renders nested groups" do
    tree = %{
      "op" => "and",
      "children" => [
        %{"op" => "cost", "cmp" => "gte", "value" => 200},
        %{"op" => "or", "children" => [%{"op" => "owns", "gift" => "A", "not" => true}, %{"op" => "owns", "gift" => "B"}]}
      ]
    }

    assert GiftPlans.condition_label(tree) == "cost >= 200 AND (missing A OR owns B)"
  end

  test "a fused fixed fusion counts as having its ingredients for every section, not just its own" do
    {data, first} = with_gifts(["Ing A"])
    second = GiftPlans.new_section()
    data = Map.update!(data, "sections", &(&1 ++ [second]))
    data = GiftPlans.add_gift(data, second["id"], "Soothe", by_name(), fn tier -> routes_for(tier) end)

    refute GiftPlans.section_reached?(data, first, env(data, %{}))
    assert GiftPlans.section_reached?(data, first, env(data, %{"Ing A" => 0}))
    assert GiftPlans.section_reached?(data, first, env(data, %{"Soothe" => 0}))
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

    section = GiftPlans.find_section(data, id)
    assert length(section["entries"]) == 2
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

  test "blank/1 starts with one empty section" do
    data = GiftPlans.blank("burn")

    assert data["version"] == 6
    assert data["affinity"] == "burn"
    assert [%{"goals" => [], "entries" => []}] = data["sections"]
    assert GiftPlans.issues(data) == []
  end

  test "normalize/1 resets anything that isn't a v4 plan" do
    assert GiftPlans.normalize(%{"version" => 3, "library" => %{}})["sections"] |> hd() |> Map.get("entries") == []
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

  describe "encounter reward schedule" do
    test "defaults to the shipped order and the latest row at or below the floor wins" do
      default = ~w(gain_cost starlight random_gift cost_plus_gift resources)
      assert GiftPlans.blank()["encounter_rewards"] == [%{"from_floor" => 1, "order" => default}]
      assert GiftPlans.normalize(Map.delete(GiftPlans.blank(), "encounter_rewards"))["encounter_rewards"] == [%{"from_floor" => 1, "order" => default}]

      data = %{"encounter_rewards" => [%{"from_floor" => 1, "order" => default}, %{"from_floor" => 6, "order" => ["starlight"]}]}
      assert GiftPlans.encounter_reward_order(data, 5) == default
      assert GiftPlans.encounter_reward_order(data, 6) == ["starlight"]
      assert GiftPlans.encounter_reward_order(%{"encounter_rewards" => []}, 3) == default
    end

    test "hooks end with the tiers, highest first" do
      assert GiftPlans.encounter_reward_hooks(["starlight"]) ==
               [:encounter_reward_starlight, :encounter_reward_tier_7, :encounter_reward_tier_5, :encounter_reward_tier_4, :encounter_reward_tier_3]
    end
  end

  describe "multi entry moves and pastes" do
    defp entry(id, extra \\ %{}), do: Map.merge(%{"id" => id, "subject" => %{"gift" => id}, "floors" => [%{"from" => 1, "disposition" => "keep"}]}, extra)

    defp grouped_plan do
      floors = [%{"from" => 1, "disposition" => "keep"}, %{"from" => 5, "disposition" => "keep"}]

      entries = [
        entry("a"),
        entry("b"),
        entry("c"),
        entry("g1", %{"group" => "grp", "scheduled" => true, "floors" => floors}),
        entry("g2", %{"group" => "grp", "scheduled" => true, "floors" => floors})
      ]

      %{"sections" => [%{"id" => "ms", "name" => "Shop", "entries" => entries}]}
    end

    defp entries_of(data), do: hd(data["sections"])["entries"]
    defp ids_of(data), do: data |> entries_of() |> Enum.map(& &1["id"])

    test "moves several entries into a group in the given order" do
      data = GiftPlans.move_entries(grouped_plan(), "ms", ["a", "c"], "grp", ["g1", "a", "c", "g2"])
      grouped = entries_of(data) |> Enum.filter(&(&1["group"] == "grp")) |> Enum.map(& &1["id"])
      assert grouped == ["g1", "a", "c", "g2"]
      assert ids_of(data) == ["b", "g1", "a", "c", "g2"]
    end

    test "moves several entries out of a group" do
      data = GiftPlans.move_entries(grouped_plan(), "ms", ["g1", "g2"], nil, ["g2", "a", "g1", "b", "c"])
      assert ids_of(data) == ["g2", "a", "g1", "b", "c"]
      refute Enum.any?(entries_of(data), &Map.has_key?(&1, "group"))
    end

    test "pastes clones with fresh ids right after the target row" do
      data = GiftPlans.paste_entries(grouped_plan(), "ms", [entry("x"), entry("y")], "a")
      assert [%{"id" => "a"}, first, second, %{"id" => "b"} | _] = entries_of(data)
      assert first["subject"] == %{"gift" => "x"}
      assert second["subject"] == %{"gift" => "y"}
      assert first["id"] != "x" and first["id"] != second["id"]
    end

    test "pasting below a grouped entry joins that group" do
      data = GiftPlans.paste_entries(grouped_plan(), "ms", [entry("x"), entry("y")], "g1")
      group = Enum.filter(entries_of(data), &(&1["group"] == "grp"))
      assert Enum.map(group, & &1["subject"]["gift"]) == ["g1", "x", "y", "g2"]
      assert Enum.all?(group, &(length(&1["floors"]) == 2))
    end

    test "pasted entries from one group stay together under a new group" do
      source = [entry("x", %{"group" => "old"}), entry("y", %{"group" => "old"})]
      data = GiftPlans.paste_entries(grouped_plan(), "ms", source, "b")
      [x, y] = entries_of(data) |> Enum.filter(&(&1["subject"]["gift"] in ["x", "y"]))
      assert x["group"] == y["group"]
      refute x["group"] in ["old", "grp"]
    end
  end

  describe "stages" do
    defp end_entry(id, subject, segment) do
      %{"id" => id, "subject" => subject, "fusion" => nil, "floors" => [Map.merge(GiftPlans.default_segment(), segment)]}
    end

    defp heal_segment, do: %{"disposition" => "ignore", "goal" => nil, "buy" => false, "sinners" => ["yi_sang"], "repeat" => "once"}

    defp staged do
      data = %{"sections" => [%{GiftPlans.new_section() | "id" => "ms_a"}, %{GiftPlans.new_section() | "id" => "ms_b"}]}
      {data, stage} = GiftPlans.add_stage(data, "ms_a")
      {data, stage}
    end

    test "a stage lands right after its section" do
      data = %{"sections" => [%{GiftPlans.new_section() | "id" => "ms_a"}, %{GiftPlans.new_section() | "id" => "ms_b"}]}
      {data, stage} = GiftPlans.add_stage(data, "ms_a")
      {data, second} = GiftPlans.add_stage(data, "ms_a")
      assert Enum.map(data["sections"], & &1["id"]) == ["ms_a", stage["id"], second["id"], "ms_b"]
      assert stage["stage_of"] == "ms_a"
      assert stage["name"] == "Stage 2"
      assert second["name"] == "Stage 3"
    end

    test "moving a stage swaps it with its sibling and keeps its name" do
      {data, first} = staged()
      {data, second} = GiftPlans.add_stage(data, "ms_a")
      moved = GiftPlans.move_stage(data, second["id"], -1)
      assert Enum.map(moved["sections"], & &1["id"]) == ["ms_a", second["id"], first["id"], "ms_b"]
      assert Enum.map(GiftPlans.stages(moved, "ms_a"), & &1["name"]) == ["Stage 3", "Stage 2"]
      assert GiftPlans.move_stage(moved, second["id"], -1) == moved
      assert GiftPlans.move_stage(moved, "ms_a", 1) == moved
    end

    test "the first stage swaps content with the section, heals stay put" do
      {data, stage} = staged()
      heal = end_entry("h1", %{"action" => "heal"}, heal_segment())
      gift = %{"id" => "g1", "subject" => %{"gift" => "Gift"}}
      data = data |> GiftPlans.update_section("ms_a", &%{&1 | "goals" => [%{"letter" => "A"}], "entries" => [heal, gift]}) 
      swapped = GiftPlans.move_stage(data, stage["id"], -1)
      root = GiftPlans.find_section(swapped, "ms_a")
      assert root["goals"] == []
      assert root["entries"] == [heal]
      first = GiftPlans.find_section(swapped, stage["id"])
      assert first["goals"] == [%{"letter" => "A"}]
      assert first["entries"] == [gift]
      assert GiftPlans.swap_first_stage(swapped, "ms_a") == data
    end

    test "a stage uses its section's refresh cases and counts goals on its own" do
      {data, stage} = staged()
      refresh_case = %{"id" => "rc_1", "condition" => nil, "action" => "refresh", "affinity" => nil, "max" => 2}
      data = GiftPlans.update_section(data, "ms_a", &Map.put(&1, "refresh", [refresh_case]))
      stage = GiftPlans.find_section(data, stage["id"])
      assert GiftPlans.matching_refresh_case(stage, %{plan: data, wallet: 1000}) == refresh_case
      assert GiftPlans.matching_refresh_case(stage, %{plan: data, wallet: 1000, case_runs: %{"rc_1" => 2}}) == nil
      assert stage["refresh"] == []
    end

    test "goal letters are unique across a section and its stages, and conditions find them by letter" do
      {data, stage} = staged()
      data = data |> GiftPlans.add_goal("ms_a") |> GiftPlans.add_goal(stage["id"]) |> GiftPlans.add_goal("ms_a")
      assert GiftPlans.goal_letters(GiftPlans.find_section(data, "ms_a")) == ["A", "C"]
      assert GiftPlans.goal_letters(GiftPlans.find_section(data, stage["id"])) == ["B"]
      assert GiftPlans.all_goal_letters(data, stage["id"]) == ["A", "C", "B"]
      entry = %{"id" => "me_s", "subject" => %{"gift" => "Glimpse"}, "fusion" => nil, "floors" => [%{GiftPlans.default_segment() | "goal" => "B"}]}
      data = GiftPlans.update_section(data, stage["id"], &Map.put(&1, "entries", [entry]))
      refute GiftPlans.goal_reached?(data, "ms_a", "B", %{plan: data})
      owned = %{plan: data, inventory: %{"g_glimpse" => %{name: "Glimpse", uptie: 0}}}
      assert GiftPlans.goal_reached?(data, "ms_a", "B", owned)
      assert GiftPlans.goal_reached?(data, stage["id"], "B", owned)
    end

    test "while working a stage its definition of a gift beats the earlier stage's for protection" do
      {data, stage} = staged()
      keep = %{GiftPlans.default_segment() | "disposition" => "keep"}
      sell = %{GiftPlans.default_segment() | "disposition" => "sell", "buy" => false, "goal" => nil}
      mine = fn id, segment -> %{"id" => id, "subject" => %{"gift" => "Glimpse"}, "fusion" => nil, "floors" => [segment]} end
      data = data |> GiftPlans.update_section("ms_a", &Map.put(&1, "entries", [mine.("me_1", keep)])) |> GiftPlans.update_section(stage["id"], &Map.put(&1, "entries", [mine.("me_2", sell)]))
      assert MapSet.member?(GiftPlans.keep_set(data, 1), "Glimpse")
      assert MapSet.member?(GiftPlans.keep_set(data, 1, "ms_a"), "Glimpse")
      refute MapSet.member?(GiftPlans.keep_set(data, 1, stage["id"]), "Glimpse")
    end

    test "conditions can name a stage's required entries or goals and the run type" do
      {data, stage} = staged()
      entry = %{"id" => "me_s", "subject" => %{"gift" => "Glimpse"}, "fusion" => nil, "floors" => [GiftPlans.default_segment()]}
      data = GiftPlans.update_section(data, stage["id"], &Map.put(&1, "entries", [entry]))
      data = GiftPlans.for_run(data, "extreme")
      owned = %{plan: data, inventory: %{"g_glimpse" => %{name: "Glimpse", uptie: 0}}, current_section: "ms_a"}
      empty = %{owned | inventory: %{}}

      leaf = GiftPlans.condition_leaf(%{"op" => "goal", "goal" => "required:" <> stage["id"]})
      assert leaf == %{"op" => "goal", "goal" => "required", "stage" => stage["id"]}
      assert GiftPlans.eval_condition(leaf, owned)
      refute GiftPlans.eval_condition(leaf, empty)
      assert GiftPlans.condition_label(leaf, data) == "Required of Stage 2 done"

      stage_leaf = %{"op" => "stage", "stage" => stage["id"]}
      refute GiftPlans.eval_condition(stage_leaf, owned)
      assert GiftPlans.eval_condition(stage_leaf, empty)

      extreme = GiftPlans.condition_leaf(%{"op" => "run_kind", "kind" => "extreme"})
      hard = GiftPlans.condition_leaf(%{"op" => "run_kind", "kind" => "all_hard"})
      normal = GiftPlans.condition_leaf(%{"op" => "run_kind", "kind" => "all_normal"})
      assert GiftPlans.eval_condition(extreme, owned)
      assert GiftPlans.eval_condition(hard, owned)
      refute GiftPlans.eval_condition(normal, owned)
      refute GiftPlans.eval_condition(extreme, %{plan: %{}})
      assert GiftPlans.condition_label(Map.put(normal, "not", true), data) == "run is not Normal F1-F5"
      assert GiftPlans.condition_leaf(%{"op" => "run_kind", "kind" => "bogus"})["kind"] == "all_normal"
    end

    test "the run type survives normalize" do
      {data, _stage} = staged()
      kept = data |> GiftPlans.for_run("extreme") |> Map.put("version", GiftPlans.version()) |> GiftPlans.normalize()
      assert kept["run_kind"] == "extreme"
    end

    test "sections lists the section then its stages" do
      {data, stage} = staged()
      assert Enum.map(GiftPlans.sections(data, "ms_a"), & &1["id"]) == ["ms_a", stage["id"]]
      assert Enum.map(GiftPlans.sections(data, "ms_b"), & &1["id"]) == ["ms_b"]
    end

    test "for_run puts pursue_optional on the last section" do
      {data, stage} = staged()
      data = GiftPlans.update_section(data, "ms_a", &Map.put(&1, "pursue_optional", true))
      flags = fn data, kind -> for m <- GiftPlans.for_run(data, kind)["sections"], m["id"] in ["ms_a", stage["id"]], do: {m["id"], m["pursue_optional"]} end
      assert flags.(data, "extreme") == [{"ms_a", false}, {stage["id"], true}]
      assert flags.(GiftPlans.update_section(data, "ms_a", &Map.put(&1, "pursue_optional", false)), "extreme") == [{"ms_a", false}, {stage["id"], false}]
    end

    test "a later stage carries earlier optional gifts, not patterns or required ones, and its own definition wins" do
      {data, stage} = staged()
      gift = fn id, name, segment -> end_entry(id, %{"gift" => name}, segment) end
      keep_optional = %{"disposition" => "keep", "goal" => "optional", "buy" => true}
      ignore_buy = %{"disposition" => "ignore", "goal" => nil, "buy" => true}
      required = %{"disposition" => "keep", "goal" => "required", "buy" => true}

      root_entries = [gift.("e_opt", "Opt", keep_optional), end_entry("e_ign", %{"tiers" => [1]}, ignore_buy), end_entry("e_pat", %{"tiers" => [2]}, keep_optional), gift.("e_req", "Req", required), gift.("e_dup", "Dup", keep_optional)]
      data = GiftPlans.update_section(data, "ms_a", &Map.put(&1, "entries", root_entries))
      data = GiftPlans.update_section(data, stage["id"], &Map.put(&1, "entries", [gift.("s_dup", "Dup", required), gift.("s_own", "Own", required)]))

      carried = GiftPlans.carried_entries(data, GiftPlans.find_section(data, stage["id"]), 1)
      assert Enum.map(carried, & &1.id) == ["e_opt"]
      assert GiftPlans.carried_entries(data, GiftPlans.find_section(data, "ms_a"), 1) == []

      env = %{plan: data, floor: 1, inventory: %{}}
      assert Enum.map(GiftPlans.working_progress(data, stage["id"], env).entries, & &1.id) == ["s_dup", "s_own", "e_opt"]
      assert Enum.map(GiftPlans.progress(data, stage["id"], env).entries, & &1.id) == ["s_dup", "s_own"]
    end

    test "normalize keeps stage_of" do
      {data, stage} = staged()
      normalized = GiftPlans.normalize(Map.put(data, "version", GiftPlans.version()))
      assert GiftPlans.find_section(normalized, stage["id"])["stage_of"] == "ms_a"
    end
  end

  describe "segment branches" do
    setup do
      {data, id} = with_gifts(["Glimpse"])
      entry_id = entry_for(data, id, "Glimpse")["id"]
      rich = %{"op" => "and", "children" => [%{"op" => "cost", "cmp" => "gte", "value" => 500}]}
      data = GiftPlans.add_branch(data, id, entry_id, 1, nil, "br_a", rich)
      data = GiftPlans.update_segment(data, id, entry_id, 1, &Map.merge(&1, %{"disposition" => "sell", "buy" => false}), nil, "br_a")
      %{data: data, id: id, entry_id: entry_id, entry: entry_for(data, id, "Glimpse")}
    end

    test "a branch copies the tab's settings and edits stay on the branch", %{entry: entry} do
      assert [%{"floors" => [segment]}] = [entry]
      assert [%{"id" => "br_a", "disposition" => "sell", "buy" => false}] = segment["branches"]
      assert %{"disposition" => "keep", "buy" => true} = segment
      refute Map.has_key?(hd(segment["branches"]), "from")
    end

    test "resolving without an environment uses the otherwise settings", %{entry: entry} do
      assert %{disposition: "keep", buy: true} = GiftPlans.resolve(entry, 1)
    end

    test "the first branch whose condition holds wins, else the tab's own settings apply", %{entry: entry} do
      assert %{disposition: "sell"} = GiftPlans.resolve(entry, 1, %{wallet: 600, owned: MapSet.new()})
      assert %{disposition: "keep", buy: true} = GiftPlans.resolve(entry, 1, %{wallet: 100, owned: MapSet.new()})
      assert %{disposition: "keep"} = GiftPlans.resolve(entry, 1, %{wallet: 600, owned: MapSet.new(), no_branches: true})
    end

    test "branches are checked in order and can be moved, removed and reordered", %{data: data, id: id, entry_id: entry_id} do
      always = %{"op" => "and", "children" => [%{"op" => "refreshes", "cmp" => "gte", "value" => 0}]}
      data = GiftPlans.add_branch(data, id, entry_id, 1, nil, "br_b", always)
      env = %{wallet: 600, owned: MapSet.new(), refreshes: 0}
      assert %{disposition: "sell"} = GiftPlans.resolve(entry_for(data, id, "Glimpse"), 1, env)

      data = GiftPlans.move_branch(data, id, entry_id, 1, nil, "br_b", -1)
      assert Enum.map(hd(entry_for(data, id, "Glimpse")["floors"])["branches"], & &1["id"]) == ["br_b", "br_a"]
      assert %{disposition: "keep"} = GiftPlans.resolve(entry_for(data, id, "Glimpse"), 1, env)

      data = data |> GiftPlans.remove_branch(id, entry_id, 1, nil, "br_b") |> GiftPlans.remove_branch(id, entry_id, 1, nil, "br_a")
      refute Map.has_key?(hd(entry_for(data, id, "Glimpse")["floors"]), "branches")
    end

    test "a goal condition does not recurse into branch resolution", %{data: data, id: id, entry_id: entry_id} do
      goal = %{"op" => "and", "children" => [%{"op" => "goal", "goal" => "required"}]}
      data = GiftPlans.set_branch_condition(data, id, entry_id, 1, nil, "br_a", goal)
      env = %{plan: data, floor: 1, inventory: %{}, owned: MapSet.new(), gifts: by_name(), gifts_by_id: by_id()}
      assert %{disposition: disposition} = GiftPlans.resolve(entry_for(data, id, "Glimpse"), 1, env)
      assert disposition in ["keep", "sell"]
    end
  end
end
