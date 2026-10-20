defmodule StarlightBot.GiftPlans do
  alias StarlightBot.Conditions
  alias StarlightBot.GiftPlans.Routes

  @library_keys ~w(keep_lists upties fusions shopping_lists)
  @step_kinds ~w(uptie fusion buy_list refresh affinity_refresh sell skill_replace heal heal_all revive budget workflow bail leave)
  @library_refs %{
    "uptie" => {"upties", "upties"},
    "fusion" => {"fusions", "fusions"},
    "buy_list" => {"shopping_lists", "list"}
  }
  @skill_options ~w(s1_s3 s2_s3 s1_s2)
  @heal_cost 100
  @skill_replace_cost 50
  @uptie_step_costs %{1 => [50, 100], 2 => [60, 120], 3 => [75, 150], 4 => [100, 200]}
  @default_grace_indexes [0, 2, 3, 7]
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
    keep = new_definition("keep_lists", "Keep")
    workflow = %{"id" => new_id("wf"), "name" => "Standard", "keep" => keep["id"], "steps" => []}

    %{
      "version" => 2,
      "affinity" => affinity,
      "cabinet_gifts" => starting_gifts(affinity),
      "grace_picks" => Enum.map(@default_grace_indexes, &%{"index" => &1, "enhance" => 0}),
      "gift_search" => [],
      "library" => %{"keep_lists" => [keep], "upties" => [], "fusions" => [], "shopping_lists" => []},
      "workflows" => [workflow],
      "floor_schedule" => [%{"from_floor" => 1, "workflow" => workflow["id"]}]
    }
  end

  def normalize(%{"version" => 2} = data) do
    library = data["library"] || %{}

    %{
      "version" => 2,
      "affinity" => data["affinity"],
      "cabinet_gifts" => data["cabinet_gifts"] || [],
      "grace_picks" => data["grace_picks"] || [],
      "gift_search" => data["gift_search"] || [],
      "library" => Map.new(@library_keys, &{&1, library[&1] || []}),
      "workflows" => data["workflows"] || [],
      "floor_schedule" => data["floor_schedule"] || []
    }
  end

  def normalize(_data), do: blank()

  def new_id(prefix) do
    prefix <> "_" <> Base.encode32(:crypto.strong_rand_bytes(4), case: :lower, padding: false)
  end

  def new_definition("keep_lists", name), do: %{"id" => new_id("kp"), "name" => name, "gifts" => []}
  def new_definition("shopping_lists", name), do: %{"id" => new_id("sl"), "name" => name, "gifts" => []}

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

  defp step_defaults("uptie", data), do: %{"upties" => List.wrap(first_id(data, "upties")), "max_gifts" => 1}
  defp step_defaults("fusion", data), do: %{"fusions" => List.wrap(first_id(data, "fusions"))}
  defp step_defaults("buy_list", data), do: %{"list" => first_id(data, "shopping_lists"), "max_items" => 1}
  defp step_defaults("refresh", _data), do: %{}
  defp step_defaults("affinity_refresh", data), do: %{"affinity" => data["affinity"]}
  defp step_defaults("sell", _data), do: %{"tiers" => [1], "stop_at_cost" => nil, "max_items" => 1}
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

  def entry_label(entry) do
    case parse_tier_entry(entry) do
      nil -> entry
      tier -> "Any T#{tier}"
    end
  end

  def list_rank(entries, gift) do
    Enum.find_index(entries, fn entry ->
      case parse_tier_entry(entry) do
        nil -> entry == gift.name
        tier -> tier == gift.tier
      end
    end)
  end

  def list_owned_count(entries, owned_gifts), do: Enum.count(owned_gifts, &list_rank(entries, &1))

  def list_remaining(%{"done_at" => done_at} = list, owned_gifts) when is_integer(done_at) do
    max(done_at - list_owned_count(list["gifts"], owned_gifts), 0)
  end

  def list_remaining(_list, _owned_gifts), do: nil

  def find_definition(data, lib, id), do: Enum.find(data["library"][lib] || [], &(&1["id"] == id))

  def find_workflow(data, id), do: Enum.find(data["workflows"], &(&1["id"] == id))

  def definition_for(data, %{"kind" => "workflow"} = step) do
    case find_workflow(data, step["workflow"]) do
      nil -> {:error, :missing_definition}
      workflow -> {:ok, workflow}
    end
  end

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
    for %{"kind" => "workflow", "workflow" => id} <- workflow["steps"] || [], is_binary(id), uniq: true, do: id
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
            "steps" => Enum.map(workflow["steps"], &remap_step(&1, wf_map, ref_map))
        }
        |> Map.put("keep", ref_map[{"keep_lists", workflow["keep"]}])
      end)

    Map.update!(data, "workflows", &(&1 ++ imported))
  end

  defp workflow_refs(workflow) do
    keep = if workflow["keep"], do: [{"keep_lists", workflow["keep"]}], else: []

    keep ++
      Enum.flat_map(workflow["steps"], fn step ->
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

  defp remap_ref(ids, lib, ref_map) when is_list(ids), do: for(id <- ids, ref_map[{lib, id}], do: ref_map[{lib, id}])
  defp remap_ref(id, lib, ref_map), do: ref_map[{lib, id}]

  defp id_prefix("keep_lists"), do: "kp"
  defp id_prefix("shopping_lists"), do: "sl"
  defp id_prefix("upties"), do: "up"
  defp id_prefix("fusions"), do: "fu"

  def expand_steps(data, workflow), do: expand_steps(data, workflow, [workflow["id"]])

  defp expand_steps(data, workflow, stack) do
    workflow["steps"]
    |> Enum.filter(&(&1["enabled"] != false))
    |> Enum.flat_map(fn
      %{"kind" => "workflow", "workflow" => id} = step ->
        case find_workflow(data, id) do
          %{} = sub -> if id in stack, do: [], else: expand_steps(data, sub, [id | stack])
          nil -> [step]
        end

      step ->
        [step]
    end)
  end

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
    case find_definition(data, "keep_lists", workflow["keep"]) do
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
    for {id, %{uptie: uptie}} <- owned,
        gift = gifts_by_id[id],
        gift && gift.tier in 1..4 && (uptie || 0) < 1 && not MapSet.member?(protected, gift.name) do
      %{id: id, name: gift.name, tier: gift.tier, uptie: uptie, selling_cost: gift.selling_cost || 0}
    end
  end

  def sell_order(fodder, tiers) do
    rank = tiers |> Enum.with_index() |> Map.new()

    fodder
    |> Enum.filter(&Map.has_key?(rank, &1.tier))
    |> Enum.sort_by(&{rank[&1.tier], -&1.selling_cost, &1.name})
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
  defp eval_leaf(%{"op" => "has_gift", "gift" => gift}, %{owned: owned}), do: MapSet.member?(owned, gift)
  defp eval_leaf(%{"op" => "missing_gift", "gift" => gift}, %{owned: owned}), do: not MapSet.member?(owned, gift)
  defp eval_leaf(%{"op" => "fusions_complete"}, %{plan: plan, owned: owned}), do: fusions_complete?(plan, owned)
  defp eval_leaf(%{"op" => "upties_complete"}, %{plan: plan, inventory: inventory}), do: upties_complete?(plan, inventory)
  defp eval_leaf(%{"op" => "fusion_done"} = leaf, %{plan: plan, owned: owned}), do: fusion_done?(find_definition(plan, "fusions", leaf["fusion"]), owned)
  defp eval_leaf(%{"op" => "uptie_done"} = leaf, %{plan: plan, inventory: inventory}), do: uptie_done?(find_definition(plan, "upties", leaf["uptie"]), inventory)

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
  defp leaf_label(%{"op" => "has_gift", "gift" => gift}, _data), do: "owns #{gift}"
  defp leaf_label(%{"op" => "missing_gift", "gift" => gift}, _data), do: "missing #{gift}"
  defp leaf_label(%{"op" => "fusions_complete"}, _data), do: "all fusions complete"
  defp leaf_label(%{"op" => "upties_complete"}, _data), do: "all upties complete"
  defp leaf_label(%{"op" => "fusion_done"} = leaf, data), do: "fusion #{definition_name(data, "fusions", leaf["fusion"])} done"
  defp leaf_label(%{"op" => "uptie_done"} = leaf, data), do: "uptie #{definition_name(data, "upties", leaf["uptie"])} done"

  defp definition_name(_data, _lib, nil), do: "(none picked)"
  defp definition_name(nil, _lib, id), do: id

  defp definition_name(data, lib, id) do
    case find_definition(data, lib, id) do
      nil -> "(deleted)"
      definition -> definition["name"]
    end
  end

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

  defp step_subject(data, %{"kind" => kind} = step) when kind in ["uptie", "fusion", "buy_list"] do
    case definition_for(data, step) do
      {:ok, definitions} when is_list(definitions) -> Enum.map_join(definitions, " › ", & &1["name"])
      {:ok, definition} -> definition["name"]
      {:error, :missing_definition} -> "(missing definition)"
      {:error, :no_definitions} -> "(none selected)"
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
      Enum.flat_map(data["library"]["fusions"], &fusion_issues(data, &1, gifts_by_name))
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
      if find_definition(data, "keep_lists", workflow["keep"]),
        do: [],
        else: ["#{workflow["name"]}: no keep list selected."]

    broken =
      workflow["steps"]
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {step, i} ->
        prefix = "#{workflow["name"]}: step #{i} (#{kind_label(step["kind"])})"

        case {step["kind"], definition_for(data, step)} do
          {"workflow", {:error, :missing_definition}} -> ["#{prefix} has no workflow selected, or it was deleted."]
          {"workflow", {:ok, sub}} ->
            if creates_cycle?(data, workflow["id"], sub["id"]), do: ["#{prefix} runs #{sub["name"]}, which leads back to #{workflow["name"]}."], else: []

          {_kind, {:error, :missing_definition}} -> ["#{prefix} references a deleted definition."]
          {_kind, {:error, :no_definitions}} -> ["#{prefix} has no definitions selected."]
          _ -> []
        end
      end)

    keep ++ broken
  end
end
