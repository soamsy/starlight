defmodule StarlightBot.GiftPlans do
  alias StarlightBot.Conditions
  alias StarlightBot.GiftPlans.Routes

  @library_keys ~w(fusions upties lists)
  @step_kinds ~w(if milestone uptie fusion buy_list refresh affinity_refresh sell skill_replace heal heal_all revive budget workflow bail leave)
  @library_refs %{
    "uptie" => {"upties", "upties"},
    "fusion" => {"fusions", "fusions"},
    "buy_list" => {"lists", "list"},
    "sell" => {"lists", "list"}
  }
  @skill_options ~w(s1_s3 s2_s3 s1_s2)
  @heal_cost 100
  @skill_replace_cost 50
  @uptie_step_costs %{1 => [50, 100], 2 => [60, 120], 3 => [75, 150], 4 => [100, 200]}
  @default_grace_indexes [0, 2, 3, 7]
  @chance_comet 8
  @gift_search_max 3
  @gift_search_starlight_costs [70, 160, 270]
  @shop_tiers 1..4
  @gift_search_max_tier 3
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

  def library_keys, do: @library_keys
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
  def skill_options, do: @skill_options
  def heal_cost, do: @heal_cost
  def skill_replace_cost, do: @skill_replace_cost
  def library_ref(kind), do: Map.get(@library_refs, kind)
  def gift_search_max, do: @gift_search_max

  def gift_search_starlight_cost(0), do: 0
  def gift_search_starlight_cost(count), do: Enum.at(@gift_search_starlight_costs, min(count, @gift_search_max) - 1)
  def gift_search_slot_cost(slot), do: gift_search_starlight_cost(slot + 1) - gift_search_starlight_cost(slot)
  def shop_tiers, do: @shop_tiers

  def blank(affinity \\ nil) do
    keep = new_definition("lists", "Keep")
    workflow = %{"id" => new_id("wf"), "name" => "Standard", "keep" => keep["id"], "steps" => []}

    %{
      "version" => 3,
      "affinity" => affinity,
      "cabinet_gifts" => starting_gifts(affinity),
      "grace_picks" => Enum.map(@default_grace_indexes, &%{"index" => &1, "enhance" => 0}),
      "gift_search" => [],
      "library" => %{"lists" => [keep], "upties" => [], "fusions" => []},
      "workflows" => [workflow],
      "floor_schedule" => [%{"from_floor" => 1, "workflow" => workflow["id"]}],
      "milestones" => [new_milestone("Shop Done")]
    }
  end

  def normalize(%{"version" => 3} = data) do
    library = data["library"] || %{}

    %{
      "version" => 3,
      "affinity" => data["affinity"],
      "cabinet_gifts" => data["cabinet_gifts"] || [],
      "grace_picks" => data["grace_picks"] || [],
      "gift_search" => data["gift_search"] || [],
      "library" => Map.new(@library_keys, &{&1, library[&1] || []}),
      "workflows" => data["workflows"] || [],
      "floor_schedule" => data["floor_schedule"] || [],
      "milestones" => data["milestones"] || [new_milestone("Shop Done")]
    }
  end

  def normalize(_data), do: blank()

  def new_id(prefix) do
    prefix <> "_" <> Base.encode32(:crypto.strong_rand_bytes(4), case: :lower, padding: false)
  end

  def new_milestone(name), do: %{"id" => new_id("ms"), "name" => name, "condition" => nil, "blocks" => []}

  def find_milestone(data, id), do: Enum.find(data["milestones"] || [], &(&1["id"] == id))

  def entry_ref(lib, id, gift \\ nil)
  def entry_ref("lists", id, gift), do: %{"lib" => "lists", "id" => id, "gift" => gift}
  def entry_ref(lib, id, _gift), do: %{"lib" => lib, "id" => id}

  def entry_key(ref), do: Enum.join([ref["lib"], ref["id"], ref["gift"] || ""], "|")

  def block_key(%{"type" => "group", "letter" => letter}), do: "group:" <> letter
  def block_key(%{"ref" => ref}), do: entry_key(ref)

  def block_refs(%{"type" => "group", "refs" => refs}), do: refs
  def block_refs(%{"ref" => ref}), do: [ref]

  def milestone_refs(milestone), do: Enum.flat_map(milestone["blocks"] || [], &block_refs/1)

  def milestone_entries(data, id) do
    case find_milestone(data, id) do
      nil ->
        []

      milestone ->
        for block <- milestone["blocks"] || [],
            ref <- block_refs(block),
            definition = resolve_ref(data, ref),
            do: %{
              lib: ref["lib"],
              definition: definition,
              gift: ref["gift"],
              group: if(block["type"] == "group", do: block["letter"]),
              optional: block["optional"] == true,
              ref: ref,
              milestone: id
            }
    end
  end

  defp resolve_ref(data, %{"lib" => "milestones", "id" => id}), do: find_milestone(data, id)

  defp resolve_ref(data, %{"lib" => "lists", "id" => id, "gift" => gift}) do
    case find_definition(data, "lists", id) do
      %{"gifts" => gifts} = list -> if gift in gifts, do: list
      nil -> nil
    end
  end

  defp resolve_ref(data, %{"lib" => lib, "id" => id}), do: find_definition(data, lib, id)

  def assignments(data, ref) do
    key = entry_key(ref)

    for milestone <- data["milestones"] || [], block <- milestone["blocks"] || [], Enum.any?(block_refs(block), &(entry_key(&1) == key)), into: %{} do
      {milestone["id"], block_placement(block)}
    end
  end

  defp block_placement(%{"type" => "group", "letter" => letter}), do: letter
  defp block_placement(%{"optional" => true}), do: "optional"
  defp block_placement(_block), do: nil

  def group_letters(milestone), do: for(%{"type" => "group", "letter" => letter} <- milestone["blocks"] || [], do: letter)

  def next_group_letter(milestone) do
    used = group_letters(milestone)
    Enum.find(Enum.map(?A..?Z, &<<&1>>), &(&1 not in used))
  end

  def group_min(milestone, letter) do
    case Enum.find(milestone["blocks"] || [], &(&1["type"] == "group" and &1["letter"] == letter)) do
      %{"min" => min} when is_integer(min) -> min
      _ -> 1
    end
  end

  def update_milestone(data, id, fun) do
    Map.update!(data, "milestones", fn milestones -> Enum.map(milestones, &if(&1["id"] == id, do: fun.(&1), else: &1)) end)
  end

  def add_entry(data, id, ref) do
    block = if pattern_ref?(ref), do: %{"type" => "entry", "ref" => ref, "optional" => true}, else: %{"type" => "entry", "ref" => ref}

    update_milestone(data, id, fn milestone ->
      if Enum.any?(milestone_refs(milestone), &(entry_key(&1) == entry_key(ref))),
        do: milestone,
        else: Map.put(milestone, "blocks", (milestone["blocks"] || []) ++ [block])
    end)
  end

  def pattern_ref?(%{"lib" => "lists", "gift" => gift}) when is_binary(gift), do: pattern_entry?(gift)
  def pattern_ref?(_ref), do: false

  def fixed_placement?(ref), do: ref["lib"] == "milestones" or pattern_ref?(ref)

  def remove_entry(data, id, ref), do: update_milestone(data, id, &drop_refs(&1, fn other -> entry_key(other) == entry_key(ref) end))

  def drop_refs_everywhere(data, drop?) do
    Map.update!(data, "milestones", fn milestones -> Enum.map(milestones, &drop_refs(&1, drop?)) end)
  end

  defp drop_refs(milestone, drop?) do
    blocks =
      Enum.flat_map(milestone["blocks"] || [], fn
        %{"type" => "group", "refs" => refs} = group ->
          case Enum.reject(refs, drop?) do
            [] -> []
            kept -> [%{group | "refs" => kept}]
          end

        %{"ref" => ref} = block ->
          if drop?.(ref), do: [], else: [block]
      end)

    Map.put(milestone, "blocks", blocks)
  end

  def set_entry_group(data, id, ref, group) do
    key = entry_key(ref)

    update_milestone(data, id, fn milestone ->
      blocks = milestone["blocks"] || []
      index = Enum.find_index(blocks, fn block -> Enum.any?(block_refs(block), &(entry_key(&1) == key)) end)
      current = index && block_placement(Enum.at(blocks, index))
      letter = if group == "new", do: next_group_letter(milestone), else: group

      if is_nil(index) or letter == current or (group == "new" and is_nil(letter)) or (ref["lib"] == "milestones" and letter != nil) or
           (pattern_ref?(ref) and letter != "optional") do
        milestone
      else
        stripped = drop_refs(milestone, &(entry_key(&1) == key))["blocks"]
        slot = if length(stripped) == length(blocks), do: index + 1, else: index

        blocks =
          cond do
            is_nil(letter) -> List.insert_at(stripped, slot, %{"type" => "entry", "ref" => ref})
            letter == "optional" -> List.insert_at(stripped, slot, %{"type" => "entry", "ref" => ref, "optional" => true})
            letter in group_letters(%{"blocks" => stripped}) -> Enum.map(stripped, &if(&1["letter"] == letter, do: Map.update!(&1, "refs", fn refs -> refs ++ [ref] end), else: &1))
            true -> List.insert_at(stripped, slot, %{"type" => "group", "letter" => letter, "min" => 1, "refs" => [ref]})
          end

        Map.put(milestone, "blocks", blocks)
      end
    end)
  end

  def move_entry(data, id, key, letter, keys) do
    case find_milestone(data, id) && Enum.find(milestone_refs(find_milestone(data, id)), &(entry_key(&1) == key)) do
      nil ->
        data

      ref ->
        if is_binary(letter) and fixed_placement?(ref) do
          data
        else
          data
          |> update_milestone(id, fn milestone ->
            stripped = drop_refs(milestone, &(entry_key(&1) == key))

            blocks =
              if letter in group_letters(stripped),
                do: Enum.map(stripped["blocks"], &if(&1["letter"] == letter, do: Map.update!(&1, "refs", fn refs -> refs ++ [ref] end), else: &1)),
                else: stripped["blocks"] ++ [%{"type" => "entry", "ref" => ref}]

            Map.put(stripped, "blocks", blocks)
          end)
          |> then(&if(letter, do: reorder_group(&1, id, letter, keys), else: reorder_blocks(&1, id, keys)))
        end
    end
  end

  def set_group_min(data, id, letter, min) do
    update_milestone(data, id, fn milestone ->
      Map.update(milestone, "blocks", [], fn blocks ->
        Enum.map(blocks, &if(&1["type"] == "group" and &1["letter"] == letter, do: Map.put(&1, "min", max(min, 1)), else: &1))
      end)
    end)
  end

  def reorder_blocks(data, id, keys) do
    update_milestone(data, id, fn milestone -> Map.update(milestone, "blocks", [], &reorder_by_keys(&1, keys, fn block -> block_key(block) end)) end)
  end

  def reorder_group(data, id, letter, keys) do
    update_milestone(data, id, fn milestone ->
      Map.update(milestone, "blocks", [], fn blocks ->
        Enum.map(blocks, &if(&1["type"] == "group" and &1["letter"] == letter, do: Map.update!(&1, "refs", fn refs -> reorder_by_keys(refs, keys, fn ref -> entry_key(ref) end) end), else: &1))
      end)
    end)
  end

  defp reorder_by_keys(items, keys, key_fun) do
    by_key = Map.new(items, &{key_fun.(&1), &1})
    ordered = keys |> Enum.map(&by_key[&1]) |> Enum.reject(&is_nil/1)
    ordered ++ Enum.reject(items, &(&1 in ordered))
  end

  def remove_milestone(data, id) do
    data
    |> Map.update!("milestones", fn milestones -> Enum.reject(milestones, &(&1["id"] == id)) end)
    |> drop_refs_everywhere(&(&1["lib"] == "milestones" and &1["id"] == id))
  end

  defp entry_configured?(%{lib: "fusions", definition: definition}), do: is_binary(definition["target"])
  defp entry_configured?(%{lib: "upties", definition: definition}), do: is_binary(definition["gift"])
  defp entry_configured?(_entry), do: true

  def entry_status(data, %{lib: "milestones", definition: milestone}, env), do: if(milestone_reached?(data, milestone["id"], env), do: :done, else: :open)

  def entry_status(_data, %{lib: "fusions", definition: definition}, env) do
    cond do
      fusion_done?(definition, Map.get(env, :owned, MapSet.new())) -> :done
      fixed_fusion?(definition) and ingredient_owned?(definition, env) -> :partial
      true -> :open
    end
  end

  def entry_status(_data, %{lib: "upties", definition: definition}, env) do
    inventory = Map.get(env, :inventory, %{})

    cond do
      uptie_done?(definition, inventory) -> :done
      Enum.any?(inventory, fn {_id, entry} -> entry.name == definition["gift"] end) -> :partial
      true -> :open
    end
  end

  def entry_status(_data, %{lib: "lists", gift: gift}, env), do: if(MapSet.member?(Map.get(env, :owned, MapSet.new()), gift), do: :done, else: :open)

  defp ingredient_owned?(definition, env) do
    case Map.get(env, :gifts, %{})[definition["target"]] do
      nil -> false
      target -> Enum.any?(ingredient_ids(target), &Map.has_key?(Map.get(env, :inventory, %{}), &1))
    end
  end

  def entry_needed?(_data, %{optional: true}, _env), do: false

  def entry_needed?(data, entry, env) do
    entry_configured?(entry) and
      case entry_status(data, entry, env) do
        :done -> false
        :partial -> true
        :open -> is_nil(entry.group) or group_committed(data, entry.milestone, entry.group, env) < group_min(find_milestone(data, entry.milestone), entry.group)
      end
  end

  defp group_committed(data, id, letter, env) do
    data
    |> milestone_entries(id)
    |> Enum.filter(&(&1.group == letter and entry_configured?(&1)))
    |> Enum.count(&(entry_status(data, &1, env) != :open))
  end

  defp group_ok?(entries, milestone, letter, data, env) do
    statuses = entries |> Enum.filter(&entry_configured?/1) |> Enum.map(&entry_status(data, &1, env))
    :partial not in statuses and Enum.count(statuses, &(&1 == :done)) >= group_min(milestone, letter)
  end

  def work_entries(data, id), do: data |> collect_work(id, []) |> Enum.uniq_by(&entry_key(&1.ref))

  defp collect_work(data, id, stack) do
    if id in stack do
      []
    else
      entries = milestone_entries(data, id)
      {subs, own} = Enum.split_with(entries, &(&1.lib == "milestones"))
      Enum.flat_map(subs, &collect_work(data, &1.definition["id"], [id | stack])) ++ own
    end
  end

  def called_milestones(milestone) do
    conditions = for %{"op" => "milestone", "milestone" => id} <- Conditions.leaves(milestone["condition"]), is_binary(id), do: id
    included = for %{"lib" => "milestones", "id" => id} <- milestone_refs(milestone), do: id
    Enum.uniq(conditions ++ included)
  end

  def reachable_milestones(data, id), do: reach_milestones(data, called_milestones(find_milestone(data, id) || %{}), MapSet.new())

  defp reach_milestones(_data, [], seen), do: seen

  defp reach_milestones(data, [id | rest], seen) do
    if MapSet.member?(seen, id) do
      reach_milestones(data, rest, seen)
    else
      next = called_milestones(find_milestone(data, id) || %{})
      reach_milestones(data, next ++ rest, MapSet.put(seen, id))
    end
  end

  def milestone_cycle?(data, host_id, child_id), do: child_id == host_id or MapSet.member?(reachable_milestones(data, child_id), host_id)

  def milestone_reached?(data, id, env) do
    stack = Map.get(env, :milestone_stack, [])

    case find_milestone(data, id) do
      nil ->
        false

      milestone ->
        if id in stack do
          false
        else
          env = Map.put(env, :milestone_stack, [id | stack])

          data
          |> milestone_entries(id)
          |> Enum.reject(& &1.optional)
          |> Enum.group_by(& &1.group)
          |> Enum.all?(fn
            {nil, entries} -> entries |> Enum.filter(&entry_configured?/1) |> Enum.all?(&(entry_status(data, &1, env) == :done))
            {letter, entries} -> group_ok?(entries, milestone, letter, data, env)
          end) and eval_condition(milestone["condition"], env)
        end
    end
  end

  def new_definition("lists", name), do: %{"id" => new_id("ls"), "name" => name, "gifts" => []}

  def new_definition("upties", name) do
    %{"id" => new_id("up"), "name" => name, "gift" => nil, "target_level" => 2}
  end

  def new_definition("fusions", name), do: new_definition("fusions", name, "tiered")

  def new_definition("fusions", name, "fixed") do
    %{"id" => new_id("fu"), "name" => name, "type" => "fixed", "target" => nil, "buy_missing" => true, "sub_fusions" => %{}}
  end

  def new_definition("fusions", name, "tiered") do
    %{"id" => new_id("fu"), "name" => name, "type" => "tiered", "target" => nil, "routes" => []}
  end

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

  defp step_defaults("uptie", data), do: %{"upties" => List.wrap(first_id(data, "upties")), "max_gifts" => 1}
  defp step_defaults("fusion", data), do: %{"fusions" => List.wrap(first_id(data, "fusions"))}
  defp step_defaults("buy_list", data), do: %{"list" => first_id(data, "lists"), "done_at" => nil}
  defp step_defaults("refresh", _data), do: %{}
  defp step_defaults("affinity_refresh", data), do: %{"affinity" => data["affinity"]}
  defp step_defaults("sell", _data), do: %{"tiers" => [1], "list" => nil, "stop_at_cost" => nil, "max_items" => 1}
  defp step_defaults("skill_replace", _data), do: %{"sinner" => nil, "options" => @skill_options}
  defp step_defaults("heal", _data), do: %{"sinner" => nil}
  defp step_defaults("heal_all", _data), do: %{}
  defp step_defaults("revive", _data), do: %{"sinner" => nil}
  defp step_defaults("budget", _data), do: %{"amount" => 0}
  defp step_defaults("workflow", _data), do: %{"workflow" => nil}
  defp step_defaults("bail", _data), do: %{}
  defp step_defaults("leave", _data), do: %{}

  defp first_id(data, lib) do
    case data["library"][lib] do
      [%{"id" => id} | _] -> id
      _ -> nil
    end
  end

  def tier_entry(tier), do: "tier:#{tier}"

  def parse_tier_entry("tier:" <> tier) do
    case Integer.parse(tier) do
      {tier, ""} -> tier
      _ -> nil
    end
  end

  def parse_tier_entry(_entry), do: nil

  def affinity_entry(affinity, tiers) do
    case tiers |> Enum.uniq() |> Enum.sort() do
      [] -> "affinity:#{affinity}"
      tiers -> "affinity:#{affinity}:#{Enum.join(tiers, ",")}"
    end
  end

  def parse_affinity_entry("affinity:" <> rest) do
    case String.split(rest, ":") do
      [affinity] -> {affinity, []}
      [affinity, tiers] -> {affinity, tiers |> String.split(",", trim: true) |> Enum.map(&String.to_integer/1)}
    end
  end

  def parse_affinity_entry(_entry), do: nil

  def pattern_entry?(entry), do: not is_nil(parse_tier_entry(entry)) or not is_nil(parse_affinity_entry(entry))

  def entry_matches?(entry, gift) do
    case {parse_tier_entry(entry), parse_affinity_entry(entry)} do
      {tier, nil} when is_integer(tier) -> tier == Map.get(gift, :tier)
      {nil, {affinity, tiers}} -> Map.get(gift, :affinity) == affinity and (tiers == [] or Map.get(gift, :tier) in tiers)
      {nil, nil} -> entry == gift.name
    end
  end

  def entry_label(entry) do
    case {parse_tier_entry(entry), parse_affinity_entry(entry)} do
      {tier, nil} when is_integer(tier) -> "Any T#{tier}"
      {nil, {affinity, []}} -> "Any #{affinity}"
      {nil, {affinity, tiers}} -> "Any #{affinity} " <> Enum.map_join(tiers, ", ", &"T#{&1}")
      {nil, nil} -> entry
    end
  end

  def list_rank(entries, gift), do: Enum.find_index(entries, &entry_matches?(&1, gift))

  def list_owned_count(entries, owned_gifts), do: Enum.count(owned_gifts, &list_rank(entries, &1))

  def list_remaining(list, done_at, owned_gifts) when is_integer(done_at) do
    max(done_at - list_owned_count(list["gifts"], owned_gifts), 0)
  end

  def list_remaining(_list, _done_at, _owned_gifts), do: nil

  def find_definition(data, lib, id), do: Enum.find(data["library"][lib] || [], &(&1["id"] == id))

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

  def definition_for(data, %{"kind" => "sell", "list" => id}) when is_binary(id), do: resolve_refs(data, "lists", id)
  def definition_for(_data, %{"kind" => "sell"}), do: {:ok, nil}

  def definition_for(data, %{"kind" => kind} = step) do
    case library_ref(kind) do
      {lib, field} -> resolve_refs(data, lib, step[field])
      nil -> {:ok, nil}
    end
  end

  defp resolve_refs(_data, _lib, []), do: {:error, :no_definitions}

  defp resolve_refs(data, lib, ids) when is_list(ids) do
    definitions = Enum.map(ids, &find_definition(data, lib, &1))
    if nil in definitions, do: {:error, :missing_definition}, else: {:ok, definitions}
  end

  defp resolve_refs(data, lib, id) do
    case find_definition(data, lib, id) do
      nil -> {:error, :missing_definition}
      definition -> {:ok, definition}
    end
  end

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

    {data, ref_map} =
      workflows
      |> Enum.flat_map(&workflow_refs/1)
      |> Enum.reduce({data, %{}}, fn {lib, id}, acc -> import_definition(acc, source, lib, id) end)

    imported =
      Enum.map(workflows, fn workflow ->
        name = if MapSet.member?(taken, workflow["name"]), do: "#{workflow["name"]} (#{source_name})", else: workflow["name"]

        %{
          workflow
          | "id" => wf_map[workflow["id"]],
            "name" => name,
            "steps" => Enum.map(workflow["steps"], &remap_tree(&1, wf_map, ref_map))
        }
        |> Map.put("keep", ref_map[{"lists", workflow["keep"]}])
      end)

    Map.update!(data, "workflows", &(&1 ++ imported))
  end

  defp workflow_refs(workflow) do
    keep = if workflow["keep"], do: [{"lists", workflow["keep"]}], else: []

    keep ++
      Enum.flat_map(all_steps(workflow["steps"]), fn step ->
        case library_ref(step["kind"]) do
          {lib, field} -> for id <- List.wrap(step[field]), is_binary(id), do: {lib, id}
          nil -> []
        end
      end)
  end

  defp import_definition({data, ref_map} = acc, source, lib, id) do
    cond do
      Map.has_key?(ref_map, {lib, id}) ->
        acc

      is_nil(find_definition(source, lib, id)) ->
        acc

      true ->
        definition = find_definition(source, lib, id)

        case Enum.find(data["library"][lib] || [], &(&1["name"] == definition["name"])) do
          %{"id" => existing} ->
            {data, Map.put(ref_map, {lib, id}, existing)}

          nil ->
            copy_id = new_id(id_prefix(lib))
            acc = {data, Map.put(ref_map, {lib, id}, copy_id)}
            subs = if lib == "fusions", do: Map.values(definition["sub_fusions"] || %{}), else: []
            {data, ref_map} = Enum.reduce(subs, acc, &import_definition(&2, source, "fusions", &1))
            copy = remap_sub_fusions(%{definition | "id" => copy_id}, ref_map)
            {update_in(data, ["library", lib], &((&1 || []) ++ [copy])), ref_map}
        end
    end
  end

  defp remap_sub_fusions(%{"sub_fusions" => subs} = definition, ref_map) when is_map(subs) do
    Map.put(definition, "sub_fusions", for({name, id} <- subs, ref_map[{"fusions", id}], into: %{}, do: {name, ref_map[{"fusions", id}]}))
  end

  defp remap_sub_fusions(definition, _ref_map), do: definition

  defp remap_step(%{"kind" => "workflow"} = step, wf_map, _ref_map), do: %{step | "id" => new_id("st"), "workflow" => wf_map[step["workflow"]]}

  defp remap_step(step, _wf_map, ref_map) do
    step = Map.put(step, "id", new_id("st"))

    case library_ref(step["kind"]) do
      {lib, field} -> Map.update(step, field, nil, &remap_ref(&1, lib, ref_map))
      nil -> step
    end
  end

  defp remap_tree(step, wf_map, ref_map) do
    step
    |> remap_step(wf_map, ref_map)
    |> remap_between(wf_map)
    |> update_branches(&Enum.map(&1, fn child -> remap_tree(child, wf_map, ref_map) end))
  end

  defp remap_between(%{"between" => id} = step, wf_map) when is_binary(id), do: %{step | "between" => wf_map[id]}
  defp remap_between(step, _wf_map), do: step

  defp remap_ref(ids, lib, ref_map) when is_list(ids), do: for(id <- ids, ref_map[{lib, id}], do: ref_map[{lib, id}])
  defp remap_ref(id, lib, ref_map), do: ref_map[{lib, id}]

  defp id_prefix("lists"), do: "ls"
  defp id_prefix("upties"), do: "up"
  defp id_prefix("fusions"), do: "fu"

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

  def keep_gifts(data, workflow) do
    case find_definition(data, "lists", workflow["keep"]) do
      nil -> []
      keep -> keep["gifts"]
    end
  end

  def derived_protected(data, workflow, gifts) do
    gifts_by_name = Map.new(gifts, &{&1.name, &1})
    gifts_by_id = Map.new(gifts, &{&1.id, &1})

    data
    |> expand_steps(workflow)
    |> Enum.flat_map(&step_protected(&1, data, gifts_by_name, gifts_by_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp step_protected(%{"kind" => "fusion"} = step, data, by_name, by_id) do
    case definition_for(data, step) do
      {:ok, definitions} -> Enum.flat_map(definitions, &fusion_protected(&1, data, by_name, by_id, []))
      _ -> []
    end
  end

  defp step_protected(%{"kind" => "uptie"} = step, data, _by_name, _by_id) do
    for id <- step["upties"] || [], definition = find_definition(data, "upties", id), do: definition["gift"]
  end

  defp step_protected(%{"kind" => "milestone", "milestone" => id}, data, by_name, by_id) when is_binary(id) do
    data
    |> work_entries(id)
    |> Enum.flat_map(fn
      %{lib: "fusions", definition: definition} -> fusion_protected(definition, data, by_name, by_id, [])
      %{lib: "upties", definition: definition} -> [definition["gift"]]
      %{lib: "lists", gift: gift} -> if(pattern_entry?(gift), do: [], else: [gift])
    end)
  end

  defp step_protected(_step, _data, _by_name, _by_id), do: []

  defp fusion_protected(%{"type" => "fixed"} = definition, data, by_name, by_id, seen) do
    if definition["id"] in seen do
      []
    else
      subs =
        for {_ingredient, id} <- definition["sub_fusions"] || %{},
            sub = find_definition(data, "fusions", id),
            name <- fusion_protected(sub, data, by_name, by_id, [definition["id"] | seen]),
            do: name

      [definition["target"] | ingredient_names(by_name[definition["target"]], by_id)] ++ subs
    end
  end

  defp fusion_protected(definition, _data, _by_name, _by_id, _seen), do: [definition["target"]]

  def ingredient_names(gift, by_id), do: gift |> ingredient_ids() |> Enum.map(&(by_id[&1] && by_id[&1].name))

  def fixed_fusion?(definition), do: definition["type"] == "fixed"

  def protected_set(data, workflow, gifts) do
    MapSet.new(keep_gifts(data, workflow) ++ derived_protected(data, workflow, gifts))
  end

  def protected?(protected, gift), do: MapSet.member?(protected, gift.name) or Enum.any?(protected, &(is_binary(&1) and pattern_entry?(&1) and entry_matches?(&1, gift)))

  def ingredient_ids(%{ingredients: ingredients}) when is_binary(ingredients) and ingredients != "" do
    ingredients |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

  def ingredient_ids(_gift), do: []

  def uptie_cost(tier, from, to) do
    case Map.get(@uptie_step_costs, tier) do
      nil -> nil
      steps -> steps |> Enum.slice(from, to - from) |> Enum.sum()
    end
  end

  def fodder(owned, protected, gifts_by_id) do
    for {id, %{uptie: uptie, count: count}} <- owned,
        gift = gifts_by_id[id],
        gift && gift.tier in 1..4 && (uptie || 0) < 1 && not protected?(protected, gift),
        _copy <- 1..count//1 do
      %{id: id, name: gift.name, tier: gift.tier, affinity: Map.get(gift, :affinity), uptie: uptie, selling_cost: gift.selling_cost || 0}
    end
  end

  def sell_order(fodder, tiers) do
    rank = tiers |> Enum.with_index() |> Map.new()

    fodder
    |> Enum.filter(&Map.has_key?(rank, &1.tier))
    |> Enum.sort_by(&{rank[&1.tier], -&1.selling_cost, &1.name})
  end

  def chance_comet?(data), do: Enum.any?(data["grace_picks"] || [], &match?(%{"index" => @chance_comet}, &1))

  def list_sell_order(fodder, entries) do
    fodder
    |> Enum.map(&{&1, list_rank(entries, &1)})
    |> Enum.reject(fn {_gift, rank} -> is_nil(rank) end)
    |> Enum.sort_by(fn {gift, rank} -> {rank, -gift.selling_cost, gift.name} end)
    |> Enum.map(fn {gift, _rank} -> gift end)
  end

  def sell_plan(queue, needed, max_items) do
    queue
    |> Enum.take(max_items)
    |> Enum.reduce_while({[], 0}, fn gift, {picked, total} ->
      if is_integer(needed) and total >= needed,
        do: {:halt, {picked, total}},
        else: {:cont, {picked ++ [gift], total + gift.selling_cost}}
    end)
  end

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
  defp eval_leaf(%{"op" => "fusions_complete"}, %{plan: plan, owned: owned}), do: fusions_complete?(plan, owned)
  defp eval_leaf(%{"op" => "upties_complete"}, %{plan: plan, inventory: inventory}), do: upties_complete?(plan, inventory)
  defp eval_leaf(%{"op" => "fusion_done"} = leaf, %{plan: plan, owned: owned}), do: fusion_done?(find_definition(plan, "fusions", leaf["fusion"]), owned)
  defp eval_leaf(%{"op" => "uptie_done"} = leaf, %{plan: plan, inventory: inventory}), do: uptie_done?(find_definition(plan, "upties", leaf["uptie"]), inventory)
  defp eval_leaf(%{"op" => "milestone"} = leaf, %{plan: plan} = env), do: milestone_reached?(plan, leaf["milestone"], env)

  def fusions_complete?(data, owned) do
    fusions = data["library"]["fusions"]
    sub_ids = MapSet.new(Enum.flat_map(fusions, &Map.values(&1["sub_fusions"] || %{})))

    fusions
    |> Enum.reject(&(MapSet.member?(sub_ids, &1["id"]) or is_nil(&1["target"])))
    |> Enum.all?(&fusion_done?(&1, owned))
  end

  def upties_complete?(data, inventory) do
    data["library"]["upties"]
    |> Enum.reject(&is_nil(&1["gift"]))
    |> Enum.all?(&uptie_done?(&1, inventory))
  end

  def fusion_done?(%{"target" => target}, owned) when is_binary(target), do: MapSet.member?(owned, target)
  def fusion_done?(_definition, _owned), do: false

  def uptie_done?(%{"gift" => gift, "target_level" => target}, inventory) when is_binary(gift) do
    Enum.any?(inventory, fn {_id, entry} -> entry.name == gift and entry.uptie >= target end)
  end

  def uptie_done?(_definition, _inventory), do: false

  def prune_condition(node), do: Conditions.prune(node)

  def condition_label(node, data \\ nil), do: Conditions.label(node, &leaf_label(&1, data))

  defp leaf_label(%{"op" => "cost_gte", "value" => value}, _data), do: "cost >= #{value}"
  defp leaf_label(%{"op" => "cost_lt", "value" => value}, _data), do: "cost < #{value}"
  defp leaf_label(%{"op" => "refreshes_lt", "value" => value}, _data), do: "refreshes < #{value}"
  defp leaf_label(%{"op" => "refreshes_gte", "value" => value}, _data), do: "refreshes >= #{value}"
  defp leaf_label(%{"op" => "has_gift", "gift" => gift}, _data), do: "owns #{gift}"
  defp leaf_label(%{"op" => "missing_gift", "gift" => gift}, _data), do: "missing #{gift}"
  defp leaf_label(%{"op" => "fusions_complete"}, _data), do: "all fusions complete"
  defp leaf_label(%{"op" => "upties_complete"}, _data), do: "all upties complete"
  defp leaf_label(%{"op" => "fusion_done"} = leaf, data), do: "fusion #{definition_name(data, "fusions", leaf["fusion"])} done"
  defp leaf_label(%{"op" => "uptie_done"} = leaf, data), do: "uptie #{definition_name(data, "upties", leaf["uptie"])} done"
  defp leaf_label(%{"op" => "milestone"} = leaf, data), do: "milestone #{milestone_name(data, leaf["milestone"])} reached"

  defp milestone_name(_data, nil), do: "(none picked)"
  defp milestone_name(nil, id), do: id

  defp milestone_name(data, id) do
    case find_milestone(data, id) do
      nil -> "(deleted)"
      milestone -> milestone["name"]
    end
  end

  defp definition_name(_data, _lib, nil), do: "(none picked)"
  defp definition_name(nil, _lib, id), do: id

  defp definition_name(data, lib, id) do
    case find_definition(data, lib, id) do
      nil -> "(deleted)"
      definition -> definition["name"]
    end
  end

  def kind_label("if"), do: "If"
  def kind_label("milestone"), do: "Work on Milestone"
  def kind_label("uptie"), do: "Uptie"
  def kind_label("fusion"), do: "Fusion"
  def kind_label("buy_list"), do: "Buy from list"
  def kind_label("refresh"), do: "Refresh"
  def kind_label("affinity_refresh"), do: "Affinity Refresh"
  def kind_label("sell"), do: "Sell"
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

  defp step_subject(data, %{"kind" => kind} = step) when kind in ["uptie", "fusion", "buy_list"] do
    case definition_for(data, step) do
      {:ok, definitions} when is_list(definitions) -> Enum.map_join(definitions, " › ", & &1["name"])
      {:ok, definition} -> definition["name"]
      {:error, :missing_definition} -> "(missing definition)"
      {:error, :no_definitions} -> "(none selected)"
    end
  end

  defp step_subject(data, %{"kind" => "sell"} = step) do
    case definition_for(data, step) do
      {:ok, nil} -> nil
      {:ok, list} -> list["name"]
      {:error, :missing_definition} -> "(missing definition)"
    end
  end

  defp step_subject(_data, %{"kind" => "affinity_refresh"} = step), do: step["affinity"] || "(no affinity)"
  defp step_subject(_data, %{"kind" => "skill_replace"} = step), do: step["sinner"] || "(no sinner)"
  defp step_subject(_data, %{"kind" => kind} = step) when kind in ["heal", "revive"], do: step["sinner"] || "(no sinner)"
  defp step_subject(_data, %{"kind" => "budget", "amount" => amount}) when amount >= 0, do: "+#{amount}"
  defp step_subject(_data, %{"kind" => "budget", "amount" => amount}), do: "#{amount}"
  defp step_subject(_data, _step), do: nil

  def issues(data, gifts_by_name \\ %{}) do
    schedule_issues(data) ++
      gift_search_issues(data, gifts_by_name) ++
      Enum.flat_map(data["workflows"], &workflow_issues(data, &1)) ++
      Enum.flat_map(data["library"]["fusions"], &fusion_issues(data, &1, gifts_by_name)) ++
      Enum.flat_map(data["milestones"] || [], &milestone_issues(data, &1))
  end

  defp milestone_issues(data, milestone) do
    refs =
      for id <- called_milestones(milestone) do
        case find_milestone(data, id) do
          nil -> "Milestone #{milestone["name"]}: uses a deleted milestone."
          other -> if milestone_cycle?(data, milestone["id"], id), do: "Milestone #{milestone["name"]}: depends on #{other["name"]}, which leads back to it."
        end
      end

    groups =
      for %{"type" => "group", "letter" => letter, "refs" => refs} <- milestone["blocks"] || [], group_min(milestone, letter) > length(refs) do
        "Milestone #{milestone["name"]}: group #{letter} needs #{group_min(milestone, letter)} but only has #{length(refs)}."
      end

    Enum.reject(refs, &is_nil/1) ++ groups
  end

  defp fusion_issues(data, %{"type" => "fixed"} = fusion, gifts_by_name) do
    by_id = Map.new(gifts_by_name, fn {_name, gift} -> {gift.id, gift} end)

    case gifts_by_name[fusion["target"]] do
      nil ->
        []

      target ->
        ingredients = ingredient_names(target, by_id)

        no_recipe = if ingredients == [], do: ["#{fusion["name"]}: #{target.name} has no fixed recipe."], else: []

        subs =
          for {ingredient, id} <- fusion["sub_fusions"] || %{} do
            case find_definition(data, "fusions", id) do
              nil -> "#{fusion["name"]}: the sub-fusion for #{ingredient} was deleted."
              %{"target" => ^ingredient} -> nil
              sub -> "#{fusion["name"]}: the sub-fusion for #{ingredient} (#{sub["name"]}) targets #{sub["target"] || "nothing"}."
            end
          end

        no_recipe ++ Enum.reject(subs, &is_nil/1)
    end
  end

  defp fusion_issues(_data, fusion, gifts_by_name) do
    case gifts_by_name[fusion["target"]] do
      %{tier: tier} ->
        case Routes.invalid_count(fusion["routes"] || [], tier) do
          0 -> []
          n -> ["#{fusion["name"]}: #{n} route(s) use a combo that can't make that tier."]
        end

      nil ->
        []
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
    keep =
      if find_definition(data, "lists", workflow["keep"]),
        do: [],
        else: ["#{workflow["name"]}: no keep list selected."]

    broken =
      workflow["steps"]
      |> numbered_steps("")
      |> Enum.flat_map(fn {step, i} ->
        prefix = "#{workflow["name"]}: step #{i} (#{kind_label(step["kind"])})"

        case {step["kind"], definition_for(data, step)} do
          {"workflow", {:error, :missing_definition}} -> ["#{prefix} has no workflow selected, or it was deleted."]
          {"workflow", {:ok, sub}} ->
            if creates_cycle?(data, workflow["id"], sub["id"]), do: ["#{prefix} runs #{sub["name"]}, which leads back to #{workflow["name"]}."], else: []

          {_kind, {:error, :missing_definition}} -> ["#{prefix} references a deleted definition."]
          {_kind, {:error, :no_definitions}} -> ["#{prefix} has no definitions selected."]
          _ -> []
        end ++ between_issues(data, workflow, step, prefix)
      end)

    keep ++ broken
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
