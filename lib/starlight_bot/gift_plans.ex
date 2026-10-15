defmodule StarlightBot.GiftPlans do
  alias StarlightBot.GiftPlans.Routes

  @library_keys ~w(keep_lists upties tiered_fusions shopping_lists)
  @step_kinds ~w(uptie tiered_fusion buy_list fixed_fusion refresh affinity_refresh sell skill_replace heal heal_all revive budget)
  @library_refs %{
    "uptie" => {"upties", "upties"},
    "tiered_fusion" => {"tiered_fusions", "fusions"},
    "buy_list" => {"shopping_lists", "list"}
  }
  @skill_options ~w(s1_s3 s1_s2 s2_s3)
  @heal_cost 100
  @default_grace_indexes [0, 2, 3, 7]

  def library_keys, do: @library_keys
  def step_kinds, do: @step_kinds
  def skill_options, do: @skill_options
  def heal_cost, do: @heal_cost
  def library_ref(kind), do: Map.get(@library_refs, kind)

  def blank(affinity \\ nil) do
    keep = new_definition("keep_lists", "Keep")
    workflow = %{"id" => new_id("wf"), "name" => "Standard", "keep" => keep["id"], "steps" => []}

    %{
      "version" => 2,
      "affinity" => affinity,
      "grace_picks" => Enum.map(@default_grace_indexes, &%{"index" => &1, "enhance" => 0}),
      "library" => %{"keep_lists" => [keep], "upties" => [], "tiered_fusions" => [], "shopping_lists" => []},
      "workflows" => [workflow],
      "floor_schedule" => [%{"from_floor" => 1, "workflow" => workflow["id"]}]
    }
  end

  def normalize(%{"version" => 2} = data) do
    library = data["library"] || %{}

    %{
      "version" => 2,
      "affinity" => data["affinity"],
      "grace_picks" => data["grace_picks"] || [],
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

  def new_definition("tiered_fusions", name) do
    %{"id" => new_id("tf"), "name" => name, "target" => nil, "routes" => Routes.defaults(4)}
  end

  def new_step(kind, data) when kind in @step_kinds do
    %{"id" => new_id("st"), "kind" => kind, "enabled" => true, "condition" => nil}
    |> Map.merge(step_defaults(kind, data))
  end

  defp step_defaults("uptie", data), do: %{"upties" => List.wrap(first_id(data, "upties")), "max_gifts" => 1}
  defp step_defaults("tiered_fusion", data), do: %{"fusions" => List.wrap(first_id(data, "tiered_fusions"))}
  defp step_defaults("buy_list", data), do: %{"list" => first_id(data, "shopping_lists"), "max_items" => 1}
  defp step_defaults("fixed_fusion", _data), do: %{"target" => nil, "buy_missing" => true}
  defp step_defaults("refresh", _data), do: %{}
  defp step_defaults("affinity_refresh", data), do: %{"affinity" => data["affinity"]}
  defp step_defaults("sell", _data), do: %{"tiers" => [1], "stop_at_cost" => nil, "max_items" => 1}
  defp step_defaults("skill_replace", _data), do: %{"sinner" => nil, "options" => @skill_options}
  defp step_defaults("heal", _data), do: %{"sinner" => nil}
  defp step_defaults("heal_all", _data), do: %{}
  defp step_defaults("revive", _data), do: %{"sinner" => nil}
  defp step_defaults("budget", _data), do: %{"amount" => 0}

  defp first_id(data, lib) do
    case data["library"][lib] do
      [%{"id" => id} | _] -> id
      _ -> nil
    end
  end

  def find_definition(data, lib, id), do: Enum.find(data["library"][lib] || [], &(&1["id"] == id))

  def find_workflow(data, id), do: Enum.find(data["workflows"], &(&1["id"] == id))

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

    workflow["steps"]
    |> Enum.filter(&(&1["enabled"] != false))
    |> Enum.flat_map(&step_protected(&1, data, gifts_by_name, gifts_by_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp step_protected(%{"kind" => "tiered_fusion"} = step, data, _by_name, _by_id) do
    case definition_for(data, step) do
      {:ok, definitions} -> Enum.map(definitions, & &1["target"])
      _ -> []
    end
  end

  defp step_protected(%{"kind" => "fixed_fusion", "target" => target}, _data, by_name, by_id) do
    ingredient_names =
      by_name
      |> Map.get(target)
      |> ingredient_ids()
      |> Enum.map(&(by_id[&1] && by_id[&1].name))

    [target | ingredient_names]
  end

  defp step_protected(_step, _data, _by_name, _by_id), do: []

  def protected_set(data, workflow, gifts) do
    MapSet.new(keep_gifts(data, workflow) ++ derived_protected(data, workflow, gifts))
  end

  def ingredient_ids(%{ingredients: ingredients}) when is_binary(ingredients) and ingredients != "" do
    ingredients |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

  def ingredient_ids(_gift), do: []

  def eval_condition(nil, _env), do: true
  def eval_condition(%{"op" => "and", "children" => children}, env), do: Enum.all?(children, &eval_condition(&1, env))
  def eval_condition(%{"op" => "or", "children" => children}, env), do: Enum.any?(children, &eval_condition(&1, env))
  def eval_condition(%{"op" => "cost_gte", "value" => value}, %{wallet: wallet}), do: is_integer(wallet) and wallet >= value
  def eval_condition(%{"op" => "has_gift", "gift" => gift}, %{owned: owned}), do: MapSet.member?(owned, gift)
  def eval_condition(%{"op" => "missing_gift", "gift" => gift}, %{owned: owned}), do: not MapSet.member?(owned, gift)

  def prune_condition(%{"op" => op, "children" => children} = node) when op in ["and", "or"] do
    case children |> Enum.map(&prune_condition/1) |> Enum.reject(&is_nil/1) do
      [] -> nil
      kept -> %{node | "children" => kept}
    end
  end

  def prune_condition(node), do: node

  def condition_label(nil), do: nil
  def condition_label(node), do: node_label(node, true)

  defp node_label(%{"op" => op, "children" => children}, root?) do
    joined = Enum.map_join(children, " #{String.upcase(op)} ", &node_label(&1, false))
    if root? or length(children) == 1, do: joined, else: "(#{joined})"
  end

  defp node_label(%{"op" => "cost_gte", "value" => value}, _root?), do: "cost >= #{value}"
  defp node_label(%{"op" => "has_gift", "gift" => gift}, _root?), do: "owns #{gift}"
  defp node_label(%{"op" => "missing_gift", "gift" => gift}, _root?), do: "missing #{gift}"

  def kind_label("uptie"), do: "Uptie"
  def kind_label("tiered_fusion"), do: "Tiered Fusion"
  def kind_label("buy_list"), do: "Buy from list"
  def kind_label("fixed_fusion"), do: "Fixed Fusion"
  def kind_label("refresh"), do: "Refresh"
  def kind_label("affinity_refresh"), do: "Affinity Refresh"
  def kind_label("sell"), do: "Sell"
  def kind_label("skill_replace"), do: "Skill Replace"
  def kind_label("heal"), do: "Heal Sinner"
  def kind_label("heal_all"), do: "Heal All"
  def kind_label("revive"), do: "Revive"
  def kind_label("budget"), do: "Budget"

  def step_label(data, %{"kind" => kind} = step) do
    case step_subject(data, step) do
      nil -> kind_label(kind)
      subject -> "#{kind_label(kind)} · #{subject}"
    end
  end

  defp step_subject(data, %{"kind" => kind} = step) when kind in ["uptie", "tiered_fusion", "buy_list"] do
    case definition_for(data, step) do
      {:ok, definitions} when is_list(definitions) -> Enum.map_join(definitions, " › ", & &1["name"])
      {:ok, definition} -> definition["name"]
      {:error, :missing_definition} -> "(missing definition)"
      {:error, :no_definitions} -> "(none selected)"
    end
  end

  defp step_subject(_data, %{"kind" => "fixed_fusion"} = step), do: step["target"] || "(no target)"
  defp step_subject(_data, %{"kind" => "affinity_refresh"} = step), do: step["affinity"] || "(no affinity)"
  defp step_subject(_data, %{"kind" => "skill_replace"} = step), do: step["sinner"] || "(no sinner)"
  defp step_subject(_data, %{"kind" => kind} = step) when kind in ["heal", "revive"], do: step["sinner"] || "(no sinner)"
  defp step_subject(_data, %{"kind" => "budget", "amount" => amount}) when amount >= 0, do: "+#{amount}"
  defp step_subject(_data, %{"kind" => "budget", "amount" => amount}), do: "#{amount}"
  defp step_subject(_data, _step), do: nil

  def issues(data, gifts_by_name \\ %{}) do
    schedule_issues(data) ++
      Enum.flat_map(data["workflows"], &workflow_issues(data, &1)) ++
      Enum.flat_map(data["library"]["tiered_fusions"], &fusion_issues(&1, gifts_by_name))
  end

  defp fusion_issues(fusion, gifts_by_name) do
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

        case definition_for(data, step) do
          {:error, :missing_definition} -> ["#{prefix} references a deleted definition."]
          {:error, :no_definitions} -> ["#{prefix} has no definitions selected."]
          _ -> []
        end
      end)

    keep ++ broken
  end
end
