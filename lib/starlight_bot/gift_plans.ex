defmodule StarlightBot.GiftPlans do
  alias StarlightBot.Conditions
  alias StarlightBot.GiftPlans.Routes

  @version 4
  @step_kinds ~w(if milestone refresh affinity_refresh skill_replace heal heal_all revive budget workflow bail leave)
  @dispositions ~w(keep ignore sell)
  @skill_options ~w(s1_s3 s2_s3 s1_s2)
  @heal_cost 100
  @heal_actions ~w(heal revive heal_all)
  @heal_all_max 7
  @refresh_actions ~w(refresh affinity_refresh leave)
  @skill_option_costs %{"s1_s2" => 45, "s2_s3" => 75, "s1_s3" => 120}
  @skill_replace_cost 50
  @uptie_step_costs %{1 => [50, 100], 2 => [60, 120], 3 => [75, 150], 4 => [100, 200]}
  @max_uptie 2
  @default_grace_indexes [0, 2, 3, 7]
  @chance_comet 8
  @gift_search_max 3
  @gift_search_starlight_costs [70, 160, 270]
  @shop_tiers 1..4
  @gift_search_max_tier 3
  @tier_fusable_tiers 1..4
  @max_floor 15
  @mounting_trials_modes ~w(avoid_hp best_gift)
  @fragment_slot "gift_0"
  @sin_fragments [
    "Fragment of Allurement",
    "Fragment of Conceit",
    "Fragment of Decay",
    "Fragment of Desire",
    "Fragment of Friction",
    "Fragment of Hellfire",
    "Fragment of Inertia"
  ]
  @starting_gifts %{
    "bleed" => ["Wound Clerid", "Little and To-Be-Naughty Plushie", "Awe"],
    "blunt" => ["Today's Expression", "Pocket Flashcards", "Temporal Bridle"],
    "burn" => ["Hellterfly’s Dream", "Fiery Down", "Pain of Stifled Rage"],
    "charge" => ["Employee Card", "Portable Battery Socket", "Patrolling Flashlight"],
    "pierce" => ["Gathering Skulls", "Plume of Proof", "Torn Bandolier"],
    "poise" => ["Cigarette Holder", "Stone Tomb", "Old Wooden Doll"],
    "rupture" => ["Barbed Lasso", "Fluorescent Lamp", "Smoking Gunpowder"],
    "sinking" => ["Red Order", "Melted Spring", "Grandeur"],
    "slash" => ["Dreaming Electric Sheep", "Short Cane Sword", "Resolution"],
    "tremor" => ["Oscillating Bracelet", "Reverberation", "Sour Liquor Aroma"]
  }

  def starting_gifts(affinity), do: Map.get(@starting_gifts, affinity, [])

  def cabinet_order(data) do
    starting = starting_gifts(data["affinity"])
    chosen = Enum.filter(data["cabinet_gifts"] || [], &(&1 in starting))
    Enum.uniq(chosen ++ starting)
  end

  def cabinet_slots(data) do
    starting = starting_gifts(data["affinity"])

    case cabinet_order(data) do
      [] -> [0, 1, 2]
      order -> Enum.map(order, fn name -> Enum.find_index(starting, &(&1 == name)) end)
    end
  end

  def step_kinds, do: @step_kinds
  def dispositions, do: @dispositions
  def skill_options, do: @skill_options
  def heal_cost, do: @heal_cost
  def skill_replace_cost, do: @skill_replace_cost
  def max_uptie, do: @max_uptie
  def gift_search_max, do: @gift_search_max
  def sin_fragments, do: @sin_fragments

  def gift_search_starlight_cost(0), do: 0
  def gift_search_starlight_cost(count), do: Enum.at(@gift_search_starlight_costs, min(count, @gift_search_max) - 1)
  def gift_search_slot_cost(slot), do: gift_search_starlight_cost(slot + 1) - gift_search_starlight_cost(slot)
  def shop_tiers, do: @shop_tiers
  def max_floor, do: @max_floor
  def mounting_trials_modes, do: @mounting_trials_modes

  def mounting_trials_mode_label("avoid_hp"), do: "Avoid boosting enemy HP"
  def mounting_trials_mode_label("best_gift"), do: "Best gift"

  def default_mounting_trials, do: [%{"from_floor" => 1, "mode" => "avoid_hp"}]

  def mounting_trials_mode(data, floor) when is_integer(floor) do
    (data["mounting_trials"] || [])
    |> Enum.filter(&(&1["from_floor"] <= floor))
    |> Enum.max_by(& &1["from_floor"], fn -> %{"mode" => "best_gift"} end)
    |> Map.fetch!("mode")
  end

  def blank(affinity \\ nil) do
    workflow = %{"id" => new_id("wf"), "name" => "Standard", "steps" => []}

    %{
      "version" => @version,
      "affinity" => affinity,
      "cabinet_gifts" => starting_gifts(affinity),
      "grace_picks" => Enum.map(@default_grace_indexes, &%{"index" => &1, "enhance" => 0}),
      "gift_search" => [],
      "workflows" => [workflow],
      "floor_schedule" => [%{"from_floor" => 1, "workflow" => workflow["id"]}],
      "mounting_trials" => default_mounting_trials(),
      "milestones" => [new_milestone("Shop Done")]
    }
  end

  def normalize(%{"version" => @version} = data) do
    %{
      "version" => @version,
      "affinity" => data["affinity"],
      "cabinet_gifts" => data["cabinet_gifts"] || [],
      "grace_picks" => data["grace_picks"] || [],
      "gift_search" => data["gift_search"] || [],
      "workflows" => data["workflows"] || [],
      "floor_schedule" => data["floor_schedule"] || [],
      "mounting_trials" => data["mounting_trials"] || default_mounting_trials(),
      "milestones" => Enum.map(data["milestones"] || [new_milestone("Shop Done")], &normalize_milestone/1)
    }
  end

  def normalize(_data), do: blank()

  defp normalize_milestone(milestone) do
    %{"id" => milestone["id"], "name" => milestone["name"], "goals" => milestone["goals"] || [], "entries" => milestone["entries"] || [], "refresh" => milestone["refresh"] || []}
  end

  def new_id(prefix) do
    prefix <> "_" <> Base.encode32(:crypto.strong_rand_bytes(4), case: :lower, padding: false)
  end

  def new_milestone(name), do: %{"id" => new_id("ms"), "name" => name, "goals" => [], "entries" => [], "refresh" => []}

  def find_milestone(data, id), do: Enum.find(data["milestones"] || [], &(&1["id"] == id))

  def update_milestone(data, id, fun) do
    Map.update!(data, "milestones", fn milestones -> Enum.map(milestones, &if(&1["id"] == id, do: fun.(&1), else: &1)) end)
  end

  def remove_milestone(data, id), do: Map.update!(data, "milestones", fn milestones -> Enum.reject(milestones, &(&1["id"] == id)) end)

  def gift_subject(name), do: %{"gift" => name}
  def tier_subject(tiers), do: %{"tiers" => tiers |> Enum.uniq() |> Enum.sort()}
  def affinity_subject(affinity, tiers), do: %{"affinity" => affinity, "tiers" => tiers |> Enum.uniq() |> Enum.sort()}

  def subject_gift(%{"subject" => %{"gift" => name}}), do: name
  def subject_gift(_entry), do: nil

  def pattern_entry?(entry), do: is_nil(subject_gift(entry))

  def heal_actions, do: @heal_actions
  def heal_all_max, do: @heal_all_max

  def action_cost_range("revive", segment), do: twice(length(segment["sinners"] || []) * @heal_cost)
  def action_cost_range("heal", %{"repeat" => "until_full"} = segment), do: {length(segment["sinners"] || []) * @heal_cost, 2 * length(segment["sinners"] || []) * @heal_cost}
  def action_cost_range("heal", segment), do: twice(length(segment["sinners"] || []) * @heal_cost)
  def action_cost_range("heal_all", %{"repeat" => "until_full"}), do: {@heal_cost, @heal_all_max * @heal_cost}
  def action_cost_range("heal_all", segment), do: twice(heal_all_times(segment["repeat"]) * @heal_cost)

  def action_cost_range("skill_replace", segment) do
    case Enum.map(segment["options"] || [], &@skill_option_costs[&1]) do
      [] -> {0, 0}
      costs -> Enum.min_max(costs)
    end
  end

  def heal_all_times("2"), do: 2
  def heal_all_times("3"), do: 3
  def heal_all_times(_repeat), do: 1

  defp twice(cost), do: {cost, cost}
  def action_entry?(entry), do: match?(%{"subject" => %{"action" => _}}, entry)

  def subject_label(%{"gift" => name}), do: name
  def subject_label(%{"action" => "heal"}), do: "Greatly Heal"
  def subject_label(%{"action" => "revive"}), do: "Revive"
  def subject_label(%{"action" => "heal_all"}), do: "Heal Everyone"
  def subject_label(%{"action" => "skill_replace"}), do: "Skill Replace"
  def subject_label(%{"affinity" => affinity, "tiers" => []}), do: "Any #{affinity}"
  def subject_label(%{"affinity" => affinity, "tiers" => tiers}), do: "Any #{affinity} " <> Enum.map_join(tiers, ", ", &"T#{&1}")
  def subject_label(%{"tiers" => tiers}), do: "Any " <> Enum.map_join(tiers, ", ", &"T#{&1}")

  def subject_matches?(%{"gift" => name}, gift), do: gift.name == name
  def subject_matches?(%{"action" => _}, _gift), do: false
  def subject_matches?(%{"affinity" => affinity, "tiers" => tiers}, gift), do: Map.get(gift, :affinity) == affinity and (tiers == [] or Map.get(gift, :tier) in tiers)
  def subject_matches?(%{"tiers" => tiers}, gift), do: Map.get(gift, :tier) in tiers

  defp specificity(%{"gift" => _}), do: 3
  defp specificity(%{"affinity" => _, "tiers" => [_ | _]}), do: 2
  defp specificity(%{"affinity" => _}), do: 1
  defp specificity(_subject), do: 0

  def default_segment do
    %{"from" => 1, "disposition" => "keep", "goal" => "required", "buy" => true, "fuse" => false, "uptie" => 0, "max" => nil}
  end

  def segment_at(entry, floor) do
    entry["floors"]
    |> Enum.filter(&(&1["from"] <= floor))
    |> Enum.max_by(& &1["from"], fn -> hd(entry["floors"]) end)
  end

  def abandoned?(entry, segment), do: segment["abandoned"] == true or (not pattern_entry?(entry) and segment["disposition"] == "ignore")

  def resolve(entry, floor) do
    segment = segment_at(entry, floor)
    abandoned? = abandoned?(entry, segment)

    disposition =
      cond do
        abandoned? -> "ignore"
        pattern_entry?(entry) and segment["disposition"] == "keep" -> "ignore"
        true -> segment["disposition"]
      end

    keep? = disposition == "keep"
    buy? = not abandoned? and disposition != "sell" and segment["buy"] == true

    %{
      id: entry["id"],
      subject: entry["subject"],
      gift: subject_gift(entry),
      fusion: entry["fusion"],
      disposition: disposition,
      goal: if(keep?, do: segment["goal"] || "required"),
      buy: buy?,
      fuse: keep? and segment["fuse"] == true and not is_nil(entry["fusion"]),
      uptie: if(keep?, do: segment["uptie"] || 0, else: 0),
      max: if(disposition == "sell" or (buy? and pattern_entry?(entry)), do: segment["max"]),
      abandoned: abandoned?,
      sinners: segment["sinners"] || [],
      repeat: segment["repeat"] || "once",
      options: segment["options"] || []
    }
  end

  def resolved_entries(nil, _floor), do: []
  def resolved_entries(milestone, floor), do: Enum.map(milestone["entries"] || [], &resolve(&1, floor))

  def keep_set(data, floor) do
    for milestone <- data["milestones"] || [], entry <- resolved_entries(milestone, floor), entry.disposition == "keep", entry.gift, into: MapSet.new(), do: entry.gift
  end

  def protected?(keep, gift), do: MapSet.member?(keep, gift.name)

  def sell_entries(entries), do: Enum.filter(entries, &(&1.disposition == "sell"))

  def ruling_entry(entries, gift) do
    entries
    |> Enum.filter(&subject_matches?(&1.subject, gift))
    |> Enum.max_by(&specificity(&1.subject), fn -> nil end)
  end

  def fixed_fusion?(%{fusion: %{"type" => "fixed"}}), do: true
  def fixed_fusion?(%{"fusion" => %{"type" => "fixed"}}), do: true
  def fixed_fusion?(_entry), do: false

  def tiered_fusion?(%{fusion: %{"type" => "tiered"}}), do: true
  def tiered_fusion?(%{"fusion" => %{"type" => "tiered"}}), do: true
  def tiered_fusion?(_entry), do: false

  def ingredient_ids(%{ingredients: ingredients}) when is_binary(ingredients) and ingredients != "" do
    ingredients |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

  def ingredient_ids(_gift), do: []

  def fixed_recipe?(gift), do: ingredient_ids(gift) != []
  def recipe_ids(gift), do: gift |> ingredient_ids() |> Enum.reject(&(&1 == @fragment_slot))
  def fragment_slots(gift), do: gift |> ingredient_ids() |> Enum.count(&(&1 == @fragment_slot))
  def recipe_names(gift, by_id), do: for(id <- recipe_ids(gift), by_id[id], do: by_id[id].name)

  def tier_fusable?(gift) do
    not fixed_recipe?(gift) and gift.tier in @tier_fusable_tiers and String.contains?(Map.get(gift, :obtain_method) || "", "Shop")
  end

  def fusable?(gift), do: fixed_recipe?(gift) or tier_fusable?(gift)

  def covered_names(gift, by_id, by_name) do
    direct = recipe_names(gift, by_id)
    fragments = if fragment_slots(gift) > 0, do: @sin_fragments, else: []

    Enum.reduce(direct, MapSet.new(direct ++ fragments), fn name, acc ->
      case by_name[name] do
        nil -> acc
        ingredient -> MapSet.union(acc, covered_names(ingredient, by_id, by_name))
      end
    end)
  end

  def new_gift_entry(gift, role, routes_for) do
    fusion = default_fusion(gift, routes_for)
    fuse = fusion != nil and ((gift.tier || 0) >= 4 or (role == :ingredient and fixed_recipe?(gift)))
    goal = if role == :ingredient, do: "optional", else: "required"
    %{"id" => new_id("me"), "subject" => gift_subject(gift.name), "fusion" => fusion, "floors" => [%{default_segment() | "goal" => goal, "fuse" => fuse}]}
  end

  def default_fusion(gift, routes_for) do
    cond do
      fixed_recipe?(gift) -> %{"type" => "fixed"}
      tier_fusable?(gift) -> %{"type" => "tiered", "routes" => routes_for.(gift.tier)}
      true -> nil
    end
  end

  def has_gift?(milestone, name), do: Enum.any?(milestone["entries"] || [], &(subject_gift(&1) == name))

  def add_gift(data, id, name, gifts_by_name, routes_for) do
    by_id = Map.new(gifts_by_name, fn {_name, gift} -> {gift.id, gift} end)
    update_milestone(data, id, &add_gift_entry(&1, name, :top, gifts_by_name, by_id, routes_for))
  end

  defp add_gift_entry(milestone, name, role, by_name, by_id, routes_for) do
    gift = by_name[name]

    if is_nil(gift) or has_gift?(milestone, name) do
      milestone
    else
      milestone = Map.update(milestone, "entries", [], &(&1 ++ [new_gift_entry(gift, role, routes_for)]))
      Enum.reduce(recipe_names(gift, by_id), milestone, &add_gift_entry(&2, &1, :ingredient, by_name, by_id, routes_for))
    end
  end

  def add_pattern(data, id, subject) do
    update_milestone(data, id, fn milestone ->
      if Enum.any?(milestone["entries"] || [], &(&1["subject"] == subject)) do
        milestone
      else
        entry = %{"id" => new_id("me"), "subject" => subject, "fusion" => nil, "floors" => [%{default_segment() | "disposition" => "ignore", "goal" => nil}]}
        Map.update(milestone, "entries", [], &(&1 ++ [entry]))
      end
    end)
  end

  def add_action(data, id, action, sinner) when action in ["skill_replace" | @heal_actions] do
    segment = Map.merge(default_segment(), %{"disposition" => "ignore", "goal" => nil, "buy" => false, "sinners" => List.wrap(sinner), "repeat" => "once"})
    segment = if action == "skill_replace", do: Map.put(segment, "options", @skill_options), else: segment
    entry = %{"id" => new_id("me"), "subject" => %{"action" => action}, "fusion" => nil, "floors" => [segment]}
    update_milestone(data, id, fn milestone -> Map.update(milestone, "entries", [], &(&1 ++ [entry])) end)
  end

  def heal_entries(entries), do: Enum.filter(entries, &(match?(%{subject: %{"action" => action}} when action in @heal_actions, &1) and not &1.abandoned))
  def skill_replace_entries(entries), do: Enum.filter(entries, &(match?(%{subject: %{"action" => "skill_replace"}}, &1) and not &1.abandoned))

  def refresh_actions, do: @refresh_actions

  def refresh_action_label("refresh"), do: "Refresh"
  def refresh_action_label("affinity_refresh"), do: "Keyword Refresh"
  def refresh_action_label("leave"), do: "Leave Shop"

  def add_refresh_case(data, id) do
    refresh_case = %{"id" => new_id("rc"), "condition" => nil, "action" => "refresh", "affinity" => nil}
    update_milestone(data, id, fn milestone -> Map.update(milestone, "refresh", [refresh_case], &(&1 ++ [refresh_case])) end)
  end

  def update_refresh_case(data, id, case_id, fun) do
    update_milestone(data, id, fn milestone ->
      Map.update(milestone, "refresh", [], fn cases -> Enum.map(cases, &if(&1["id"] == case_id, do: fun.(&1), else: &1)) end)
    end)
  end

  def remove_refresh_case(data, id, case_id) do
    update_milestone(data, id, fn milestone -> Map.update(milestone, "refresh", [], &Enum.reject(&1, fn refresh_case -> refresh_case["id"] == case_id end)) end)
  end

  def reorder_refresh_cases(data, id, ids) do
    update_milestone(data, id, fn milestone -> Map.update(milestone, "refresh", [], &reorder_by_keys(&1, ids, fn refresh_case -> refresh_case["id"] end)) end)
  end

  def matching_refresh_case(milestone, env), do: Enum.find(milestone["refresh"] || [], &eval_condition(&1["condition"], env))

  def find_entry(milestone, entry_id), do: Enum.find(milestone["entries"] || [], &(&1["id"] == entry_id))

  def update_entry(data, id, entry_id, fun) do
    update_milestone(data, id, fn milestone ->
      Map.update(milestone, "entries", [], fn entries -> Enum.map(entries, &if(&1["id"] == entry_id, do: fun.(&1), else: &1)) end)
    end)
  end

  def update_segment(data, id, entry_id, from, fun) do
    update_entry(data, id, entry_id, fn entry ->
      Map.update!(entry, "floors", fn floors -> Enum.map(floors, &if(&1["from"] == from, do: fun.(&1), else: &1)) end)
    end)
  end

  def remove_entry(data, id, entry_id) do
    update_milestone(data, id, fn milestone -> Map.update(milestone, "entries", [], &Enum.reject(&1, fn entry -> entry["id"] == entry_id end)) end)
  end

  def reorder_entries(data, id, ids) do
    update_milestone(data, id, fn milestone ->
      Map.update(milestone, "entries", [], fn entries -> reorder_by_keys(entries, expand_entry_ids(entries, ids), & &1["id"]) end)
    end)
  end

  def group_key(entry), do: entry["group"] || entry["id"]

  def group_members(milestone, entry_id) do
    case find_entry(milestone, entry_id) do
      nil -> []
      entry -> Enum.filter(milestone["entries"] || [], &(group_key(&1) == group_key(entry)))
    end
  end

  defp expand_entry_ids(entries, ids) do
    ids
    |> Enum.flat_map(fn
      "group:" <> key -> for entry <- entries, group_key(entry) == key, do: entry["id"]
      id -> [id]
    end)
    |> Enum.uniq()
  end

  def reorder_group(data, id, key, ids) do
    update_milestone(data, id, fn milestone ->
      Map.update(milestone, "entries", [], fn entries ->
        members = Enum.filter(entries, &(group_key(&1) == key))
        place_block(entries, &(group_key(&1) == key), reorder_by_keys(members, ids, & &1["id"]))
      end)
    end)
  end

  def join_group(data, id, entry_id, key, ids) do
    update_milestone(data, id, fn milestone ->
      entries = milestone["entries"] || []
      template = Enum.find(entries, &(group_key(&1) == key and &1["id"] != entry_id))
      moving = Enum.find(entries, &(&1["id"] == entry_id))

      if is_nil(template) or is_nil(moving) do
        milestone
      else
        group = template["group"] || new_id("grp")
        joined = moving |> adopt_schedule(template) |> Map.merge(%{"group" => group, "scheduled" => true})
        rest = entries |> Enum.reject(&(&1["id"] == entry_id)) |> Enum.map(&if(group_key(&1) == key, do: Map.put(&1, "group", group), else: &1))
        member? = &(&1["group"] == group)
        members = Enum.filter(rest, member?) ++ [joined]
        Map.put(milestone, "entries", place_block(rest, member?, reorder_by_keys(members, ids, & &1["id"])))
      end
    end)
  end

  def leave_group(data, id, entry_id, ids) do
    data
    |> update_entry(id, entry_id, &Map.delete(&1, "group"))
    |> reorder_entries(id, ids)
  end

  defp adopt_schedule(entry, template) do
    floors =
      for tab <- template["floors"] do
        segment = segment_at(entry, tab["from"])
        segment = if not pattern_entry?(entry) and segment["disposition"] == "ignore", do: Map.put(segment, "disposition", "keep"), else: segment
        Map.merge(segment, %{"from" => tab["from"], "abandoned" => abandoned?(template, tab)})
      end

    Map.put(entry, "floors", floors)
  end

  defp place_block(entries, member?, block) do
    case Enum.find_index(entries, member?) do
      nil ->
        entries ++ block

      index ->
        {before, after_block} = entries |> Enum.reject(member?) |> Enum.split(index)
        before ++ block ++ after_block
    end
  end

  def split_entry(data, id, entry_id, floor) when floor in 2..@max_floor do
    update_entry(data, id, entry_id, fn entry ->
      if Enum.any?(entry["floors"], &(&1["from"] == floor)) do
        entry
      else
        segment = %{segment_at(entry, floor) | "from" => floor}
        Map.put(entry, "floors", Enum.sort_by(entry["floors"] ++ [segment], & &1["from"]))
      end
    end)
  end

  def split_entry(data, _id, _entry_id, _floor), do: data

  def move_segment(data, id, entry_id, from, to) when from != 1 and to in 2..@max_floor do
    update_entry(data, id, entry_id, fn entry ->
      if Enum.any?(entry["floors"], &(&1["from"] == to)) do
        entry
      else
        floors = Enum.map(entry["floors"], &if(&1["from"] == from, do: %{&1 | "from" => to}, else: &1))
        Map.put(entry, "floors", Enum.sort_by(floors, & &1["from"]))
      end
    end)
  end

  def move_segment(data, _id, _entry_id, _from, _to), do: data

  def remove_segment(data, _id, _entry_id, 1), do: data

  def remove_segment(data, id, entry_id, from) do
    update_entry(data, id, entry_id, fn entry -> Map.update!(entry, "floors", &Enum.reject(&1, fn segment -> segment["from"] == from end)) end)
  end

  def goal_letters(milestone), do: Enum.map(milestone["goals"] || [], & &1["letter"])

  def add_goal(data, id) do
    update_milestone(data, id, fn milestone ->
      used = goal_letters(milestone)

      case Enum.find(Enum.map(?A..?Z, &<<&1>>), &(&1 not in used)) do
        nil -> milestone
        letter -> Map.update(milestone, "goals", [], &(&1 ++ [%{"letter" => letter, "min" => 1}]))
      end
    end)
  end

  def set_goal_min(data, id, letter, min) do
    update_milestone(data, id, fn milestone ->
      Map.update(milestone, "goals", [], fn goals -> Enum.map(goals, &if(&1["letter"] == letter, do: Map.put(&1, "min", max(min, 1)), else: &1)) end)
    end)
  end

  def remove_goal(data, id, letter) do
    update_milestone(data, id, fn milestone ->
      entries =
        Enum.map(milestone["entries"] || [], fn entry ->
          Map.update!(entry, "floors", fn floors -> Enum.map(floors, &if(&1["goal"] == letter, do: Map.put(&1, "goal", "required"), else: &1)) end)
        end)

      %{milestone | "goals" => Enum.reject(milestone["goals"] || [], &(&1["letter"] == letter)), "entries" => entries}
    end)
  end

  def goal_min(milestone, letter) do
    case Enum.find(milestone["goals"] || [], &(&1["letter"] == letter)) do
      %{"min" => min} when is_integer(min) -> min
      _ -> 1
    end
  end

  def progress(data, id, env) do
    milestone = find_milestone(data, id)
    entries = resolved_entries(milestone, env_floor(env))
    covered = covered(entries, env)
    statuses = Map.new(entries, &{&1.id, entry_status(&1, env, covered)})
    %{milestone: milestone, entries: entries, statuses: statuses, pending: pending_ingredients(entries, env)}
  end

  defp env_floor(env), do: Map.get(env, :floor) || 1

  def covered(entries, env) do
    by_name = Map.get(env, :gifts, %{})
    by_id = env_by_id(env)

    entries
    |> Enum.filter(&(&1.fuse and fixed_fusion?(&1) and owns?(env, &1.gift)))
    |> Enum.reduce(MapSet.new(), fn entry, acc ->
      case by_name[entry.gift] do
        nil -> acc
        gift -> MapSet.union(acc, covered_names(gift, by_id, by_name))
      end
    end)
  end

  def pending_ingredients(entries, env) do
    by_name = Map.get(env, :gifts, %{})
    by_id = env_by_id(env)

    entries
    |> Enum.filter(&(&1.fuse and fixed_fusion?(&1) and not owns?(env, &1.gift)))
    |> Enum.reduce(MapSet.new(), fn entry, acc ->
      case by_name[entry.gift] do
        nil -> acc
        gift -> MapSet.union(acc, covered_names(gift, by_id, by_name))
      end
    end)
  end

  defp env_by_id(env), do: Map.get_lazy(env, :gifts_by_id, fn -> Map.new(Map.get(env, :gifts, %{}), fn {_name, gift} -> {gift.id, gift} end) end)

  defp owns?(env, name), do: Enum.any?(Map.get(env, :inventory, %{}), fn {_id, entry} -> entry.name == name end)

  def entry_status(%{gift: nil}, _env, _covered), do: :none

  def entry_status(entry, env, covered) do
    inventory = Map.get(env, :inventory, %{})
    owned = Enum.find_value(inventory, fn {_id, owned} -> if owned.name == entry.gift, do: owned end)

    cond do
      MapSet.member?(covered, entry.gift) -> :done
      owned -> if (owned.uptie || 0) >= entry.uptie, do: :done, else: :partial
      entry.fuse and fixed_fusion?(entry) and recipe_started?(entry, env) -> :partial
      true -> :open
    end
  end

  defp recipe_started?(entry, env) do
    case Map.get(env, :gifts, %{})[entry.gift] do
      nil -> false
      gift -> Enum.any?(recipe_ids(gift), &Map.has_key?(Map.get(env, :inventory, %{}), &1))
    end
  end

  def status(progress, entry), do: progress.statuses[entry.id]

  def goal_entries(progress), do: Enum.filter(progress.entries, &(&1.disposition == "keep" and is_binary(&1.gift)))

  def goal_members(progress, letter), do: Enum.filter(goal_entries(progress), &(&1.goal == letter))

  def goal_need(progress, letter), do: min(goal_min(progress.milestone, letter), length(goal_members(progress, letter)))

  def goal_committed(progress, letter), do: progress |> goal_members(letter) |> Enum.count(&(status(progress, &1) != :open))

  def goal_done(progress, letter), do: progress |> goal_members(letter) |> Enum.count(&(status(progress, &1) == :done))

  def reached?(%{milestone: nil}), do: false

  def reached?(progress) do
    entries = goal_entries(progress)
    letters = entries |> Enum.map(& &1.goal) |> Enum.reject(&(&1 in ["required", "optional"])) |> Enum.uniq()

    Enum.all?(entries, &(&1.goal != "required" or status(progress, &1) == :done)) and
      Enum.all?(letters, fn letter ->
        statuses = progress |> goal_members(letter) |> Enum.map(&status(progress, &1))
        :partial not in statuses and goal_done(progress, letter) >= goal_need(progress, letter)
      end)
  end

  def needed?(progress, %{disposition: "keep", gift: gift} = entry) when is_binary(gift) do
    case status(progress, entry) do
      :done -> false
      :partial -> entry.goal != "optional"
      :open ->
        case entry.goal do
          "required" -> true
          "optional" -> false
          letter -> goal_committed(progress, letter) < goal_need(progress, letter)
        end
    end
  end

  def needed?(_progress, _entry), do: false

  def milestone_reached?(data, id, env), do: data |> progress(id, env) |> reached?()

  def new_step(kind, data) when kind in @step_kinds do
    %{"id" => new_id("st"), "kind" => kind, "enabled" => true, "condition" => nil}
    |> Map.merge(step_defaults(kind, data))
  end

  defp step_defaults("if", _data), do: %{"condition" => Conditions.add(nil, "", %{"op" => "cost_gte", "value" => 0}), "then" => [], "else" => []}

  defp step_defaults("milestone", data) do
    case data["milestones"] do
      [%{"id" => id} | _] -> %{"milestone" => id}
      _ -> %{"milestone" => nil}
    end
  end

  defp step_defaults("affinity_refresh", data), do: %{"affinity" => data["affinity"]}
  defp step_defaults("skill_replace", _data), do: %{"sinner" => nil, "options" => @skill_options}
  defp step_defaults(kind, _data) when kind in ["heal", "revive"], do: %{"sinner" => nil}
  defp step_defaults("budget", _data), do: %{"amount" => 0}
  defp step_defaults("workflow", _data), do: %{"workflow" => nil}
  defp step_defaults(_kind, _data), do: %{}

  def find_workflow(data, id), do: Enum.find(data["workflows"], &(&1["id"] == id))

  def definition_for(data, %{"kind" => "workflow"} = step) do
    case find_workflow(data, step["workflow"]) do
      nil -> {:error, :missing_definition}
      workflow -> {:ok, workflow}
    end
  end

  def definition_for(data, %{"kind" => "milestone"} = step) do
    case find_milestone(data, step["milestone"]) do
      nil -> {:error, :missing_definition}
      milestone -> {:ok, milestone}
    end
  end

  def definition_for(_data, _step), do: {:ok, nil}

  def called_workflows(workflow) do
    steps = all_steps(workflow["steps"])
    runs = for %{"kind" => "workflow", "workflow" => id} <- steps, is_binary(id), do: id
    betweens = for %{"between" => id} <- steps, is_binary(id), do: id
    Enum.uniq(runs ++ betweens)
  end

  def all_steps(steps), do: Enum.flat_map(steps || [], fn step -> [step | Enum.flat_map(branches(step), &all_steps(step[&1]))] end)

  def branches(%{"kind" => "if"}), do: ["then", "else"]
  def branches(_step), do: []

  def find_step(steps, id), do: Enum.find(all_steps(steps), &(&1["id"] == id))

  def update_step_in(steps, id, fun) do
    Enum.map(steps, fn
      %{"id" => ^id} = step -> fun.(step)
      step -> update_branches(step, &update_step_in(&1, id, fun))
    end)
  end

  def remove_step(steps, id), do: steps |> Enum.reject(&(&1["id"] == id)) |> Enum.map(&update_branches(&1, fn list -> remove_step(list, id) end))

  def update_step_list(steps, "", fun), do: fun.(steps)

  def update_step_list(steps, scope, fun) do
    [id, branch] = String.split(scope, ":")
    update_step_in(steps, id, &Map.put(&1, branch, fun.(&1[branch] || [])))
  end

  def update_containing_list(steps, id, fun) do
    if Enum.any?(steps, &(&1["id"] == id)),
      do: fun.(steps),
      else: Enum.map(steps, &update_branches(&1, fn list -> update_containing_list(list, id, fun) end))
  end

  def move_step(steps, id, scope, ids) do
    step = find_step(steps, id)
    host = if scope == "", do: nil, else: scope |> String.split(":") |> hd()

    if is_nil(step) or (host && (host == id or find_step(Enum.flat_map(branches(step), &(step[&1] || [])), host))) do
      steps
    else
      steps |> remove_step(id) |> update_step_list(scope, &reorder_by_keys(&1 ++ [step], ids, fn s -> s["id"] end))
    end
  end

  def fresh_step_ids(step), do: step |> Map.put("id", new_id("st")) |> update_branches(&Enum.map(&1, fn child -> fresh_step_ids(child) end))

  defp update_branches(step, fun), do: Enum.reduce(branches(step), step, fn branch, step -> Map.put(step, branch, fun.(step[branch] || [])) end)

  defp reorder_by_keys(items, keys, key_fun) do
    by_key = Map.new(items, &{key_fun.(&1), &1})
    ordered = keys |> Enum.map(&by_key[&1]) |> Enum.reject(&is_nil/1)
    ordered ++ Enum.reject(items, &(&1 in ordered))
  end

  def reachable_workflows(data, id), do: reach(data, called_workflows(find_workflow(data, id) || %{}), MapSet.new())

  defp reach(_data, [], seen), do: seen

  defp reach(data, [id | rest], seen) do
    if MapSet.member?(seen, id) do
      reach(data, rest, seen)
    else
      next = called_workflows(find_workflow(data, id) || %{})
      reach(data, next ++ rest, MapSet.put(seen, id))
    end
  end

  def creates_cycle?(data, host_id, child_id), do: child_id == host_id or MapSet.member?(reachable_workflows(data, child_id), host_id)

  def callers(data, id), do: Enum.filter(data["workflows"], &(id in called_workflows(&1)))

  def import_workflows(data, source, workflow_ids, source_name) do
    ids = Enum.uniq(Enum.flat_map(workflow_ids, &[&1 | MapSet.to_list(reachable_workflows(source, &1))]))
    workflows = Enum.filter(source["workflows"], &(&1["id"] in ids))
    wf_map = Map.new(workflows, &{&1["id"], new_id("wf")})
    taken = MapSet.new(data["workflows"], & &1["name"])

    imported =
      Enum.map(workflows, fn workflow ->
        name = if MapSet.member?(taken, workflow["name"]), do: "#{workflow["name"]} (#{source_name})", else: workflow["name"]
        %{workflow | "id" => wf_map[workflow["id"]], "name" => name, "steps" => Enum.map(workflow["steps"], &remap_tree(&1, wf_map))}
      end)

    Map.update!(data, "workflows", &(&1 ++ imported))
  end

  defp remap_step(%{"kind" => "workflow"} = step, wf_map), do: %{step | "id" => new_id("st"), "workflow" => wf_map[step["workflow"]]}
  defp remap_step(step, _wf_map), do: Map.put(step, "id", new_id("st"))

  defp remap_tree(step, wf_map) do
    step
    |> remap_step(wf_map)
    |> remap_between(wf_map)
    |> update_branches(&Enum.map(&1, fn child -> remap_tree(child, wf_map) end))
  end

  defp remap_between(%{"between" => id} = step, wf_map) when is_binary(id), do: %{step | "between" => wf_map[id]}
  defp remap_between(step, _wf_map), do: step

  def expand_steps(data, workflow), do: expand_steps(data, workflow, [workflow["id"]])

  defp expand_steps(data, workflow, stack), do: expand_list(data, workflow["steps"], stack)

  defp expand_list(data, steps, stack) do
    steps
    |> Enum.filter(&(&1["enabled"] != false))
    |> Enum.flat_map(fn
      %{"kind" => "workflow", "workflow" => id} = step ->
        case find_workflow(data, id) do
          %{} = sub -> if id in stack, do: [], else: expand_steps(data, sub, [id | stack])
          nil -> [step]
        end

      %{"kind" => "if"} = step ->
        [step | Enum.flat_map(branches(step), &expand_list(data, step[&1] || [], stack))]

      step ->
        [step | expand_between(data, step, stack)]
    end)
  end

  defp expand_between(data, %{"between" => id}, stack) when is_binary(id) do
    case find_workflow(data, id) do
      %{} = between -> if id in stack, do: [], else: expand_steps(data, between, [id | stack])
      nil -> []
    end
  end

  defp expand_between(_data, _step, _stack), do: []

  def workflow_for_floor(data, floor) when is_integer(floor) do
    data["floor_schedule"]
    |> Enum.filter(&(&1["from_floor"] <= floor))
    |> Enum.max_by(& &1["from_floor"], fn -> nil end)
    |> case do
      nil -> nil
      %{"workflow" => id} -> find_workflow(data, id)
    end
  end

  def uptie_cost(tier, from, to) do
    case Map.get(@uptie_step_costs, tier) do
      nil -> nil
      steps -> steps |> Enum.slice(from, to - from) |> Enum.sum()
    end
  end

  def fodder(owned, keep, gifts_by_id) do
    for {id, %{uptie: uptie, count: count}} <- owned,
        gift = gifts_by_id[id],
        gift && gift.tier in 1..4 && (uptie || 0) < 1 && not protected?(keep, gift),
        _copy <- 1..count//1 do
      %{id: id, name: gift.name, tier: gift.tier, affinity: Map.get(gift, :affinity), uptie: uptie, selling_cost: gift.selling_cost || 0}
    end
  end

  def chance_comet?(data), do: Enum.any?(data["grace_picks"] || [], &match?(%{"index" => @chance_comet}, &1))

  def uptie_plan(definitions, owned, gifts_by_name, cost, max_gifts) do
    owned_by_name = Map.new(owned, fn {_id, entry} -> {entry.name, entry} end)
    walk_upties(definitions, owned_by_name, gifts_by_name, cost || 0, max_gifts, [])
  end

  defp walk_upties(_definitions, _owned, _gifts, _cost, max, planned) when length(planned) >= max,
    do: {Enum.reverse(planned), "reached max gifts"}

  defp walk_upties([], _owned, _gifts, _cost, _max, planned), do: {Enum.reverse(planned), "end of list"}

  defp walk_upties([definition | rest], owned, gifts, cost, max, planned) do
    entry = owned[definition["gift"]]
    gift = gifts[definition["gift"]]
    target = definition["target_level"]
    price = gift && entry && uptie_cost(gift.tier, entry.uptie, target)

    cond do
      is_nil(entry) or is_nil(gift) or entry.uptie >= target or is_nil(price) ->
        walk_upties(rest, owned, gifts, cost, max, planned)

      price > cost ->
        step_to = entry.uptie + 1
        step_price = uptie_cost(gift.tier, entry.uptie, step_to)

        if step_to < target and step_price <= cost do
          item = %{gift: gift, from: entry.uptie, to: step_to, price: step_price}
          {Enum.reverse([item | planned]), "can't afford #{gift.name} +#{target} (#{price}, have #{cost}), going to +#{step_to}"}
        else
          {Enum.reverse(planned), "can't afford #{gift.name} +#{target} (#{price}, have #{cost})"}
        end

      true ->
        item = %{gift: gift, from: entry.uptie, to: target, price: price}
        walk_upties(rest, owned, gifts, cost - price, max, [item | planned])
    end
  end

  def gift_searchable?(%{tier: tier}) when is_integer(tier), do: tier <= @gift_search_max_tier
  def gift_searchable?(_gift), do: false

  def gift_search_tab(%{affinity: affinity}) when affinity in [nil, "none"], do: "keywordless"
  def gift_search_tab(%{affinity: affinity}), do: affinity

  def gift_search_tabs(names, gifts_by_name) do
    gifts =
      names
      |> Enum.map(&gifts_by_name[&1])
      |> Enum.filter(&gift_searchable?/1)
      |> Enum.take(@gift_search_max)

    gifts
    |> Enum.map(&gift_search_tab/1)
    |> Enum.uniq()
    |> Enum.map(fn tab -> {tab, Enum.filter(gifts, &(gift_search_tab(&1) == tab))} end)
  end

  def eval_condition(tree, env), do: Conditions.eval(tree, &eval_leaf(&1, env))

  defp eval_leaf(%{"op" => "cost_gte", "value" => value}, %{wallet: wallet}), do: is_integer(wallet) and wallet >= value
  defp eval_leaf(%{"op" => "cost_lt", "value" => value}, %{wallet: wallet}), do: is_integer(wallet) and wallet < value
  defp eval_leaf(%{"op" => "refreshes_lt", "value" => value}, env), do: Map.get(env, :refreshes, 0) < value
  defp eval_leaf(%{"op" => "refreshes_gte", "value" => value}, env), do: Map.get(env, :refreshes, 0) >= value
  defp eval_leaf(%{"op" => "has_gift", "gift" => gift}, %{owned: owned}), do: MapSet.member?(owned, gift)
  defp eval_leaf(%{"op" => "missing_gift", "gift" => gift}, %{owned: owned}), do: not MapSet.member?(owned, gift)
  defp eval_leaf(%{"op" => "milestone"} = leaf, %{plan: plan} = env), do: milestone_reached?(plan, leaf["milestone"], env)
  defp eval_leaf(%{"op" => "milestone_not"} = leaf, %{plan: plan} = env), do: not milestone_reached?(plan, leaf["milestone"], env)

  def prune_condition(node), do: Conditions.prune(node)

  def condition_label(node, data \\ nil), do: Conditions.label(node, &leaf_label(&1, data))

  defp leaf_label(%{"op" => "cost_gte", "value" => value}, _data), do: "cost >= #{value}"
  defp leaf_label(%{"op" => "cost_lt", "value" => value}, _data), do: "cost < #{value}"
  defp leaf_label(%{"op" => "refreshes_lt", "value" => value}, _data), do: "refreshes < #{value}"
  defp leaf_label(%{"op" => "refreshes_gte", "value" => value}, _data), do: "refreshes >= #{value}"
  defp leaf_label(%{"op" => "has_gift", "gift" => gift}, _data), do: "owns #{gift}"
  defp leaf_label(%{"op" => "missing_gift", "gift" => gift}, _data), do: "missing #{gift}"
  defp leaf_label(%{"op" => "milestone"} = leaf, data), do: "milestone #{milestone_name(data, leaf["milestone"])} reached"
  defp leaf_label(%{"op" => "milestone_not"} = leaf, data), do: "milestone #{milestone_name(data, leaf["milestone"])} not reached"

  defp milestone_name(_data, nil), do: "(none picked)"
  defp milestone_name(nil, id), do: id

  defp milestone_name(data, id) do
    case find_milestone(data, id) do
      nil -> "(deleted)"
      milestone -> milestone["name"]
    end
  end

  def kind_label("if"), do: "If"
  def kind_label("milestone"), do: "Work on Milestone"
  def kind_label("refresh"), do: "Refresh"
  def kind_label("affinity_refresh"), do: "Affinity Refresh"
  def kind_label("skill_replace"), do: "Skill Replace"
  def kind_label("heal"), do: "Heal Sinner"
  def kind_label("heal_all"), do: "Heal All"
  def kind_label("revive"), do: "Revive"
  def kind_label("budget"), do: "Budget"
  def kind_label("workflow"), do: "Run Workflow"
  def kind_label("bail"), do: "Exit Workflow"
  def kind_label("leave"), do: "Leave Shop"

  def step_label(data, %{"kind" => kind} = step) do
    case step_subject(data, step) do
      nil -> kind_label(kind)
      subject -> "#{kind_label(kind)} · #{subject}"
    end
  end

  defp step_subject(data, %{"kind" => "workflow"} = step) do
    case definition_for(data, step) do
      {:ok, workflow} -> workflow["name"]
      _ -> if step["workflow"], do: "(missing workflow)", else: "(no workflow)"
    end
  end

  defp step_subject(data, %{"kind" => "milestone"} = step) do
    case definition_for(data, step) do
      {:ok, milestone} -> milestone["name"]
      _ -> if step["milestone"], do: "(missing milestone)", else: "(no milestone)"
    end
  end

  defp step_subject(_data, %{"kind" => "affinity_refresh"} = step), do: step["affinity"] || "(no affinity)"
  defp step_subject(_data, %{"kind" => "skill_replace"} = step), do: step["sinner"] || "(no sinner)"
  defp step_subject(_data, %{"kind" => kind} = step) when kind in ["heal", "revive"], do: step["sinner"] || "(no sinner)"
  defp step_subject(_data, %{"kind" => "budget", "amount" => amount}) when amount >= 0, do: "+#{amount}"
  defp step_subject(_data, %{"kind" => "budget", "amount" => amount}), do: "#{amount}"
  defp step_subject(_data, _step), do: nil

  def missing_ingredients(milestone, entry, gifts_by_name) do
    by_id = Map.new(gifts_by_name, fn {_name, gift} -> {gift.id, gift} end)

    case gifts_by_name[subject_gift(entry)] do
      nil ->
        {[], 0}

      gift ->
        names = Enum.reject(recipe_names(gift, by_id), &has_gift?(milestone, &1))
        fragments = Enum.count(milestone["entries"] || [], &(subject_gift(&1) in @sin_fragments))
        {names, max(fragment_slots(gift) - fragments, 0)}
    end
  end

  def issues(data, gifts_by_name \\ %{}) do
    (schedule_issues(data) ++
       gift_search_issues(data, gifts_by_name) ++
       Enum.flat_map(data["workflows"], &workflow_issues(data, &1)) ++
       Enum.flat_map(data["milestones"] || [], &milestone_issues(&1, gifts_by_name)) ++
       keep_sell_issues(data))
    |> Enum.uniq()
  end

  defp milestone_issues(milestone, gifts_by_name) do
    by_id = Map.new(gifts_by_name, fn {_name, gift} -> {gift.id, gift} end)
    prefix = "Milestone #{milestone["name"]}"
    floors = segment_floors(milestone)

    Enum.flat_map(floors, fn floor ->
      entries = resolved_entries(milestone, floor)
      fixed = Enum.filter(entries, &(&1.fuse and fixed_fusion?(&1)))
      at = if length(floors) > 1, do: " (F#{floor}+)", else: ""

      missing =
        Enum.flat_map(fixed, fn entry ->
          case missing_ingredients(milestone, %{"subject" => entry.subject}, gifts_by_name) do
            {[], 0} -> []
            {names, fragments} -> ["#{prefix}: #{entry.gift} needs #{missing_label(names, fragments)} in the milestone."]
          end
        end)

      closures = for entry <- fixed, gift = gifts_by_name[entry.gift], do: {entry.gift, covered_names(gift, by_id, gifts_by_name)}

      upties =
        for entry <- entries, entry.uptie > 0, {parent, names} <- closures, MapSet.member?(names, entry.gift) do
          "#{prefix}#{at}: #{entry.gift} is upgraded to +#{entry.uptie} but gets fused into #{parent}."
        end

      shared =
        for [{a, _}, {b, _}] <- pairs(closures),
            gift_a = gifts_by_name[a],
            gift_b = gifts_by_name[b],
            name <- recipe_names(gift_a, by_id),
            name in recipe_names(gift_b, by_id) do
          "#{prefix}#{at}: #{a} and #{b} both use #{name}; fusing one leaves the other without it."
        end

      routes =
        for entry <- entries, entry.fuse, tiered_fusion?(entry), gift = gifts_by_name[entry.gift], n = Routes.invalid_count(entry.fusion["routes"] || [], gift.tier), n > 0 do
          "#{prefix}: #{entry.gift} has #{n} route(s) that can't make that tier."
        end

      missing ++ upties ++ shared ++ routes
    end) ++ goal_issues(milestone, prefix)
  end

  defp missing_label(names, 0), do: Enum.join(names, ", ")
  defp missing_label([], fragments), do: "#{fragments} more Sin Fragment(s)"
  defp missing_label(names, fragments), do: Enum.join(names, ", ") <> " and #{fragments} more Sin Fragment(s)"

  defp pairs(list), do: for({a, i} <- Enum.with_index(list), {b, j} <- Enum.with_index(list), i < j, do: [a, b])

  defp goal_issues(milestone, prefix) do
    used = for entry <- milestone["entries"] || [], segment <- entry["floors"], into: MapSet.new(), do: segment["goal"]
    empty = for letter <- goal_letters(milestone), not MapSet.member?(used, letter), do: "#{prefix}: goal #{letter} has no entries."
    unknown = for letter <- used, letter not in [nil, "required", "optional"], letter not in goal_letters(milestone), do: "#{prefix}: entries use goal #{letter}, which was removed."
    empty ++ unknown
  end

  defp segment_floors(milestone) do
    (milestone["entries"] || []) |> Enum.flat_map(fn entry -> Enum.map(entry["floors"], & &1["from"]) end) |> Enum.concat([1]) |> Enum.uniq() |> Enum.sort()
  end

  defp keep_sell_issues(data) do
    floors = (data["milestones"] || []) |> Enum.flat_map(&segment_floors/1) |> Enum.uniq() |> Enum.sort()

    for floor <- floors,
        keep = keep_set(data, floor),
        milestone <- data["milestones"] || [],
        entry <- resolved_entries(milestone, floor),
        entry.disposition == "sell",
        MapSet.member?(keep, entry.gift) do
      "Milestone #{milestone["name"]}: sells #{entry.gift} from F#{floor}, but another milestone keeps it, so it won't be sold."
    end
  end

  defp gift_search_issues(data, gifts_by_name) do
    names = data["gift_search"] || []

    too_many =
      if length(names) > @gift_search_max,
        do: ["Gift search has #{length(names)} gifts; only #{@gift_search_max} can be picked."],
        else: []

    unpickable =
      for name <- names, gift = gifts_by_name[name], not gift_searchable?(gift) do
        "Gift search: #{name} is T#{gift.tier}; only T#{@gift_search_max_tier} and under show up."
      end

    too_many ++ unpickable
  end

  defp schedule_issues(data) do
    floor_one =
      if Enum.any?(data["floor_schedule"], &(&1["from_floor"] == 1)),
        do: [],
        else: ["Floor 1 has no workflow; shops before the first scheduled floor do nothing."]

    dangling =
      data["floor_schedule"]
      |> Enum.reject(&find_workflow(data, &1["workflow"]))
      |> Enum.map(&"Floor #{&1["from_floor"]} points at a deleted workflow.")

    floor_one ++ dangling
  end

  defp workflow_issues(data, workflow) do
    workflow["steps"]
    |> numbered_steps("")
    |> Enum.flat_map(fn {step, i} ->
      prefix = "#{workflow["name"]}: step #{i} (#{kind_label(step["kind"])})"

      case {step["kind"], definition_for(data, step)} do
        {"workflow", {:error, :missing_definition}} -> ["#{prefix} has no workflow selected, or it was deleted."]
        {"workflow", {:ok, sub}} ->
          if creates_cycle?(data, workflow["id"], sub["id"]), do: ["#{prefix} runs #{sub["name"]}, which leads back to #{workflow["name"]}."], else: []

        {"milestone", {:error, :missing_definition}} -> ["#{prefix} has no milestone selected, or it was deleted."]
        _ -> []
      end ++ between_issues(data, workflow, step, prefix)
    end)
  end

  defp numbered_steps(steps, prefix) do
    steps
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {step, i} ->
      number = prefix <> to_string(i)
      [{step, number} | Enum.flat_map(branches(step), &numbered_steps(step[&1] || [], "#{number} › #{&1} "))]
    end)
  end

  defp between_issues(data, workflow, %{"between" => id}, prefix) when is_binary(id) do
    case find_workflow(data, id) do
      nil -> ["#{prefix} runs a deleted workflow between repeats."]
      between -> if creates_cycle?(data, workflow["id"], id), do: ["#{prefix} runs #{between["name"]} between repeats, which leads back to #{workflow["name"]}."], else: []
    end
  end

  defp between_issues(_data, _workflow, _step, _prefix), do: []
end
