defmodule StarlightBot.GiftPlans do
  alias StarlightBot.{Conditions, EgoGifts, ThemePacks}
  alias StarlightBot.GiftPlans.Routes

  @version 6
  @dispositions ~w(keep ignore sell)
  @skill_options ~w(s1_s3 s2_s3 s1_s2)
  @heal_cost 100
  @heal_actions ~w(heal revive heal_all)
  @heal_all_max 7
  @refresh_actions ~w(refresh affinity_refresh leave)
  @default_min_cost 250
  @skill_option_costs %{"s1_s2" => 45, "s2_s3" => 75, "s1_s3" => 120}
  @skill_moves %{"s1_s2" => {"s1", "s2"}, "s2_s3" => {"s2", "s3"}, "s1_s3" => {"s1", "s3"}}
  @skill_start %{"s1" => 3, "s2" => 2, "s3" => 1}
  @skill_default_target %{"s1" => 1, "s2" => 2, "s3" => 3}
  @skill_slots 6
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
  @encounter_reward_hooks %{
    "gain_cost" => :encounter_reward_gain_cost,
    "random_gift" => :encounter_reward_random_gift,
    "starlight" => :encounter_reward_starlight,
    "resources" => :encounter_reward_resources,
    "cost_plus_gift" => :encounter_reward_cost_plus_gift
  }
  @encounter_reward_options Map.keys(@encounter_reward_hooks)
  @encounter_reward_labels %{
    "gain_cost" => "Gain cost",
    "random_gift" => "Random gift",
    "starlight" => "Starlight",
    "resources" => "Resources",
    "cost_plus_gift" => "Cost + % chance of gift"
  }
  @encounter_reward_default_order ~w(gain_cost starlight random_gift cost_plus_gift resources)
  @encounter_reward_tier_hooks [:encounter_reward_tier_7, :encounter_reward_tier_5, :encounter_reward_tier_4, :encounter_reward_tier_3]
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

  @cabinet_choice_graces [3, 9]
  @perfected_possibility 9
  @max_cabinet_picks 3

  def cabinet_pick_count(data) do
    extra = Enum.count(data["grace_picks"] || [], &(&1["index"] in @cabinet_choice_graces))
    min(1 + extra, @max_cabinet_picks)
  end

  def perfected_pick(data), do: Enum.find(data["grace_picks"] || [], &(&1["index"] == @perfected_possibility))

  def perfected_options(affinity) do
    perfected_target_options(EgoGifts.list_gifts(), ThemePacks.names_by_gift_id(), affinity)
  end

  def perfected_target_options(gifts, theme_packs_by_gift_id, affinity) do
    for gift <- gifts, gift.tier == 3, gift.affinity == affinity, not is_map_key(theme_packs_by_gift_id, gift.id), do: gift.name
  end

  def perfected_priority(data, options) do
    excluded = perfected_list(data, "target_excluded")
    chosen = Enum.filter(perfected_list(data, "target_gifts"), &(&1 in options and &1 not in excluded))
    Enum.uniq(chosen ++ Enum.reject(options, &(&1 in excluded)))
  end

  def perfected_unprioritized(data, options), do: Enum.filter(options, &(&1 in perfected_list(data, "target_excluded")))

  def perfected_target(data, options), do: if(perfected_pick(data), do: data |> perfected_priority(options) |> List.first())

  def restart_without_target?(data, options), do: perfected_target(data, options) != nil and perfected_pick(data)["restart_without_target"] == true

  def set_perfected_priority(data, priority, unprioritized), do: update_perfected(data, &Map.merge(&1, %{"target_gifts" => priority, "target_excluded" => unprioritized}))

  def set_perfected_restart(data, restart?), do: update_perfected(data, &Map.put(&1, "restart_without_target", restart?))

  def clear_perfected_priority(data), do: set_perfected_priority(data, [], [])

  defp perfected_list(data, key), do: (perfected_pick(data) || %{})[key] || []

  defp update_perfected(data, fun) do
    picks = Enum.map(data["grace_picks"] || [], fn pick -> if pick["index"] == @perfected_possibility, do: fun.(pick), else: pick end)
    Map.put(data, "grace_picks", picks)
  end

  def cabinet_slots(data) do
    starting = starting_gifts(data["affinity"])

    case cabinet_order(data) do
      [] -> [0, 1, 2]
      order -> Enum.map(order, fn name -> Enum.find_index(starting, &(&1 == name)) end)
    end
  end

  def dispositions, do: @dispositions
  def skill_options, do: @skill_options
  def skill_slots, do: @skill_slots

  def skill_target(target, lock_s2?) when is_map(target) do
    s1 = clamp_skill_count(target["s1"], @skill_default_target["s1"], 0, skill_max(%{"s1" => 0}, "s1"))
    s2 = clamp_skill_count(target["s2"], @skill_default_target["s2"], skill_min(lock_s2?, "s2"), skill_max(%{"s1" => s1}, "s2"))
    %{"s1" => s1, "s2" => s2, "s3" => @skill_slots - s1 - s2}
  end

  def skill_target(_target, lock_s2?), do: skill_target(@skill_default_target, lock_s2?)

  def skill_max(_target, "s1"), do: 3
  def skill_max(%{"s1" => s1}, "s2"), do: @skill_slots - @skill_start["s3"] - s1

  def skill_min(true, "s2"), do: @skill_start["s2"]
  def skill_min(_lock_s2?, _key), do: 0

  def step_skill_target(target, key, delta, lock_s2?) when key in ["s1", "s2"] do
    target = skill_target(target, lock_s2?)
    skill_target(Map.update!(target, key, &(&1 + delta)), lock_s2?)
  end

  defp clamp_skill_count(count, _default, min, max) when is_integer(count), do: count |> max(min) |> min(max)
  defp clamp_skill_count(_count, default, min, max), do: default |> max(min) |> min(max)

  def skill_distribution(replaces) do
    Enum.reduce(replaces || %{}, @skill_start, fn {option, count}, distribution ->
      {from, to} = @skill_moves[option]
      distribution |> Map.update!(from, &(&1 - count)) |> Map.update!(to, &(&1 + count))
    end)
  end

  def skill_complete?(distribution, target) do
    distribution["s3"] >= target["s3"] and distribution["s3"] + distribution["s2"] >= target["s3"] + target["s2"]
  end

  def useful_skill_options(distribution, target, lock_s2?) do
    reach_s3? = distribution["s3"] < target["s3"]
    reach_s2_or_better? = distribution["s3"] + distribution["s2"] < target["s3"] + target["s2"]
    s2_room? = not lock_s2? or distribution["s2"] < target["s2"]

    Enum.filter(@skill_options, fn
      "s1_s3" -> reach_s3? and (lock_s2? or reach_s2_or_better?) and distribution["s1"] > 0
      "s2_s3" -> not lock_s2? and reach_s3? and distribution["s2"] > 0
      "s1_s2" -> reach_s2_or_better? and s2_room? and distribution["s1"] > 0
    end)
  end

  defp skill_path_costs(distribution, target, lock_s2?) do
    case useful_skill_options(distribution, target, lock_s2?) do
      [] ->
        {0, 0}

      options ->
        costs =
          Enum.map(options, fn option ->
            {low, high} = distribution |> apply_skill_option(option) |> skill_path_costs(target, lock_s2?)
            {low + @skill_option_costs[option], high + @skill_option_costs[option]}
          end)

        {costs |> Enum.map(&elem(&1, 0)) |> Enum.min(), costs |> Enum.map(&elem(&1, 1)) |> Enum.max()}
    end
  end

  defp apply_skill_option(distribution, option) do
    {from, to} = @skill_moves[option]
    distribution |> Map.update!(from, &(&1 - 1)) |> Map.update!(to, &(&1 + 1))
  end

  def skill_sinner_complete?(replaces, target), do: replaces |> skill_distribution() |> skill_complete?(target)
  def heal_cost, do: @heal_cost
  def skill_replace_cost, do: @skill_replace_cost
  def skill_option_cost(option), do: @skill_option_costs[option]
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

  def encounter_reward_options, do: @encounter_reward_options
  def encounter_reward_label(key), do: Map.fetch!(@encounter_reward_labels, key)
  def encounter_reward_tier_hooks, do: @encounter_reward_tier_hooks

  def default_encounter_rewards, do: [%{"from_floor" => 1, "order" => @encounter_reward_default_order}]

  def encounter_reward_order(data, floor) when is_integer(floor) do
    (data["encounter_rewards"] || default_encounter_rewards())
    |> Enum.filter(&(&1["from_floor"] <= floor))
    |> Enum.max_by(& &1["from_floor"], fn -> %{"order" => @encounter_reward_default_order} end)
    |> Map.fetch!("order")
  end

  def encounter_reward_hooks(order), do: Enum.map(order, &Map.fetch!(@encounter_reward_hooks, &1)) ++ @encounter_reward_tier_hooks
  def encounter_reward_default_order, do: @encounter_reward_default_order

  def version, do: @version

  def blank(affinity \\ nil) do
    section = new_section()

    %{
      "version" => @version,
      "affinity" => affinity,
      "cabinet_gifts" => starting_gifts(affinity),
      "grace_picks" => Enum.map(@default_grace_indexes, &%{"index" => &1, "enhance" => 0}),
      "gift_search" => [],
      "mounting_trials" => default_mounting_trials(),
      "encounter_rewards" => default_encounter_rewards(),
      "sections" => [section]
    }
  end

  def normalize(%{"version" => @version} = data) do
    %{
      "version" => @version,
      "affinity" => data["affinity"],
      "cabinet_gifts" => data["cabinet_gifts"] || [],
      "grace_picks" => data["grace_picks"] || [],
      "gift_search" => data["gift_search"] || [],
      "mounting_trials" => data["mounting_trials"] || default_mounting_trials(),
      "encounter_rewards" => data["encounter_rewards"] || default_encounter_rewards(),
      "sections" => Enum.map(data["sections"] || [new_section()], &normalize_section/1)
    }
    |> then(&if(is_binary(data["run_kind"]), do: Map.put(&1, "run_kind", data["run_kind"]), else: &1))
  end

  def normalize(_data), do: blank()

  defp normalize_section(section) do
    %{"id" => section["id"], "goals" => section["goals"] || [], "entries" => section["entries"] || [], "refresh" => section["refresh"] || [],
      "refresh_floors" => section["refresh_floors"] || [], "refresh_scheduled" => section["refresh_scheduled"] == true, "pursue_optional" => section["pursue_optional"] == true}
    |> then(&if(packs(section) != [], do: Map.put(&1, "packs", packs(section)), else: &1))
    |> then(&if(is_binary(section["stage_of"]), do: Map.merge(&1, %{"stage_of" => section["stage_of"], "name" => section["name"]}), else: &1))
  end

  def new_id(prefix) do
    prefix <> "_" <> Base.encode32(:crypto.strong_rand_bytes(4), case: :lower, padding: false)
  end

  def new_section, do: %{"id" => new_id("ms"), "goals" => [], "entries" => [], "refresh" => []}

  @condition_run_kinds ~w(all_normal becomes_hard all_hard extreme)
  @run_kind_labels %{"all_normal" => "Normal F1-F5", "becomes_hard" => "Hard starts F2-F5", "all_hard" => "Hard from F1", "extreme" => "Extreme planned"}

  def condition_run_kinds, do: @condition_run_kinds
  def run_kind_label(kind), do: Map.get(@run_kind_labels, kind, "(unknown)")

  defp run_kind_matches?("all_hard", run_kind), do: run_kind in ["all_hard", "extreme"]
  defp run_kind_matches?(kind, run_kind), do: kind == run_kind

  def for_run(%{"sections" => sections} = data, run_kind) when is_list(sections) do
    %{"sections" => sections} = data = expand_packs(data)
    timelined = for section <- sections, Enum.any?(section["entries"] || [], &(timelines(&1) != [])), into: MapSet.new(), do: section["id"]
    resolved = resolve_timelines(data, run_kind)
    kept = Enum.reject(resolved["sections"], &(MapSet.member?(timelined, &1["id"]) and inert?(&1)))
    apply_sections(%{resolved | "sections" => kept}, run_kind)
  end

  def for_run(data, _run_kind), do: data

  defp inert?(%{"entries" => [_ | _] = entries}), do: Enum.all?(entries, fn entry -> Enum.all?(entry["floors"], &abandoned?(entry, &1)) end)
  defp inert?(_section), do: false

  defp apply_sections(%{"sections" => sections} = data, run_kind) when is_list(sections) do
    root_ids = for section <- sections, not stage?(section), into: MapSet.new(), do: section["id"]
    kept = Enum.filter(sections, &(not stage?(&1) or MapSet.member?(root_ids, &1["stage_of"])))
    Map.put(%{data | "sections" => stamp_pursue_optional(kept)}, "run_kind", run_kind)
  end

  defp apply_sections(data, _run_kind), do: data

  defp stamp_pursue_optional(sections) do
    root_of = &(&1["stage_of"] || &1["id"])
    wanted = for section <- sections, not stage?(section), section["pursue_optional"] == true, into: MapSet.new(), do: section["id"]
    last = Map.new(sections, &{root_of.(&1), &1["id"]})

    Enum.map(sections, fn section ->
      root = root_of.(section)
      Map.put(section, "pursue_optional", MapSet.member?(wanted, root) and last[root] == section["id"])
    end)
  end

  def find_section(data, id), do: Enum.find(data["sections"] || [], &(&1["id"] == id))

  def update_section(data, id, fun) do
    Map.update!(data, "sections", fn sections -> Enum.map(sections, &if(&1["id"] == id, do: fun.(&1), else: &1)) end)
  end

  def stage?(section), do: is_binary(section["stage_of"])

  def roots(data), do: Enum.reject(data["sections"] || [], &stage?/1)

  def find_root(data, id), do: Enum.find(roots(data), &(&1["id"] == id))

  def stages(data, root_id), do: Enum.filter(data["sections"] || [], &(&1["stage_of"] == root_id))

  def sections(data, root_id), do: Enum.filter([find_section(data, root_id) | stages(data, root_id)], & &1)

  def root_section(%{"sections" => _} = data, %{"stage_of" => root_id} = section) when is_binary(root_id), do: find_section(data, root_id) || section
  def root_section(_data, section), do: section

  def section_name(%{"stage_of" => root_id} = section) when is_binary(root_id), do: section["name"] || "Stage"
  def section_name(_section), do: "Shopping list"

  def rename_stage(data, id, name) do
    update_section(data, id, &if(stage?(&1), do: Map.put(&1, "name", name), else: &1))
  end

  def add_stage(data, root_id) do
    case find_section(data, root_id) do
      nil ->
        {data, nil}

      _root ->
        stage = Map.merge(new_section(), %{"name" => "Stage #{length(stages(data, root_id)) + 2}", "stage_of" => root_id})

        last =
          data["sections"]
          |> Enum.with_index()
          |> Enum.filter(fn {section, _index} -> section["id"] == root_id or section["stage_of"] == root_id end)
          |> List.last()
          |> elem(1)

        {Map.update!(data, "sections", &List.insert_at(&1, last + 1, stage)), stage}
    end
  end

  def remove_stage(data, id), do: Map.update!(data, "sections", fn sections -> Enum.reject(sections, &(&1["id"] == id and stage?(&1))) end)

  def swap_first_stage(data, root_id) do
    with root when is_map(root) <- find_section(data, root_id),
         false <- stage?(root),
         [first | _] <- stages(data, root_id) do
      {root_heals, root_entries} = Enum.split_with(root["entries"], &heal_entry?/1)

      data
      |> update_section(root_id, &Map.merge(&1, %{"goals" => first["goals"], "entries" => root_heals ++ first["entries"]}))
      |> update_section(first["id"], &Map.merge(&1, %{"goals" => root["goals"], "entries" => root_entries}))
    else
      _ -> data
    end
  end

  def move_stage(data, id, -1) do
    case stages(data, root_id(data, id)) do
      [%{"id" => ^id} | _] -> swap_first_stage(data, root_id(data, id))
      _ -> move_stage_sibling(data, id, -1)
    end
  end

  def move_stage(data, id, offset), do: move_stage_sibling(data, id, offset)

  defp move_stage_sibling(data, id, offset) do
    case find_section(data, id) do
      %{"stage_of" => root_id} = stage when is_binary(root_id) ->
        siblings = stages(data, root_id)
        index = Enum.find_index(siblings, &(&1["id"] == id))
        target = index + offset

        if target < 0 or target >= length(siblings) do
          data
        else
          {_stage, rest} = List.pop_at(siblings, index)
          reordered = List.insert_at(rest, target, stage)
          {sections, _pending} =
            Enum.map_reduce(data["sections"], reordered, fn
              %{"stage_of" => ^root_id}, [next | pending] -> {next, pending}
              section, pending -> {section, pending}
            end)

          %{data | "sections" => sections}
        end

      _ ->
        data
    end
  end

  def gift_subject(name), do: %{"gift" => name}
  def tier_subject(tiers), do: %{"tiers" => tiers |> Enum.uniq() |> Enum.sort()}
  def affinity_subject(affinity, tiers), do: %{"affinity" => affinity, "tiers" => tiers |> Enum.uniq() |> Enum.sort()}

  def subject_gift(%{"subject" => %{"gift" => name}}), do: name
  def subject_gift(_entry), do: nil

  def pattern_entry?(entry), do: is_nil(subject_gift(entry))

  def heal_actions, do: @heal_actions
  def heal_all_max, do: @heal_all_max

  def action_cost_range("revive", %{"heal_after" => false} = segment), do: {0, length(segment["sinners"] || []) * @heal_cost}
  def action_cost_range("revive", segment), do: {0, 2 * length(segment["sinners"] || []) * @heal_cost}
  def action_cost_range("heal", %{"repeat" => "until_full"} = segment), do: {length(segment["sinners"] || []) * @heal_cost, 2 * length(segment["sinners"] || []) * @heal_cost}
  def action_cost_range("heal", segment), do: twice(length(segment["sinners"] || []) * @heal_cost)
  def action_cost_range("heal_all", %{"repeat" => "until_full"}), do: {@heal_cost, @heal_all_max * @heal_cost}
  def action_cost_range("heal_all", segment), do: twice(heal_all_times(segment["repeat"]) * @heal_cost)

  def action_cost_range("skill_replace", segment) do
    lock_s2? = segment["lock_s2"] != false
    sinners = length(segment["sinners"] || [])
    {low, high} = skill_path_costs(@skill_start, skill_target(segment["target"], lock_s2?), lock_s2?)
    {low * sinners, high * sinners}
  end

  def heal_all_times("2"), do: 2
  def heal_all_times("3"), do: 3
  def heal_all_times(_repeat), do: 1

  defp twice(cost), do: {cost, cost}
  def action_entry?(entry), do: match?(%{"subject" => %{"action" => _}}, entry)
  def heal_entry?(entry), do: match?(%{"subject" => %{"action" => action}} when action in @heal_actions, entry)

  def subject_label(%{"gift" => name}), do: name
  def subject_label(%{"action" => "heal"}), do: "Greatly Heal"
  def subject_label(%{"action" => "revive"}), do: "Revive (if dead)"
  def subject_label(%{"action" => "heal_all"}), do: "Heal Everyone"
  def subject_label(%{"action" => "skill_replace"}), do: "Skill Replace"
  def subject_label(%{"affinity" => "none", "tiers" => []}), do: "Any keywordless"
  def subject_label(%{"affinity" => "none", "tiers" => tiers}), do: "Any keywordless " <> Enum.map_join(tiers, ", ", &"T#{&1}")
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
      goal: if(keep? or (skill_replace_subject?(entry["subject"]) and not abandoned?), do: segment["goal"] || "required"),
      buy: buy?,
      fuse: keep? and segment["fuse"] == true and not is_nil(entry["fusion"]),
      uptie: if(keep?, do: segment["uptie"] || 0, else: 0),
      max: if(disposition == "sell" or (buy? and pattern_entry?(entry)), do: segment["max"]),
      abandoned: abandoned?,
      sinners: segment["sinners"] || [],
      repeat: segment["repeat"] || "once",
      heal_after: segment["heal_after"] != false,
      target: skill_target(segment["target"], segment["lock_s2"] != false),
      lock_s2: segment["lock_s2"] != false
    }
  end

  defp skill_replace_subject?(%{"action" => "skill_replace"}), do: true
  defp skill_replace_subject?(_subject), do: false

  def resolved_entries(nil, _floor), do: []
  def resolved_entries(section, floor), do: Enum.map(section["entries"] || [], &resolve(&1, floor))

  def keep_set(data, floor, current_id \\ nil) do
    sections = data["sections"] || []
    current_root = current_id && root_id(data, current_id)
    limit = current_id && Enum.find_index(sections, &(&1["id"] == current_id))

    {decided, others} =
      sections
      |> Enum.with_index()
      |> Enum.split_with(fn {section, index} -> not is_nil(current_root) and root_id(data, section["id"]) == current_root and index <= limit end)

    latest =
      for {section, _index} <- decided, entry <- resolved_entries(section, floor), entry.gift, reduce: %{} do
        acc -> Map.put(acc, entry.gift, entry.disposition == "keep")
      end

    additive = for {section, _index} <- others, entry <- resolved_entries(section, floor), entry.disposition == "keep", entry.gift, into: MapSet.new(), do: entry.gift
    for {gift, true} <- latest, into: additive, do: gift
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
    not fixed_recipe?(gift) and gift.tier in @tier_fusable_tiers and not affinityless?(gift) and
      String.contains?(Map.get(gift, :obtain_method) || "", "Shop")
  end

  defp affinityless?(gift) do
    Map.get(gift, :affinity) in [nil, "", "none"]
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

  def has_gift?(section, name), do: Enum.any?(section["entries"] || [], &(subject_gift(&1) == name))

  def add_gift(data, id, name, gifts_by_name, routes_for) do
    by_id = Map.new(gifts_by_name, fn {_name, gift} -> {gift.id, gift} end)
    update_section(data, id, &add_gift_entry(&1, name, :top, gifts_by_name, by_id, routes_for))
  end

  defp add_gift_entry(section, name, role, by_name, by_id, routes_for) do
    gift = by_name[name]

    if is_nil(gift) or has_gift?(section, name) do
      section
    else
      section = Map.update(section, "entries", [], &(&1 ++ [new_gift_entry(gift, role, routes_for)]))
      Enum.reduce(recipe_names(gift, by_id), section, &add_gift_entry(&2, &1, :ingredient, by_name, by_id, routes_for))
    end
  end

  def add_loadout_keep(data, id, name, gifts_by_name) do
    update_section(data, id, fn section ->
      if is_nil(gifts_by_name[name]) or has_gift?(section, name) do
        section
      else
        segment = %{default_segment() | "goal" => "optional", "buy" => false, "fuse" => false}
        entry = %{"id" => new_id("me"), "subject" => gift_subject(name), "fusion" => nil, "floors" => [segment]}
        Map.update(section, "entries", [], &(&1 ++ [entry]))
      end
    end)
  end

  def add_pattern(data, id, subject) do
    update_section(data, id, fn section ->
      if Enum.any?(section["entries"] || [], &(&1["subject"] == subject)) do
        section
      else
        entry = %{"id" => new_id("me"), "subject" => subject, "fusion" => nil, "floors" => [%{default_segment() | "disposition" => "ignore", "goal" => nil}]}
        Map.update(section, "entries", [], &(&1 ++ [entry]))
      end
    end)
  end

  def add_action(data, id, action, sinner) when action in ["skill_replace" | @heal_actions] do
    segment = Map.merge(default_segment(), %{"disposition" => "ignore", "goal" => nil, "buy" => false, "sinners" => List.wrap(sinner), "repeat" => "once"})
    segment = if action == "skill_replace", do: Map.merge(segment, %{"goal" => "optional", "target" => @skill_default_target}), else: segment
    entry = %{"id" => new_id("me"), "subject" => %{"action" => action}, "fusion" => nil, "floors" => [segment]}
    update_section(data, id, fn section -> Map.update(section, "entries", [], &(&1 ++ [entry])) end)
  end

  def packs(section), do: section["packs"] || []

  def add_pack(data, id, ref) do
    update_section(data, id, fn section ->
      if Enum.any?(packs(section), &(&1["ref"] == ref)),
        do: section,
        else: Map.put(section, "packs", packs(section) ++ [%{"id" => new_id("sp"), "ref" => ref}])
    end)
  end

  def remove_pack(data, id, pack_id) do
    update_section(data, id, fn section ->
      case Enum.reject(packs(section), &(&1["id"] == pack_id)) do
        [] -> Map.delete(section, "packs")
        remaining -> Map.put(section, "packs", remaining)
      end
    end)
  end

  def pack_views(data, resolver \\ &StarlightBot.GiftStarterPacks.get/1)

  def pack_views(%{"sections" => sections} = data, resolver) when is_list(sections) do
    if Enum.any?(sections, &(packs(&1) != [])) do
      {views, _used} =
        Enum.reduce(sections, {%{}, %{}}, fn section, {views, used_by_root} ->
          root = root_id(data, section["id"])
          used = Map.get_lazy(used_by_root, root, fn -> all_goal_letters(data, root) end)
          {section_views, used} = section_pack_views(section, resolver, used)
          {Map.put(views, section["id"], section_views), Map.put(used_by_root, root, used)}
        end)

      views
    else
      %{}
    end
  end

  def pack_views(_data, _resolver), do: %{}

  defp section_pack_views(section, resolver, used) do
    own = Enum.map(section["entries"] || [], & &1["subject"])

    {views, {_taken, used}} =
      section
      |> packs()
      |> Enum.map_reduce({own, used}, fn ref, {taken, used} ->
        case resolver.(ref["ref"]) do
          nil ->
            {%{id: ref["id"], ref: ref["ref"], pack: nil, goals: [], entries: []}, {taken, used}}

          pack ->
            source = hd(pack.data["sections"])
            {allocated, used} = allocate_goals(source["goals"] || [], used)
            mapping = Map.new(allocated, &{&1.from, &1.letter})

            entries =
              for entry <- source["entries"] || [] do
                %{entry: remap_pack_entry(entry, mapping, "#{section["id"]}~#{ref["id"]}~"), source_id: entry["id"], shadowed: entry["subject"] in taken}
              end

            goals =
              for %{letter: letter, min: wanted} <- allocated,
                  members = Enum.count(entries, &(not &1.shadowed and goal_member?(&1.entry, letter))),
                  members > 0,
                  do: %{"letter" => letter, "min" => min(wanted, members)}

            {%{id: ref["id"], ref: ref["ref"], pack: pack, goals: goals, entries: entries}, {taken ++ Enum.map(source["entries"] || [], & &1["subject"]), used}}
        end
      end)

    {views, used}
  end

  defp allocate_goals(goals, used) do
    letters = Enum.map(?A..?Z, &<<&1>>)

    Enum.map_reduce(goals, used, fn goal, used ->
      case Enum.find(letters, &(&1 not in used)) do
        nil -> {%{from: goal["letter"], letter: nil, min: goal["min"] || 1}, used}
        letter -> {%{from: goal["letter"], letter: letter, min: goal["min"] || 1}, [letter | used]}
      end
    end)
    |> then(fn {allocated, used} -> {Enum.reject(allocated, &is_nil(&1.letter)), used} end)
  end

  defp goal_member?(entry, letter), do: Enum.any?(all_floors(entry), &(&1["goal"] == letter and &1["disposition"] == "keep"))

  defp remap_pack_entry(entry, mapping, prefix) do
    entry
    |> Map.put("id", prefix <> entry["id"])
    |> then(&if(&1["group"], do: Map.update!(&1, "group", fn group -> prefix <> group end), else: &1))
    |> map_all_floors(fn floors -> Enum.map(floors, &remap_goal(&1, mapping)) end)
  end

  defp remap_goal(%{"goal" => goal} = segment, _mapping) when goal in [nil, "required", "optional"], do: segment
  defp remap_goal(%{"goal" => goal} = segment, mapping), do: %{segment | "goal" => Map.get(mapping, goal, "required")}
  defp remap_goal(segment, _mapping), do: segment

  def pack_goal_letters(data, id) do
    views = pack_views(data)
    root_sections = sections(data, root_id(data, id))
    for section <- root_sections, view <- Map.get(views, section["id"], []), goal <- view.goals, do: goal["letter"]
  end

  def expand_packs(data, resolver \\ &StarlightBot.GiftStarterPacks.get/1)

  def expand_packs(%{"sections" => sections} = data, resolver) when is_list(sections) do
    case pack_views(data, resolver) do
      views when map_size(views) == 0 ->
        data

      views ->
        expanded =
          Enum.map(sections, fn section ->
            section_views = Map.get(views, section["id"], [])
            extra = for view <- section_views, item <- view.entries, not item.shadowed, do: item.entry
            goals = for view <- section_views, goal <- view.goals, do: goal
            %{section | "entries" => (section["entries"] || []) ++ extra, "goals" => (section["goals"] || []) ++ goals}
          end)

        %{data | "sections" => expanded}
    end
  end

  def expand_packs(data, _resolver), do: data

  def unpack(data, id, pack_id, resolver \\ &StarlightBot.GiftStarterPacks.get/1) do
    case Enum.find(Map.get(pack_views(data, resolver), id, []), &(&1.id == pack_id)) do
      %{pack: pack} = view when not is_nil(pack) ->
        groups = for %{entry: %{"group" => group}} <- view.entries, uniq: true, into: %{}, do: {group, new_id("grp")}

        entries =
          for %{shadowed: false, entry: entry} <- view.entries do
            entry |> Map.put("id", new_id("me")) |> then(&if(&1["group"], do: Map.update!(&1, "group", fn group -> groups[group] end), else: &1))
          end

        data
        |> update_section(id, fn section -> %{section | "entries" => (section["entries"] || []) ++ entries, "goals" => (section["goals"] || []) ++ view.goals} end)
        |> remove_pack(id, pack_id)

      _ ->
        data
    end
  end

  def heal_entries(entries), do: Enum.filter(entries, &(match?(%{subject: %{"action" => action}} when action in @heal_actions, &1) and not &1.abandoned))
  def skill_replace_entries(entries), do: Enum.filter(entries, &(match?(%{subject: %{"action" => "skill_replace"}}, &1) and not &1.abandoned))

  def refresh_actions, do: @refresh_actions

  def refresh_action_label("refresh"), do: "Refresh"
  def refresh_action_label("affinity_refresh"), do: "Keyword Refresh"
  def refresh_action_label("leave"), do: "Leave Shop"

  def add_refresh_case(data, id, from \\ 1) do
    refresh_case = %{"id" => new_id("rc"), "condition" => nil, "action" => "refresh", "affinity" => nil, "max" => 4, "min_cost" => @default_min_cost}
    update_section(data, id, &update_refresh_cases(&1, from, fn cases -> cases ++ [refresh_case] end))
  end

  def update_refresh_case(data, id, case_id, fun) do
    update_section(data, id, fn section ->
      update_all_refresh_cases(section, fn cases -> Enum.map(cases, &if(&1["id"] == case_id, do: fun.(&1), else: &1)) end)
    end)
  end

  def remove_refresh_case(data, id, case_id) do
    update_section(data, id, fn section ->
      update_all_refresh_cases(section, fn cases -> Enum.reject(cases, fn refresh_case -> refresh_case["id"] == case_id end) end)
    end)
  end

  def reorder_refresh_cases(data, id, ids, from \\ 1) do
    update_section(data, id, &update_refresh_cases(&1, from, fn cases -> reorder_by_keys(cases, ids, fn refresh_case -> refresh_case["id"] end) end))
  end

  def refresh_froms(section), do: [1 | Enum.map(section["refresh_floors"] || [], & &1["from"])]

  def refresh_cases(section, 1), do: section["refresh"] || []

  def refresh_cases(section, from) do
    case Enum.find(section["refresh_floors"] || [], &(&1["from"] == from)) do
      nil -> []
      segment -> segment["cases"]
    end
  end

  def refresh_cases_at(section, floor) do
    from = section |> refresh_froms() |> Enum.filter(&(&1 <= floor)) |> Enum.max()
    refresh_cases(section, from)
  end

  def any_refresh_cases?(section), do: Enum.any?(refresh_froms(section), &(refresh_cases(section, &1) != []))

  def add_refresh_schedule(data, id), do: update_section(data, id, &Map.put(&1, "refresh_scheduled", true))

  def remove_refresh_schedule(data, id), do: update_section(data, id, &Map.merge(&1, %{"refresh_scheduled" => false, "refresh_floors" => []}))

  def split_refresh(data, id, floor) when floor in 2..@max_floor do
    update_section(data, id, fn section ->
      if floor in refresh_froms(section) do
        section
      else
        copied = section |> refresh_cases_at(floor) |> Enum.map(&Map.put(&1, "id", new_id("rc")))
        segment = %{"from" => floor, "cases" => copied}
        section |> Map.put("refresh_scheduled", true) |> Map.update("refresh_floors", [segment], &Enum.sort_by(&1 ++ [segment], fn s -> s["from"] end))
      end
    end)
  end

  def split_refresh(data, _id, _floor), do: data

  def move_refresh_segment(data, id, from, to) when from != 1 and to in 2..@max_floor do
    update_section(data, id, fn section ->
      if to in refresh_froms(section) do
        section
      else
        Map.update(section, "refresh_floors", [], fn segments ->
          segments |> Enum.map(&if(&1["from"] == from, do: %{&1 | "from" => to}, else: &1)) |> Enum.sort_by(& &1["from"])
        end)
      end
    end)
  end

  def move_refresh_segment(data, _id, _from, _to), do: data

  def remove_refresh_segment(data, _id, 1), do: data

  def remove_refresh_segment(data, id, from) do
    update_section(data, id, fn section -> Map.update(section, "refresh_floors", [], &Enum.reject(&1, fn segment -> segment["from"] == from end)) end)
  end

  defp update_refresh_cases(section, 1, fun), do: Map.update(section, "refresh", [], fun)

  defp update_refresh_cases(section, from, fun) do
    Map.update(section, "refresh_floors", [], fn segments -> Enum.map(segments, &if(&1["from"] == from, do: Map.update!(&1, "cases", fun), else: &1)) end)
  end

  defp update_all_refresh_cases(section, fun) do
    Enum.reduce(refresh_froms(section), section, &update_refresh_cases(&2, &1, fun))
  end

  def matching_refresh_case(section, env) do
    runs = Map.get(env, :case_runs, %{})
    source = root_section(Map.get(env, :plan), section)
    env = Map.put(env, :current_section, section["id"])

    Enum.find(refresh_cases_at(source, Map.get(env, :floor) || 1), fn refresh_case ->
      under_cap?(refresh_case, runs) and cost_after_ok?(refresh_case, env) and eval_condition(refresh_case["condition"], Map.put(env, :case_action, refresh_case["action"]))
    end)
  end

  defp under_cap?(%{"max" => max, "id" => id}, runs) when is_integer(max), do: Map.get(runs, id, 0) < max
  defp under_cap?(_refresh_case, _runs), do: true

  def default_min_cost, do: @default_min_cost

  defp cost_after_ok?(%{"action" => "leave"}, _env), do: true

  defp cost_after_ok?(refresh_case, env) do
    min_cost = Map.get(refresh_case, "min_cost", @default_min_cost)

    case env do
      _ when min_cost == 0 -> true
      %{wallet: wallet, refresh_costs: costs} when is_integer(wallet) -> wallet - Map.get(costs, refresh_case["action"], 0) >= min_cost
      %{wallet: wallet} when is_integer(wallet) -> wallet >= min_cost
      _ -> false
    end
  end

  def find_entry(section, entry_id), do: Enum.find(section["entries"] || [], &(&1["id"] == entry_id))

  def update_entry(data, id, entry_id, fun) do
    update_section(data, id, fn section ->
      Map.update(section, "entries", [], fn entries -> Enum.map(entries, &if(&1["id"] == entry_id, do: fun.(&1), else: &1)) end)
    end)
  end

  def update_segment(data, id, entry_id, from, fun, timeline \\ nil) do
    update_entry(data, id, entry_id, fn entry ->
      with_timeline(entry, timeline, fn entry ->
        Map.update!(entry, "floors", fn floors -> Enum.map(floors, &if(&1["from"] == from, do: fun.(&1), else: &1)) end)
      end)
    end)
  end

  def with_timeline(entry, nil, fun), do: fun.(entry)

  def with_timeline(entry, timeline_id, fun) do
    case find_timeline(entry, timeline_id) do
      nil ->
        entry

      timeline ->
        floors = fun.(Map.put(entry, "floors", timeline["floors"]))["floors"]
        Map.put(entry, "timelines", Enum.map(entry["timelines"], &if(&1["id"] == timeline_id, do: %{&1 | "floors" => floors}, else: &1)))
    end
  end

  def timelines(entry), do: entry["timelines"] || []

  def find_timeline(entry, timeline_id), do: Enum.find(timelines(entry), &(&1["id"] == timeline_id))

  def timeline_view(entry, timeline_id) do
    case timeline_id && find_timeline(entry, timeline_id) do
      %{"floors" => floors} -> %{entry | "floors" => floors}
      _ -> entry
    end
  end

  def all_floors(entry), do: entry["floors"] ++ Enum.flat_map(timelines(entry), & &1["floors"])

  def timeline_kinds(entry), do: timelines(entry) |> Enum.flat_map(& &1["kinds"]) |> Enum.uniq()

  def add_timeline(data, id, entry_id, timeline_id, kinds) do
    update_entry(data, id, entry_id, fn entry ->
      kinds = Enum.filter(@condition_run_kinds, &(&1 in kinds and &1 not in timeline_kinds(entry)))

      if kinds == [] or find_timeline(entry, timeline_id),
        do: entry,
        else: Map.put(entry, "timelines", timelines(entry) ++ [%{"id" => timeline_id, "kinds" => kinds, "floors" => entry["floors"]}])
    end)
  end

  def toggle_timeline_kind(data, id, entry_id, timeline_id, kind) when kind in @condition_run_kinds do
    update_entry(data, id, entry_id, fn entry ->
      case find_timeline(entry, timeline_id) do
        nil ->
          entry

        %{"kinds" => kinds} = timeline ->
          next =
            cond do
              kind in kinds -> List.delete(kinds, kind)
              kind in timeline_kinds(entry) -> kinds
              true -> Enum.filter(@condition_run_kinds, &(&1 in [kind | kinds]))
            end

          if next == [],
            do: remove_timeline_from(entry, timeline["id"]),
            else: Map.put(entry, "timelines", Enum.map(entry["timelines"], &if(&1 == timeline, do: %{timeline | "kinds" => next}, else: &1)))
      end
    end)
  end

  def toggle_timeline_kind(data, _id, _entry_id, _timeline_id, _kind), do: data

  def remove_timeline(data, id, entry_id, timeline_id), do: update_entry(data, id, entry_id, &remove_timeline_from(&1, timeline_id))

  defp remove_timeline_from(entry, timeline_id) do
    case Enum.reject(timelines(entry), &(&1["id"] == timeline_id)) do
      [] -> Map.delete(entry, "timelines")
      rest -> Map.put(entry, "timelines", rest)
    end
  end

  def timeline_for(entry, run_kind) do
    timelines = timelines(entry)
    Enum.find(timelines, &(run_kind in &1["kinds"])) || (run_kind == "extreme" && Enum.find(timelines, &("all_hard" in &1["kinds"]))) || nil
  end

  def resolve_timelines(%{"sections" => sections} = data, run_kind) when is_list(sections) do
    resolved =
      for section <- sections do
        Map.update(section, "entries", [], fn entries ->
          for entry <- entries do
            case timeline_for(entry, run_kind) do
              nil -> Map.delete(entry, "timelines")
              timeline -> entry |> Map.delete("timelines") |> Map.put("floors", timeline["floors"])
            end
          end
        end)
      end

    %{data | "sections" => resolved}
  end

  def resolve_timelines(data, _run_kind), do: data

  def remove_entry(data, id, entry_id) do
    update_section(data, id, fn section -> Map.update(section, "entries", [], &Enum.reject(&1, fn entry -> entry["id"] == entry_id end)) end)
  end

  def reorder_entries(data, id, ids) do
    update_section(data, id, fn section ->
      Map.update(section, "entries", [], fn entries ->
        {actions, gifts} = entries |> reorder_by_keys(expand_entry_ids(entries, ids), & &1["id"]) |> Enum.split_with(&heal_entry?/1)
        actions ++ gifts
      end)
    end)
  end

  def group_key(entry), do: entry["group"] || entry["id"]

  def group_members(section, entry_id) do
    case find_entry(section, entry_id) do
      nil -> []
      entry -> Enum.filter(section["entries"] || [], &(group_key(&1) == group_key(entry)))
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
    update_section(data, id, fn section ->
      Map.update(section, "entries", [], fn entries ->
        members = Enum.filter(entries, &(group_key(&1) == key))
        place_block(entries, &(group_key(&1) == key), reorder_by_keys(members, ids, & &1["id"]))
      end)
    end)
  end

  def join_group(data, id, entry_id, key, ids) do
    update_section(data, id, fn section ->
      entries = section["entries"] || []
      template = Enum.find(entries, &(group_key(&1) == key and &1["id"] != entry_id))
      moving = Enum.find(entries, &(&1["id"] == entry_id))

      if is_nil(template) or is_nil(moving) do
        section
      else
        group = template["group"] || new_id("grp")
        joined = moving |> adopt_schedule(template) |> Map.merge(%{"group" => group, "scheduled" => true})
        rest = entries |> Enum.reject(&(&1["id"] == entry_id)) |> Enum.map(&if(group_key(&1) == key, do: Map.put(&1, "group", group), else: &1))
        member? = &(&1["group"] == group)
        members = Enum.filter(rest, member?) ++ [joined]
        Map.put(section, "entries", place_block(rest, member?, reorder_by_keys(members, ids, & &1["id"])))
      end
    end)
  end

  def leave_group(data, id, entry_id, ids) do
    data
    |> update_entry(id, entry_id, &Map.delete(&1, "group"))
    |> reorder_entries(id, ids)
  end

  def transfer_entries(data, from_id, to_id, entry_ids) when from_id != to_id do
    with %{} = from <- find_section(data, from_id), %{} = to <- find_section(data, to_id) do
      letters = goal_letters(to)
      keep_goal? = fn goal -> goal in [nil, "required", "optional"] or goal in letters end

      moving =
        from["entries"]
        |> Enum.filter(&(&1["id"] in entry_ids))
        |> Enum.map(fn entry ->
          entry
          |> Map.delete("group")
          |> map_all_floors(fn floors -> Enum.map(floors, &if(keep_goal?.(&1["goal"]), do: &1, else: Map.put(&1, "goal", "required"))) end)
        end)

      data
      |> update_section(from_id, fn section -> Map.update!(section, "entries", &Enum.reject(&1, fn entry -> entry["id"] in entry_ids end)) end)
      |> update_section(to_id, fn section -> Map.update(section, "entries", moving, &(&1 ++ moving)) end)
    else
      _ -> data
    end
  end

  def transfer_entries(data, _from_id, _to_id, _entry_ids), do: data

  def group_section_id(data, root_id, key) do
    data |> sections(root_id) |> Enum.find_value(fn section -> Enum.any?(section["entries"] || [], &(group_key(&1) == key)) && section["id"] end)
  end

  def move_entries(data, id, moved, nil, ids) do
    Enum.reduce(moved, data, &leave_group(&2, id, &1, ids))
  end

  def move_entries(data, id, moved, key, ids) do
    {data, _key} =
      Enum.reduce(moved, {data, key}, fn entry_id, {acc, key} ->
        acc = join_group(acc, id, entry_id, key, ids)
        entry = acc |> find_section(id) |> find_entry(entry_id)
        {acc, (entry && entry["group"]) || key}
      end)

    data
  end

  def paste_entries(data, id, sources, after_id) do
    groups = for %{"group" => group} <- sources, uniq: true, into: %{}, do: {group, new_id("grp")}

    clones =
      Enum.map(sources, fn entry ->
        entry |> Map.put("id", new_id("me")) |> then(&if(&1["group"], do: Map.update!(&1, "group", fn group -> groups[group] end), else: &1))
      end)

    data =
      update_section(data, id, fn section ->
        Map.update(section, "entries", clones, fn entries ->
          index = Enum.find_index(entries, &(&1["id"] == after_id))
          {before, rest} = if index, do: Enum.split(entries, index + 1), else: {entries, []}
          {actions, gifts} = Enum.split_with(before ++ clones ++ rest, &heal_entry?/1)
          actions ++ gifts
        end)
      end)

    target = data |> find_section(id) |> find_entry(after_id)

    if target && (target["group"] || scheduled_alone?(target)) do
      key = group_key(target)
      members = data |> find_section(id) |> Map.fetch!("entries") |> Enum.filter(&(group_key(&1) == key)) |> Enum.map(& &1["id"])
      ids = Enum.flat_map(members, fn member -> if member == after_id, do: [member | Enum.map(clones, & &1["id"])], else: [member] end)
      move_entries(data, id, Enum.map(clones, & &1["id"]), key, ids)
    else
      data
    end
  end

  def scheduled?(entry), do: entry["scheduled"] == true or length(entry["floors"]) > 1 or timelines(entry) != []

  defp scheduled_alone?(entry), do: scheduled?(entry)

  defp adopt_schedule(entry, template) do
    adopted = Map.put(entry, "floors", adopt_floors(entry, template, template["floors"]))

    case timelines(template) do
      [] -> Map.delete(adopted, "timelines")
      timelines -> Map.put(adopted, "timelines", Enum.map(timelines, &%{&1 | "floors" => adopt_floors(entry, template, &1["floors"])}))
    end
  end

  defp adopt_floors(entry, template, tabs) do
    for tab <- tabs do
      segment = segment_at(entry, tab["from"])
      segment = if not pattern_entry?(entry) and segment["disposition"] == "ignore", do: Map.put(segment, "disposition", "keep"), else: segment
      Map.merge(segment, %{"from" => tab["from"], "abandoned" => abandoned?(template, tab)})
    end
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

  def split_entry(data, id, entry_id, floor, timeline \\ nil)

  def split_entry(data, id, entry_id, floor, timeline) when floor in 2..@max_floor do
    update_entry(data, id, entry_id, fn entry ->
      with_timeline(entry, timeline, fn entry ->
        if Enum.any?(entry["floors"], &(&1["from"] == floor)) do
          entry
        else
          segment = %{segment_at(entry, floor) | "from" => floor}
          Map.put(entry, "floors", Enum.sort_by(entry["floors"] ++ [segment], & &1["from"]))
        end
      end)
    end)
  end

  def split_entry(data, _id, _entry_id, _floor, _timeline), do: data

  def move_segment(data, id, entry_id, from, to, timeline \\ nil)

  def move_segment(data, id, entry_id, from, to, timeline) when from != 1 and to in 2..@max_floor do
    update_entry(data, id, entry_id, fn entry ->
      with_timeline(entry, timeline, fn entry ->
        if Enum.any?(entry["floors"], &(&1["from"] == to)) do
          entry
        else
          floors = Enum.map(entry["floors"], &if(&1["from"] == from, do: %{&1 | "from" => to}, else: &1))
          Map.put(entry, "floors", Enum.sort_by(floors, & &1["from"]))
        end
      end)
    end)
  end

  def move_segment(data, _id, _entry_id, _from, _to, _timeline), do: data

  def remove_segment(data, id, entry_id, from, timeline \\ nil)

  def remove_segment(data, _id, _entry_id, 1, _timeline), do: data

  def remove_segment(data, id, entry_id, from, timeline) do
    update_entry(data, id, entry_id, fn entry ->
      with_timeline(entry, timeline, fn entry -> Map.update!(entry, "floors", &Enum.reject(&1, fn segment -> segment["from"] == from end)) end)
    end)
  end

  defp map_all_floors(entry, fun) do
    entry = Map.update!(entry, "floors", fun)

    case timelines(entry) do
      [] -> entry
      timelines -> Map.put(entry, "timelines", Enum.map(timelines, &%{&1 | "floors" => fun.(&1["floors"])}))
    end
  end

  def goal_letters(section), do: Enum.map(section["goals"] || [], & &1["letter"])

  def root_id(data, id) do
    case find_section(data, id) do
      %{"stage_of" => root} when is_binary(root) -> root
      _ -> id
    end
  end

  def all_goal_letters(data, id), do: data |> sections(root_id(data, id)) |> Enum.flat_map(&goal_letters/1)

  def add_goal(data, id) do
    used = all_goal_letters(data, id) ++ pack_goal_letters(data, id)

    update_section(data, id, fn section ->
      case Enum.find(Enum.map(?A..?Z, &<<&1>>), &(&1 not in used)) do
        nil -> section
        letter -> Map.update(section, "goals", [], &(&1 ++ [%{"letter" => letter, "min" => 1}]))
      end
    end)
  end

  def set_goal_min(data, id, letter, min) do
    update_section(data, id, fn section ->
      Map.update(section, "goals", [], fn goals -> Enum.map(goals, &if(&1["letter"] == letter, do: Map.put(&1, "min", max(min, 1)), else: &1)) end)
    end)
  end

  def remove_goal(data, id, letter) do
    update_section(data, id, fn section ->
      entries =
        Enum.map(section["entries"] || [], fn entry ->
          map_all_floors(entry, fn floors -> Enum.map(floors, &if(&1["goal"] == letter, do: Map.put(&1, "goal", "required"), else: &1)) end)
        end)

      %{section | "goals" => Enum.reject(section["goals"] || [], &(&1["letter"] == letter)), "entries" => entries}
    end)
  end

  defp goal_owner(data, section_id, letter) do
    sections = sections(data, root_id(data, section_id))
    Enum.find_value(sections, section_id, &(letter in goal_letters(&1) && &1["id"]))
  end

  def goal_min(section, letter) do
    case Enum.find(section["goals"] || [], &(&1["letter"] == letter)) do
      %{"min" => min} when is_integer(min) -> min
      _ -> 1
    end
  end

  def progress(data, id, env) do
    section = find_section(data, id)
    build_progress(data, section, resolved_entries(section, env_floor(env)), env)
  end

  def working_progress(data, id, env) do
    section = find_section(data, id)
    floor = env_floor(env)
    build_progress(data, section, resolved_entries(section, floor) ++ carried_entries(data, section, floor), env)
  end

  def working_entries(data, section, floor), do: resolved_entries(section, floor) ++ carried_entries(data, section, floor)

  def carried_entries(_data, nil, _floor), do: []

  def carried_entries(data, section, floor) do
    own = MapSet.new(section["entries"] || [], & &1["subject"])

    data
    |> sections(root_id(data, section["id"]))
    |> Enum.take_while(&(&1["id"] != section["id"]))
    |> Enum.reverse()
    |> Enum.flat_map(&resolved_entries(&1, floor))
    |> Enum.uniq_by(& &1.subject)
    |> Enum.reject(&MapSet.member?(own, &1.subject))
    |> Enum.filter(&carried?/1)
  end

  defp carried?(%{subject: %{"gift" => _}, disposition: "keep", goal: "optional"}), do: true
  defp carried?(_entry), do: false

  defp build_progress(data, section, entries, env) do
    covered = data["sections"] |> Enum.flat_map(&resolved_entries(&1, env_floor(env))) |> covered(env)
    statuses = Map.new(entries, &{&1.id, entry_status(&1, env, covered)})
    %{section: section, entries: entries, statuses: statuses, pending: pending_ingredients(entries, env)}
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

  def entry_status(%{subject: %{"action" => "skill_replace"}} = entry, env, _covered) do
    replaces = Map.get(env, :skill_replaces, %{})
    if Enum.all?(entry.sinners, &skill_sinner_complete?(replaces[&1], entry.target)), do: :done, else: :open
  end

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

  def goal_entries(progress), do: Enum.filter(progress.entries, &((&1.disposition == "keep" and is_binary(&1.gift)) or (skill_replace_subject?(&1.subject) and is_binary(&1.goal))))

  def goal_members(progress, letter), do: Enum.filter(goal_entries(progress), &(&1.goal == letter))

  def goal_need(progress, letter), do: min(goal_min(progress.section, letter), length(goal_members(progress, letter)))

  def goal_committed(progress, letter), do: progress |> goal_members(letter) |> Enum.count(&(status(progress, &1) != :open))

  def goal_done(progress, letter), do: progress |> goal_members(letter) |> Enum.count(&(status(progress, &1) == :done))

  def reached?(%{section: nil}), do: false

  def reached?(%{section: %{"pursue_optional" => true}}), do: false

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

  def section_reached?(data, id, env), do: data |> progress(id, env) |> reached?()

  def section_effectively_reached?(data, id, env) do
    case progress(data, id, env) do
      %{section: nil} -> false
      %{section: section} = progress -> reached?(%{progress | section: Map.put(section, "pursue_optional", false)})
    end
  end

  def goal_reached?(data, section_id, letter, env) do
    letter = letter || "required"
    section_id = if letter == "required", do: section_id, else: goal_owner(data, section_id, letter)
    progress = progress(data, section_id, env)

    cond do
      progress.section == nil -> false
      letter == "required" -> progress |> goal_members("required") |> Enum.all?(&(status(progress, &1) == :done))
      is_binary(letter) -> goal_members(progress, letter) != [] and goal_done(progress, letter) >= goal_need(progress, letter)
      true -> false
    end
  end

  defp reorder_by_keys(items, keys, key_fun) do
    by_key = Map.new(items, &{key_fun.(&1), &1})
    ordered = keys |> Enum.map(&by_key[&1]) |> Enum.reject(&is_nil/1)
    ordered ++ Enum.reject(items, &(&1 in ordered))
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

  @cmps ~w(eq gte lte)

  defp eval_leaf(leaf, env), do: eval_base(leaf, env) != (leaf["not"] == true)

  defp eval_base(%{"op" => "cost"} = leaf, %{wallet: wallet} = env) when is_integer(wallet), do: compare(wallet - refresh_spend(leaf, env), leaf["cmp"], leaf["value"])
  defp eval_base(%{"op" => "cost"}, _env), do: false
  defp eval_base(%{"op" => "refreshes"} = leaf, env), do: compare(Map.get(env, :refreshes, 0), leaf["cmp"], leaf["value"])
  defp eval_base(%{"op" => "owns", "gift" => gift}, %{owned: owned}), do: MapSet.member?(owned, gift)
  defp eval_base(%{"op" => "stage"} = leaf, %{plan: plan} = env), do: section_reached?(plan, leaf["stage"], env)
  defp eval_base(%{"op" => "goal"} = leaf, %{plan: plan} = env), do: goal_reached?(plan, leaf["stage"] || env[:current_section], leaf["goal"], env)
  defp eval_base(%{"op" => "run_kind"} = leaf, %{plan: %{"run_kind" => run_kind}}), do: run_kind_matches?(leaf["kind"], run_kind)
  defp eval_base(%{"op" => "run_kind"}, _env), do: false

  defp refresh_spend(%{"when" => "after"}, %{case_action: action, refresh_costs: costs}), do: Map.get(costs, action, 0)
  defp refresh_spend(_leaf, _env), do: 0

  defp compare(left, "eq", right), do: left == right
  defp compare(left, "lte", right), do: left <= right
  defp compare(left, _cmp, right), do: left >= right

  def default_leaf, do: %{"op" => "goal", "goal" => "required", "not" => true}

  def condition_leaf(params), do: params |> build_leaf() |> put_not(params)

  defp build_leaf(%{"op" => "cost"} = params) do
    leaf = %{"op" => "cost", "cmp" => if(params["cmp"] in @cmps, do: params["cmp"], else: "gte"), "value" => max(parse_count(params["value"]), 0)}
    if params["when"] == "after", do: Map.put(leaf, "when", "after"), else: leaf
  end

  defp build_leaf(%{"op" => "refreshes"} = params) do
    %{"op" => "refreshes", "cmp" => if(params["cmp"] in @cmps, do: params["cmp"], else: "gte"), "value" => max(parse_count(params["value"]), 0)}
  end

  defp build_leaf(%{"op" => "stage"} = params), do: %{"op" => "stage", "stage" => blank_to_nil(params["stage"])}

  defp build_leaf(%{"op" => "goal"} = params) do
    case String.split(blank_to_nil(params["goal"]) || "required", ":", parts: 2) do
      ["required", id] when id != "" -> %{"op" => "goal", "goal" => "required", "stage" => id}
      [goal | _] -> %{"op" => "goal", "goal" => goal}
    end
  end

  defp build_leaf(%{"op" => "run_kind"} = params), do: %{"op" => "run_kind", "kind" => if(params["kind"] in @condition_run_kinds, do: params["kind"], else: hd(@condition_run_kinds))}

  defp build_leaf(params), do: %{"op" => "owns", "gift" => String.trim(params["gift"] || "")}

  defp put_not(leaf, %{"not" => "true"}), do: Map.put(leaf, "not", true)
  defp put_not(leaf, _params), do: leaf

  defp parse_count(value) do
    case Integer.parse(value || "") do
      {int, _} -> int
      :error -> 0
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  def prune_condition(node), do: Conditions.prune(node)

  def condition_label(node, data \\ nil), do: Conditions.label(node, &leaf_label(&1, data))

  @cmp_symbols %{"eq" => "=", "gte" => ">=", "lte" => "<="}

  defp leaf_label(%{"op" => "cost", "when" => "after"} = leaf, _data) do
    "#{if leaf["not"], do: "not "}cost after refresh #{Map.get(@cmp_symbols, leaf["cmp"], ">=")} #{leaf["value"]}"
  end

  defp leaf_label(%{"op" => op} = leaf, _data) when op in ["cost", "refreshes"] do
    "#{if leaf["not"], do: "not "}#{op} #{Map.get(@cmp_symbols, leaf["cmp"], ">=")} #{leaf["value"]}"
  end

  defp leaf_label(%{"op" => "owns"} = leaf, _data), do: "#{if leaf["not"], do: "missing", else: "owns"} #{leaf["gift"]}"
  defp leaf_label(%{"op" => "stage"} = leaf, data), do: "#{section_title(data, leaf["stage"])} #{if leaf["not"], do: "not "}done"
  defp leaf_label(%{"op" => "goal", "stage" => id} = leaf, data) when is_binary(id), do: "#{goal_display(leaf["goal"])} of #{section_title(data, id)} #{if leaf["not"], do: "not "}done"
  defp leaf_label(%{"op" => "goal"} = leaf, _data), do: "goal #{goal_display(leaf["goal"])} #{if leaf["not"], do: "not "}done"
  defp leaf_label(%{"op" => "run_kind"} = leaf, _data), do: "run #{if leaf["not"], do: "is not", else: "is"} #{run_kind_label(leaf["kind"])}"

  defp goal_display("required"), do: "Required"
  defp goal_display(nil), do: "Required"
  defp goal_display(letter), do: letter

  defp section_title(_data, nil), do: "(none picked)"
  defp section_title(nil, id), do: id

  defp section_title(data, id) do
    case find_section(data, id) do
      nil -> "(deleted)"
      section -> section_name(section)
    end
  end

  def missing_ingredients(section, entry, gifts_by_name) do
    by_id = Map.new(gifts_by_name, fn {_name, gift} -> {gift.id, gift} end)

    case gifts_by_name[subject_gift(entry)] do
      nil ->
        {[], 0}

      gift ->
        names = Enum.reject(recipe_names(gift, by_id), &has_gift?(section, &1))
        fragments = Enum.count(section["entries"] || [], &(subject_gift(&1) in @sin_fragments))
        {names, max(fragment_slots(gift) - fragments, 0)}
    end
  end

  def issues(data, gifts_by_name \\ %{}) do
    missing_pack_issues(data) ++ expanded_issues(expand_packs(data), gifts_by_name)
  end

  defp missing_pack_issues(data) do
    for section <- data["sections"] || [], pack <- packs(section), is_nil(StarlightBot.GiftStarterPacks.get(pack["ref"])), do: "#{section_name(section)}: a starter pack no longer exists."
  end

  defp expanded_issues(data, gifts_by_name) do
    if Enum.any?(data["sections"] || [], fn section -> Enum.any?(section["entries"] || [], &(timelines(&1) != [])) end),
      do: @condition_run_kinds |> Enum.flat_map(&plan_issues(resolve_timelines(data, &1), gifts_by_name)) |> Enum.uniq(),
      else: plan_issues(data, gifts_by_name)
  end

  defp plan_issues(data, gifts_by_name) do
    (gift_search_issues(data, gifts_by_name) ++
       Enum.flat_map(data["sections"] || [], &section_issues(&1, gifts_by_name)) ++
       keep_sell_issues(data))
    |> Enum.uniq()
  end

  defp section_issues(section, gifts_by_name) do
    by_id = Map.new(gifts_by_name, fn {_name, gift} -> {gift.id, gift} end)
    prefix = section_name(section)
    floors = segment_floors(section)

    Enum.flat_map(floors, fn floor ->
      entries = resolved_entries(section, floor)
      fixed = Enum.filter(entries, &(&1.fuse and fixed_fusion?(&1)))
      at = if length(floors) > 1, do: " (F#{floor}+)", else: ""

      missing =
        Enum.flat_map(fixed, fn entry ->
          case missing_ingredients(section, %{"subject" => entry.subject}, gifts_by_name) do
            {[], 0} -> []
            {names, fragments} -> ["#{prefix}: #{entry.gift} needs #{missing_label(names, fragments)} in this stage."]
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
    end) ++ goal_issues(section, prefix)
  end

  defp missing_label(names, 0), do: Enum.join(names, ", ")
  defp missing_label([], fragments), do: "#{fragments} more Sin Fragment(s)"
  defp missing_label(names, fragments), do: Enum.join(names, ", ") <> " and #{fragments} more Sin Fragment(s)"

  defp pairs(list), do: for({a, i} <- Enum.with_index(list), {b, j} <- Enum.with_index(list), i < j, do: [a, b])

  defp goal_issues(section, prefix) do
    used = for entry <- section["entries"] || [], segment <- all_floors(entry), into: MapSet.new(), do: segment["goal"]
    empty = for letter <- goal_letters(section), not MapSet.member?(used, letter), do: "#{prefix}: goal #{letter} has no entries."
    unknown = for letter <- used, letter not in [nil, "required", "optional"], letter not in goal_letters(section), do: "#{prefix}: entries use goal #{letter}, which was removed."
    empty ++ unknown
  end

  defp segment_floors(section) do
    (section["entries"] || []) |> Enum.flat_map(fn entry -> Enum.map(entry["floors"], & &1["from"]) end) |> Enum.concat([1]) |> Enum.uniq() |> Enum.sort()
  end

  defp keep_sell_issues(data) do
    floors = (data["sections"] || []) |> Enum.flat_map(&segment_floors/1) |> Enum.uniq() |> Enum.sort()

    for floor <- floors,
        keep = keep_set(data, floor),
        section <- data["sections"] || [],
        entry <- resolved_entries(section, floor),
        entry.disposition == "sell",
        MapSet.member?(keep, entry.gift) do
      "#{section_name(section)}: sells #{entry.gift} from F#{floor}, but another stage keeps it, so it won't be sold."
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
end
