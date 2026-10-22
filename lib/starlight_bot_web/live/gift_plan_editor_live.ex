defmodule StarlightBotWeb.Live.GiftPlanEditorLive do
  use StarlightBotWeb, :live_view
  import StarlightBotWeb.Components.ConditionTree
  import StarlightBotWeb.Components.PlanPicker

  alias StarlightBot.{Conditions, EgoGifts, GiftPlans, Plans, Teams}
  alias StarlightBot.GiftPlans.{Routes, RouteDefaults, Combos}

  embed_templates "gift_plan_editor/*"

  @tabs ~w(workflows shop grace gift_search)a
  @gift_tiers 1..6
  @affinities ~w(bleed blunt burn charge pierce poise rupture sinking slash tremor)
  @gift_sorts ~w(default name tier affinity)
  @uptie_views ~w(base uptie2 uptie3)
  @stat_codes %{"cp" => "Clash Power", "fc" => "Final Power", "bc" => "Base Power", "cg" => "Coin Count"}
  @palette_kinds ~w(if refresh affinity_refresh sell skill_replace heal heal_all revive budget bail leave)
  @library_kinds [{"upties", "uptie"}, {"fusions", "fusion"}, {"lists", "buy_list"}]
  @default_leaf %{"op" => "cost_gte", "value" => 0}

  @graces [
    %{index: 0, name: "Star of the Beginning", base_cost: 10,
      effects: %{
        0 => "Starting Cost +150. Theme Pack Selection +1. Shop E.G.O Gift Selection +1. One free Normal Refresh for Shops.",
        1 => "Starting Cost +250. Theme Pack Selection +1. Shop E.G.O Gift Selection +1. One free Normal Refresh for Shops.",
        2 => "Starting Cost +250. Theme Pack Selection +1. Shop E.G.O Gift Selection +1. Two free Normal Refreshes for Shops."
      }},
    %{index: 1, name: "Cumulating Starcloud", base_cost: 10,
      effects: %{
        0 => "On floor advance, current Cost balance +10% (max 100). E.G.O Gift sale price +50% (once per Shop).",
        1 => "On floor advance, current Cost balance +20% (max 125). E.G.O Gift sale price +75% (once per Shop).",
        2 => "On floor advance, current Cost balance +30% (max 150). E.G.O Gift sale price +100% (once per Shop)."
      }},
    %{index: 2, name: "Interstellar Travel", base_cost: 20,
      effects: %{
        0 => "Theme Pack Selection +1. Theme Pack Refresh Chance +2. First new Theme Pack choice grants all Identities +3 Level (max 9).",
        1 => "Theme Pack Selection +1. Theme Pack Refresh Chance +3. First new Theme Pack choice grants all Identities +3 Level (max 9). Gain 1 Clash Power Up in Floor 5 or lower combat.",
        2 => "Theme Pack Selection +1. Theme Pack Refresh Chance +4. First new Theme Pack choice grants all Identities +3 Level (max 9). Gain 3 Clash Power Up in Floor 5 or lower combat."
      }},
    %{index: 3, name: "Star-shower", base_cost: 20,
      effects: %{
        0 => "Starting Cost +400. Starting E.G.O Gift Choice +1.",
        1 => "Starting Cost +500. Starting E.G.O Gift Choice +1. Cost +75 when choosing Starlight from Encounter Rewards.",
        2 => "Starting Cost +700. Starting E.G.O Gift Choice +1. Cost +150 when choosing Starlight from Encounter Rewards."
      }},
    %{index: 4, name: "Binary Star-shop", base_cost: 30,
      effects: %{
        0 => "Shop E.G.O Gift Selection +1. Encounter Reward Cost +20%. Higher chance of high-tier E.G.O Gifts in Shops.",
        1 => "Shop E.G.O Gift Selection +1. Encounter Reward Cost +30%. Higher chance of high-tier E.G.O Gifts in Shops. On entering a Shop, gain Cost equal to the sum of owned E.G.O Gift tiers (max 75).",
        2 => "Shop E.G.O Gift Selection +1. Encounter Reward Cost +40%. Higher chance of high-tier E.G.O Gifts in Shops. On entering a Shop, gain Cost equal to the sum of owned E.G.O Gift tiers (max 150)."
      }},
    %{index: 5, name: "Moon Star-shop", base_cost: 30,
      effects: %{
        0 => "One free Keyword Refresh for Shops. On entering Floor 1, gain 1 random Tier 1 E.G.O Gift.",
        1 => "One free Keyword Refresh for Shops. On entering Floor 1, gain 2 random Tier 1 E.G.O Gifts. +10% chance for a Super Shop to appear.",
        2 => "Two free Keyword Refreshes for Shops. On entering Floor 1, gain 3 random Tier 1 E.G.O Gifts. +25% chance for a Super Shop to appear."
      }},
    %{index: 6, name: "Favor of the Nebulae", base_cost: 40,
      effects: %{
        0 => "On entry, all Identities +3 Level. On floor clear, all Identities +1 Level (max 5).",
        1 => "On entry, all Identities +3 Level. On floor clear, all Identities +1 Level (max 9).",
        2 => "On entry, all Identities +3 Level. On floor clear, all Identities +1 Level (max 9). On entering Floor 6, all Identities +3 Level."
      }},
    %{index: 7, name: "Starlight Guidance", base_cost: 40,
      effects: %{
        0 => "Max Speed +2. Gain 1 Clash Power Up, 1 Damage Up, 1 Protection.",
        1 => "Max Speed +3. Gain 2 Clash Power Up, 1 Damage Up, 1 Protection.",
        2 => "Max Speed +3. Gain 2 Clash Power Up, 2 Damage Up, 2 Protection."
      }},
    %{index: 8, name: "Chance Comet", base_cost: 50,
      effects: %{
        0 => "On entering a Shop, gain 1 random Tier 3-or-less Fuse/Sale-only E.G.O Gift. On entering Floor 3, gain 1 random Tier 3 E.G.O Gift. When fusing, gain a random extra E.G.O Gift 2 tiers below the result (Tier 3+ only, once per Shop).",
        1 => "On entering a Shop, gain 1 random Tier 1-3 Fuse/Sale-only E.G.O Gift (Tier 2-3 on Floor 6+). On entering Floor 3 or 5, gain 1 random Tier 3 E.G.O Gift. When fusing, gain a random extra E.G.O Gift 2 tiers below the result (Tier 3+ only, once per Shop).",
        2 => "On entering a Shop, gain 1 random Tier 2-3 Fuse/Sale-only E.G.O Gift (Tier 3-4 on Floor 6+). On entering Floor 3, 5, or 7, gain 1 random Tier 4 E.G.O Gift. When fusing, gain a random extra E.G.O Gift 2 tiers below the result (Tier 3+ only, once per Shop)."
      }},
    %{index: 9, name: "Perfected Possibility", base_cost: 60,
      effects: %{
        0 => "Theme Pack Selection +1. Starting E.G.O Gift Choice +1. On entry, gain 1 Tier 3 E.G.O Gift of your choice for your selected Keyword category.",
        1 => "Theme Pack Selection +1. Starting E.G.O Gift Choice +1. On entry, gain 2 Tier 3 E.G.O Gifts of your choice for your selected Keyword category.",
        2 => "Theme Pack Selection +1. Starting E.G.O Gift Choice +1. On entry, gain 3 Tier 3 E.G.O Gifts of your choice for your selected Keyword category."
      }}
  ]

  @impl true
  def mount(_params, session, socket) do
    gifts = EgoGifts.list_gifts()
    team = session["team_id"] && Teams.get_team(session["team_id"])

    socket =
      socket
      |> assign(:team_id, team && team.id)
      |> assign(:plans, Plans.list(:gift_plans))
      |> assign(:gifts, gifts)
      |> assign(:gifts_by_name, Map.new(gifts, &{&1.name, &1}))
      |> assign(:gifts_by_id, Map.new(gifts, &{&1.id, &1}))
      |> assign(:sinners, Teams.all_sinners())
      |> assign(:route_clipboard, nil)
      |> assign(:route_defaults, RouteDefaults.all())
      |> assign(:import_source, nil)
      |> assign(:gift_clipboard, nil)
      |> reset_editor()

    {:ok, if(team && team.gift_plan_id, do: load_plan(socket, team.gift_plan_id), else: socket)}
  end

  @impl true
  def handle_event("new_plan", _, socket) do
    attrs = %{name: Plans.new_name(:gift_plans, socket.assigns.team_id), data: GiftPlans.blank()}

    case Plans.save(:gift_plans, attrs) do
      {:ok, id} -> {:noreply, socket |> refresh_plans() |> load_plan(id) |> link_team(:gift_plan_id)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("select_plan", %{"id" => id}, socket) do
    {:noreply, socket |> load_plan(String.to_integer(id)) |> link_team(:gift_plan_id)}
  end

  @impl true
  def handle_event("duplicate_plan", %{"id" => id}, socket) do
    case Plans.get(:gift_plans, String.to_integer(id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Plan not found.")}

      plan ->
        case Plans.save(:gift_plans, %{name: "#{plan.name} (copy)", data: plan.data}) do
          {:ok, new_id} -> {:noreply, socket |> refresh_plans() |> load_plan(new_id) |> link_team(:gift_plan_id)}
          {:error, reason} -> {:noreply, put_flash(socket, :error, "Duplicate failed: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def handle_event("delete_plan", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Plans.delete(:gift_plans, id) do
      {:ok, _} ->
        socket = if socket.assigns.editing_id == id, do: reset_editor(socket), else: socket
        {:noreply, socket |> refresh_plans() |> link_team(:gift_plan_id) |> put_flash(:info, "Plan deleted.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("rename_plan", %{"value" => name}, socket) do
    {:noreply, socket |> assign(:name, String.trim(name)) |> persist_plan() |> link_team(:gift_plan_id)}
  end

  @impl true
  def handle_event("set_affinity", %{"affinity" => affinity}, socket) do
    affinity = blank_to_nil(affinity)
    {:noreply, update_plan(socket, &Map.merge(&1, %{"affinity" => affinity, "cabinet_gifts" => GiftPlans.starting_gifts(affinity)}))}
  end

  @impl true
  def handle_event("reorder_cabinet_gifts", %{"ids" => ids}, socket) do
    {:noreply, update_plan(socket, &Map.put(&1, "cabinet_gifts", ids))}
  end

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    {:noreply, socket |> assign(:active_tab, String.to_existing_atom(tab)) |> assign(:selected_gift_name, nil)}
  end

  @impl true
  def handle_event("filter_gifts", %{"value" => value}, socket) do
    {:noreply, assign(socket, :gift_filter, value)}
  end

  @impl true
  def handle_event("set_gift_tier_filter", %{"value" => tier}, socket) do
    tier = if tier == "", do: nil, else: String.to_integer(tier)
    {:noreply, assign(socket, :gift_tier_filter, tier)}
  end

  @impl true
  def handle_event("set_gift_affinity_filter", %{"value" => affinity}, socket) do
    {:noreply, assign(socket, :gift_affinity_filter, blank_to_nil(affinity))}
  end

  @impl true
  def handle_event("set_gift_sort", %{"value" => sort_by}, socket) when sort_by in @gift_sorts do
    {:noreply, assign(socket, :gift_sort, sort_by)}
  end

  @impl true
  def handle_event("show_gift", %{"gift" => gift}, socket) do
    {:noreply, socket |> assign(:selected_gift_name, gift) |> assign(:uptie_view, "base")}
  end

  @impl true
  def handle_event("select_gift", %{"gift" => gift}, socket) do
    if socket.assigns.selected_gift_name == gift do
      {:noreply, assign(socket, :selected_gift_name, nil)}
    else
      {:noreply, socket |> assign(:selected_gift_name, gift) |> assign(:uptie_view, "base")}
    end
  end

  @impl true
  def handle_event("set_uptie_view", %{"level" => level}, socket) when level in @uptie_views do
    {:noreply, assign(socket, :uptie_view, level)}
  end

  @impl true
  def handle_event("toggle_grace", %{"index" => index}, socket) do
    index = String.to_integer(index)

    {:noreply,
     update_plan(socket, fn data ->
       picks = data["grace_picks"]

       picks =
         if Enum.any?(picks, &(&1["index"] == index)),
           do: Enum.reject(picks, &(&1["index"] == index)),
           else: [%{"index" => index, "enhance" => 0} | picks]

       Map.put(data, "grace_picks", picks)
     end)}
  end

  @impl true
  def handle_event("set_grace_enhance", %{"index" => index, "level" => level}, socket) do
    index = String.to_integer(index)
    level = String.to_integer(level)

    {:noreply,
     update_plan(socket, fn data ->
       picks = data["grace_picks"]

       picks =
         if Enum.any?(picks, &(&1["index"] == index)),
           do: Enum.map(picks, fn pick -> if pick["index"] == index, do: %{pick | "enhance" => level}, else: pick end),
           else: [%{"index" => index, "enhance" => level} | picks]

       Map.put(data, "grace_picks", picks)
     end)}
  end

  @impl true
  def handle_event("toggle_search_gift", %{"gift" => name}, socket) do
    {:noreply,
     update_plan(socket, fn data ->
       picks = data["gift_search"]

       cond do
         name in picks -> Map.put(data, "gift_search", List.delete(picks, name))
         length(picks) >= GiftPlans.gift_search_max() -> data
         true -> Map.put(data, "gift_search", picks ++ [name])
       end
     end)}
  end

  @impl true
  def handle_event("add_workflow", _, socket) do
    data = socket.assigns.plan_data
    keep_id = data["library"]["lists"] |> List.first() |> then(&(&1 && &1["id"]))
    workflow = %{"id" => GiftPlans.new_id("wf"), "name" => "Workflow #{length(data["workflows"]) + 1}", "keep" => keep_id, "steps" => []}

    {:noreply,
     socket
     |> update_plan(&Map.update!(&1, "workflows", fn workflows -> workflows ++ [workflow] end))
     |> assign(:selected_workflow_id, workflow["id"])}
  end

  @impl true
  def handle_event("import_source", params, socket) do
    source =
      case Integer.parse(params["plan_id"] || "") do
        {id, ""} -> Plans.get(:gift_plans, id)
        _ -> nil
      end

    {:noreply, assign(socket, :import_source, source && %{source | data: GiftPlans.normalize(source.data)})}
  end

  @impl true
  def handle_event("import_workflows", %{"workflow" => workflow}, socket) do
    case socket.assigns.import_source do
      %{data: source, name: source_name} ->
        ids = if workflow == "all", do: Enum.map(source["workflows"], & &1["id"]), else: [workflow]
        before = MapSet.new(socket.assigns.plan_data["workflows"], & &1["id"])

        socket = update_plan(socket, &GiftPlans.import_workflows(&1, source, ids, source_name))
        added = Enum.reject(socket.assigns.plan_data["workflows"], &MapSet.member?(before, &1["id"]))

        {:noreply,
         socket
         |> assign(:selected_workflow_id, first_id(added) || socket.assigns.selected_workflow_id)
         |> put_flash(:info, "Copied #{length(added)} workflow(s) from #{source_name}.")}

      nil ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_workflow", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:selected_workflow_id, id) |> assign(:expanded_step_id, nil) |> assign(:add_target, "")}
  end

  @impl true
  def handle_event("update_workflow", %{"workflow" => params}, socket) do
    {:noreply,
     update_plan(socket, fn data ->
       update_workflow(data, socket.assigns.selected_workflow_id, fn workflow ->
         workflow
         |> Map.put("name", String.trim(params["name"] || workflow["name"]))
         |> Map.put("keep", blank_to_nil(params["keep"]))
       end)
     end)}
  end

  @impl true
  def handle_event("duplicate_workflow", %{"id" => id}, socket) do
    case GiftPlans.find_workflow(socket.assigns.plan_data, id) do
      nil ->
        {:noreply, socket}

      workflow ->
        copy = %{
          workflow
          | "id" => GiftPlans.new_id("wf"),
            "name" => "#{workflow["name"]} (copy)",
            "steps" => Enum.map(workflow["steps"], &GiftPlans.fresh_step_ids/1)
        }

        {:noreply,
         socket
         |> update_plan(&Map.update!(&1, "workflows", fn workflows -> workflows ++ [copy] end))
         |> assign(:selected_workflow_id, copy["id"])}
    end
  end

  @impl true
  def handle_event("delete_workflow", %{"id" => id}, socket) do
    data = socket.assigns.plan_data
    callers = GiftPlans.callers(data, id) |> Enum.reject(&(&1["id"] == id))

    cond do
      Enum.any?(data["floor_schedule"], &(&1["workflow"] == id)) ->
        {:noreply, put_flash(socket, :error, "That workflow is assigned to a floor range. Reassign the floors first.")}

      callers != [] ->
        {:noreply, put_flash(socket, :error, "That workflow is run by #{Enum.map_join(callers, ", ", & &1["name"])}. Remove those steps first.")}

      true ->
        remaining = Enum.reject(data["workflows"], &(&1["id"] == id))
        selected = if socket.assigns.selected_workflow_id == id, do: first_id(remaining), else: socket.assigns.selected_workflow_id

        {:noreply,
         socket
         |> update_plan(&Map.put(&1, "workflows", remaining))
         |> assign(:selected_workflow_id, selected)}
    end
  end

  @impl true
  def handle_event("add_schedule_row", _, socket) do
    data = socket.assigns.plan_data
    next_floor = (data["floor_schedule"] |> Enum.map(& &1["from_floor"]) |> Enum.max(fn -> 0 end)) |> Kernel.+(1) |> min(15)
    row = %{"from_floor" => next_floor, "workflow" => socket.assigns.selected_workflow_id}

    {:noreply, update_plan(socket, &Map.put(&1, "floor_schedule", sort_schedule(&1["floor_schedule"] ++ [row])))}
  end

  @impl true
  def handle_event("update_schedule", %{"rows" => rows}, socket) do
    schedule =
      rows
      |> Enum.sort_by(fn {index, _row} -> String.to_integer(index) end)
      |> Enum.map(fn {_index, row} -> %{"from_floor" => parse_int(row["from_floor"], 1) |> max(1) |> min(15), "workflow" => row["workflow"]} end)
      |> sort_schedule()

    {:noreply, update_plan(socket, &Map.put(&1, "floor_schedule", schedule))}
  end

  @impl true
  def handle_event("remove_schedule_row", %{"index" => index}, socket) do
    {:noreply, update_plan(socket, &Map.update!(&1, "floor_schedule", fn rows -> rows |> List.delete_at(String.to_integer(index)) |> sort_schedule() end))}
  end

  @impl true
  def handle_event("add_step", %{"kind" => "workflow", "ref" => child}, socket) do
    if GiftPlans.creates_cycle?(socket.assigns.plan_data, socket.assigns.selected_workflow_id, child) do
      {:noreply, put_flash(socket, :error, "That would make the workflow run itself.")}
    else
      step = "workflow" |> GiftPlans.new_step(socket.assigns.plan_data) |> Map.put("workflow", child)
      {:noreply, add_to_target(socket, step)}
    end
  end

  @impl true
  def handle_event("add_step", %{"kind" => "milestone", "ref" => id}, socket) do
    step = "milestone" |> GiftPlans.new_step(socket.assigns.plan_data) |> Map.put("milestone", id)
    {:noreply, add_to_target(socket, step)}
  end

  @impl true
  def handle_event("add_step", %{"kind" => kind} = params, socket) do
    step =
      case GiftPlans.library_ref(kind) do
        {_lib, field} ->
          step = GiftPlans.new_step(kind, socket.assigns.plan_data)
          Map.put(step, field, if(is_list(step[field]), do: [params["ref"]], else: params["ref"]))

        nil ->
          GiftPlans.new_step(kind, socket.assigns.plan_data)
      end

    {:noreply, add_to_target(socket, step)}
  end

  @impl true
  def handle_event("set_add_target", %{"scope" => scope}, socket) do
    {:noreply, assign(socket, :add_target, if(socket.assigns.add_target == scope, do: "", else: scope))}
  end

  @impl true
  def handle_event("toggle_step", %{"id" => id}, socket) do
    expanded = if socket.assigns.expanded_step_id == id, do: nil, else: id
    {:noreply, assign(socket, :expanded_step_id, expanded)}
  end

  @impl true
  def handle_event("update_step", %{"step_id" => id, "step" => %{"workflow" => child} = params}, socket) do
    child = blank_to_nil(child)

    if child && GiftPlans.creates_cycle?(socket.assigns.plan_data, socket.assigns.selected_workflow_id, child) do
      {:noreply, put_flash(socket, :error, "That would make the workflow run itself.")}
    else
      update_step_with_between(socket, id, params, &(&1 |> Map.put("workflow", child) |> apply_repeat(params)))
    end
  end

  def handle_event("update_step", %{"step_id" => id, "step" => params}, socket) do
    update_step_with_between(socket, id, params, &(&1 |> apply_step_params(params) |> apply_repeat(params)))
  end

  @impl true
  def handle_event("toggle_step_enabled", %{"id" => id}, socket) do
    {:noreply, update_step(socket, id, &Map.put(&1, "enabled", &1["enabled"] == false))}
  end

  @impl true
  def handle_event("move_step", %{"id" => id, "dir" => dir}, socket) do
    offset = if dir == "up", do: -1, else: 1

    {:noreply,
     update_selected_steps(socket, fn steps ->
       GiftPlans.update_containing_list(steps, id, fn steps ->
         index = Enum.find_index(steps, &(&1["id"] == id))
         target = index + offset

         if target < 0 or target >= length(steps) do
           steps
         else
           {step, rest} = List.pop_at(steps, index)
           List.insert_at(rest, target, step)
         end
       end)
     end)}
  end

  @impl true
  def handle_event("reorder_steps", %{"ids" => ids} = params, socket) do
    {:noreply, update_selected_steps(socket, &GiftPlans.update_step_list(&1, params["scope"] || "", fn steps -> reorder_by_ids(steps, ids, fn step -> step["id"] end) end))}
  end

  @impl true
  def handle_event("move_step_to", %{"scope" => scope, "id" => id, "ids" => ids}, socket) do
    {:noreply, update_selected_steps(socket, &GiftPlans.move_step(&1, id, scope, ids))}
  end

  @impl true
  def handle_event("duplicate_step", %{"id" => id}, socket) do
    {:noreply,
     update_selected_steps(socket, fn steps ->
       GiftPlans.update_containing_list(steps, id, fn steps ->
         index = Enum.find_index(steps, &(&1["id"] == id))
         copy = steps |> Enum.at(index) |> GiftPlans.fresh_step_ids()
         List.insert_at(steps, index + 1, copy)
       end)
     end)}
  end

  @impl true
  def handle_event("delete_step", %{"id" => id}, socket) do
    {:noreply, update_selected_steps(socket, &GiftPlans.remove_step(&1, id))}
  end

  @impl true
  def handle_event("copy_step", %{"step_id" => id, "workflow" => workflow_id}, socket) when workflow_id != "" do
    copy = socket |> selected_steps() |> GiftPlans.find_step(id) |> GiftPlans.fresh_step_ids()

    {:noreply,
     socket
     |> update_plan(fn data -> update_workflow(data, workflow_id, &Map.update!(&1, "steps", fn steps -> steps ++ [copy] end)) end)
     |> put_flash(:info, "Copied to #{GiftPlans.find_workflow(socket.assigns.plan_data, workflow_id)["name"]}.")}
  end

  @impl true
  def handle_event("copy_step", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_step_list_item", %{"id" => id, "field" => field, "item" => item}, socket)
      when field in ["tiers", "options", "upties", "fusions"] do
    value = if field == "tiers", do: String.to_integer(item), else: item

    {:noreply,
     update_step(socket, id, fn step ->
       items = step[field] || []
       items = if value in items, do: List.delete(items, value), else: items ++ [value]
       Map.put(step, field, items)
     end)}
  end

  @impl true
  def handle_event("reorder_step_field", %{"scope" => scope, "ids" => ids}, socket) do
    [id, field] = String.split(scope, ":")
    ids = if field == "tiers", do: Enum.map(ids, &String.to_integer/1), else: ids
    {:noreply, update_step(socket, id, &Map.put(&1, field, ids))}
  end

  @impl true
  def handle_event("cond_add", %{"path" => path, "node" => node} = params, socket) do
    child = if node == "group", do: Conditions.group(@default_leaf), else: @default_leaf
    {:noreply, update_condition(socket, params, &Conditions.add(&1, path, child))}
  end

  @impl true
  def handle_event("cond_remove", %{"path" => path} = params, socket) do
    {:noreply, update_condition(socket, params, &Conditions.remove(&1, path))}
  end

  @impl true
  def handle_event("cond_toggle_op", %{"path" => path} = params, socket) do
    {:noreply, update_condition(socket, params, &Conditions.toggle_op(&1, path))}
  end

  @impl true
  def handle_event("cond_update", %{"path" => path} = params, socket) do
    leaf =
      case params["op"] do
        op when op in ["cost_gte", "cost_lt"] -> %{"op" => op, "value" => parse_int(params["value"], 0)}
        op when op in ["refreshes_lt", "refreshes_gte"] -> %{"op" => op, "value" => max(parse_int(params["value"], 0), 0)}
        op when op in ["fusions_complete", "upties_complete"] -> %{"op" => op}
        "fusion_done" -> %{"op" => "fusion_done", "fusion" => blank_to_nil(params["fusion"])}
        "uptie_done" -> %{"op" => "uptie_done", "uptie" => blank_to_nil(params["uptie"])}
        "milestone" -> %{"op" => "milestone", "milestone" => blank_to_nil(params["milestone"])}
        op -> %{"op" => op, "gift" => String.trim(params["gift"] || "")}
      end

    host = params["milestone_id"]

    if host && leaf["milestone"] && GiftPlans.milestone_cycle?(socket.assigns.plan_data, host, leaf["milestone"]) do
      {:noreply, put_flash(socket, :error, "That would make the milestone depend on itself.")}
    else
      {:noreply, update_condition(socket, params, &Conditions.put_leaf(&1, path, leaf))}
    end
  end

  @impl true
  def handle_event("add_milestone", _, socket) do
    milestone = GiftPlans.new_milestone("Milestone #{length(socket.assigns.plan_data["milestones"]) + 1}")

    {:noreply,
     socket
     |> update_plan(&Map.update!(&1, "milestones", fn milestones -> milestones ++ [milestone] end))
     |> assign(:selected_milestone_id, milestone["id"])
     |> assign(:shop_lib, "milestones")}
  end

  @impl true
  def handle_event("select_milestone", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:selected_milestone_id, id) |> assign(:shop_lib, "milestones")}
  end

  @impl true
  def handle_event("update_milestone", %{"milestone_id" => id, "name" => name}, socket) do
    {:noreply, update_milestone(socket, id, &Map.put(&1, "name", String.trim(name)))}
  end

  @impl true
  def handle_event("move_milestone", %{"id" => id, "dir" => dir}, socket) do
    offset = if dir == "up", do: -1, else: 1

    {:noreply,
     update_plan(socket, fn data ->
       Map.update!(data, "milestones", fn milestones ->
         index = Enum.find_index(milestones, &(&1["id"] == id))
         target = index + offset

         if target < 0 or target >= length(milestones) do
           milestones
         else
           {milestone, rest} = List.pop_at(milestones, index)
           List.insert_at(rest, target, milestone)
         end
       end)
     end)}
  end

  @impl true
  def handle_event("delete_milestone", %{"id" => id}, socket) do
    socket = update_plan(socket, &GiftPlans.remove_milestone(&1, id))
    selected = if socket.assigns.selected_milestone_id == id, do: first_id(socket.assigns.plan_data["milestones"]), else: socket.assigns.selected_milestone_id
    {:noreply, assign(socket, :selected_milestone_id, selected)}
  end

  @impl true
  def handle_event("toggle_milestone", %{"milestone" => milestone} = params, socket) do
    ref = GiftPlans.entry_ref(params["lib"], params["id"], params["gift"])

    {:noreply,
     update_plan(socket, fn data ->
       if Map.has_key?(GiftPlans.assignments(data, ref), milestone),
         do: GiftPlans.remove_entry(data, milestone, ref),
         else: GiftPlans.add_entry(data, milestone, ref)
     end)}
  end

  @impl true
  def handle_event("include_milestone", %{"milestone_id" => host, "sub" => sub}, socket) when sub != "" do
    if GiftPlans.milestone_cycle?(socket.assigns.plan_data, host, sub) do
      {:noreply, put_flash(socket, :error, "That would make the milestone depend on itself.")}
    else
      {:noreply, update_plan(socket, &GiftPlans.add_entry(&1, host, GiftPlans.entry_ref("milestones", sub)))}
    end
  end

  @impl true
  def handle_event("include_milestone", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("set_entry_group", %{"milestone_id" => milestone, "group" => group} = params, socket) do
    ref = GiftPlans.entry_ref(params["lib"], params["def_id"], params["gift"])
    {:noreply, update_plan(socket, &GiftPlans.set_entry_group(&1, milestone, ref, blank_to_nil(group)))}
  end

  @impl true
  def handle_event("set_group_min", %{"milestone_id" => id, "group" => letter, "min" => min}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.set_group_min(&1, id, letter, parse_int(min, 1)))}
  end

  @impl true
  def handle_event("reorder_milestone_blocks", %{"scope" => id, "ids" => keys}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.reorder_blocks(&1, id, keys))}
  end

  @impl true
  def handle_event("move_milestone_entry", %{"scope" => scope, "id" => key, "ids" => keys}, socket) do
    {id, letter} =
      case String.split(scope, "|") do
        [id, letter] -> {id, letter}
        [id] -> {id, nil}
      end

    {:noreply, update_plan(socket, &GiftPlans.move_entry(&1, id, key, letter, keys))}
  end

  @impl true
  def handle_event("reorder_milestone_group", %{"scope" => scope, "ids" => keys}, socket) do
    [id, letter] = String.split(scope, "|")
    {:noreply, update_plan(socket, &GiftPlans.reorder_group(&1, id, letter, keys))}
  end

  @impl true
  def handle_event("lib_add", %{"lib" => lib} = params, socket) do
    count = length(socket.assigns.plan_data["library"][lib])
    name = "#{lib_label(lib)} #{count + 1}"
    definition = if params["type"], do: GiftPlans.new_definition(lib, name, params["type"]), else: GiftPlans.new_definition(lib, name)
    top = first_id(socket.assigns.plan_data["milestones"])
    add_to_top = &if(top && lib in ["upties", "fusions"], do: GiftPlans.add_entry(&1, top, GiftPlans.entry_ref(lib, definition["id"])), else: &1)

    {:noreply,
     socket
     |> update_plan(&(&1 |> update_in(["library", lib], fn defs -> defs ++ [definition] end) |> add_to_top.()))
     |> select_definition(lib, definition["id"])}
  end

  @impl true
  def handle_event("lib_select", %{"lib" => lib, "id" => id}, socket) do
    {:noreply, select_definition(socket, lib, id)}
  end

  @impl true
  def handle_event("lib_delete", %{"lib" => lib, "id" => id}, socket) do
    remaining = Enum.reject(socket.assigns.plan_data["library"][lib], &(&1["id"] == id))

    {:noreply,
     socket
     |> update_plan(&(&1 |> put_in(["library", lib], remaining) |> GiftPlans.drop_refs_everywhere(fn ref -> ref["lib"] == lib and ref["id"] == id end)))
     |> select_definition(lib, first_id(remaining))}
  end

  @impl true
  def handle_event("lib_update", %{"lib" => lib, "def_id" => id, "def" => params}, socket) do
    {:noreply, update_plan(socket, &update_definition(&1, lib, id, fn definition -> apply_definition_params(lib, definition, params) end))}
  end

  @impl true
  def handle_event("lib_toggle_gift", %{"lib" => lib, "id" => id, "gift" => gift}, socket) do
    {:noreply,
     update_plan(socket, fn data ->
       removing? = gift in GiftPlans.find_definition(data, lib, id)["gifts"]
       key = GiftPlans.entry_key(GiftPlans.entry_ref(lib, id, gift))

       data
       |> update_definition(lib, id, fn definition ->
         gifts = definition["gifts"]
         Map.put(definition, "gifts", if(removing?, do: List.delete(gifts, gift), else: gifts ++ [gift]))
       end)
       |> then(&if(removing?, do: GiftPlans.drop_refs_everywhere(&1, fn ref -> GiftPlans.entry_key(ref) == key end), else: &1))
     end)}
  end

  @impl true
  def handle_event("lib_add_affinity", %{"def_id" => id, "affinity" => affinity} = params, socket) when affinity != "" do
    tiers = for tier <- params["tiers"] || [], do: String.to_integer(tier)
    entry = GiftPlans.affinity_entry(affinity, tiers)

    {:noreply,
     update_plan(socket, &update_definition(&1, "lists", id, fn list ->
       if entry in list["gifts"], do: list, else: Map.put(list, "gifts", list["gifts"] ++ [entry])
     end))}
  end

  @impl true
  def handle_event("lib_add_affinity", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("lib_reorder_gifts", %{"scope" => scope, "ids" => ids}, socket) do
    [lib, id] = String.split(scope, ":")
    {:noreply, update_plan(socket, &update_definition(&1, lib, id, fn definition -> Map.put(definition, "gifts", ids) end))}
  end

  @impl true
  def handle_event("set_uptie_gift", %{"id" => id, "gift" => gift_name}, socket) do
    {:noreply, update_plan(socket, &update_definition(&1, "upties", id, fn definition -> Map.merge(definition, %{"gift" => gift_name, "name" => gift_name}) end))}
  end

  @impl true
  def handle_event("set_fusion_target", %{"id" => id, "gift" => gift_name}, socket) do
    gift = socket.assigns.gifts_by_name[gift_name]
    tier = gift.tier

    {:noreply,
     update_plan(socket, fn data ->
       update_definition(data, "fusions", id, fn
         %{"type" => "fixed"} = definition ->
           %{definition | "target" => gift_name, "name" => gift_name, "sub_fusions" => auto_sub_fusions(data, id, gift, socket.assigns.gifts_by_id)}

         definition ->
         routes =
           case Routes.valid_for_tier(definition["routes"] || [], tier) do
             [] -> RouteDefaults.get(tier)
             kept -> kept
           end

         %{definition | "target" => gift_name, "name" => gift_name, "routes" => routes}
       end)
     end)}
  end

  @impl true
  def handle_event("set_sub_fusion", %{"def_id" => id, "ingredient" => ingredient} = params, socket) do
    sub_id = blank_to_nil(params["sub"])

    {:noreply,
     update_plan(socket, &update_definition(&1, "fusions", id, fn definition ->
       subs = definition["sub_fusions"] || %{}
       Map.put(definition, "sub_fusions", if(sub_id, do: Map.put(subs, ingredient, sub_id), else: Map.delete(subs, ingredient)))
     end))}
  end

  @impl true
  def handle_event("create_sub_fusion", %{"def_id" => id, "ingredient" => ingredient}, socket) do
    tier = socket.assigns.gifts_by_name[ingredient].tier
    sub = %{GiftPlans.new_definition("fusions", ingredient, "tiered") | "target" => ingredient, "routes" => RouteDefaults.get(tier)}

    {:noreply,
     update_plan(socket, fn data ->
       data
       |> update_in(["library", "fusions"], &(&1 ++ [sub]))
       |> update_definition("fusions", id, fn definition -> Map.put(definition, "sub_fusions", Map.put(definition["sub_fusions"] || %{}, ingredient, sub["id"])) end)
     end)}
  end

  @impl true
  def handle_event("gifts_copy", %{"lib" => lib, "def_id" => id}, socket) do
    definition = GiftPlans.find_definition(socket.assigns.plan_data, lib, id)
    clipboard = %{name: definition["name"], lib: lib, gifts: definition["gifts"]}
    {:noreply, assign(socket, :gift_clipboard, clipboard)}
  end

  @impl true
  def handle_event("gifts_paste", %{"lib" => lib, "def_id" => id}, socket) do
    case socket.assigns.gift_clipboard do
      %{gifts: gifts} ->
        {:noreply, update_plan(socket, &update_definition(&1, lib, id, fn definition -> Map.put(definition, "gifts", gifts) end))}

      nil -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("rt_copy", %{"def_id" => id}, socket) do
    definition = GiftPlans.find_definition(socket.assigns.plan_data, "fusions", id)
    target = socket.assigns.gifts_by_name[definition["target"]]

    clipboard = %{name: definition["name"], tier: target.tier, routes: definition["routes"] || []}
    {:noreply, assign(socket, :route_clipboard, clipboard)}
  end

  @impl true
  def handle_event("rt_paste", %{"def_id" => id}, socket) do
    case socket.assigns.route_clipboard do
      %{routes: routes} -> {:noreply, update_routes(socket, id, fn _routes -> Routes.copy(routes) end)}
      nil -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("rt_make_default", %{"def_id" => id}, socket) do
    definition = GiftPlans.find_definition(socket.assigns.plan_data, "fusions", id)
    tier = socket.assigns.gifts_by_name[definition["target"]].tier

    case RouteDefaults.put(tier, definition["routes"] || []) do
      :ok ->
        {:noreply,
         socket
         |> assign(:route_defaults, RouteDefaults.all())
         |> put_flash(:info, "Saved these routes as the tier #{tier} default.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Couldn't save the tier #{tier} default routes.")}
    end
  end

  @impl true
  def handle_event("rt_use_default", %{"def_id" => id}, socket) do
    definition = GiftPlans.find_definition(socket.assigns.plan_data, "fusions", id)
    tier = socket.assigns.gifts_by_name[definition["target"]].tier
    {:noreply, update_routes(socket, id, fn _routes -> RouteDefaults.get(tier) end)}
  end

  @impl true
  def handle_event("rt_add", %{"def_id" => id, "parent" => parent, "tier" => tier, "combo" => key}, socket) when key != "" do
    route = Routes.new(Combos.parse_combo_key(key))
    {:noreply, update_routes(socket, id, &Routes.add(&1, blank_to_nil(parent), String.to_integer(tier), route))}
  end

  @impl true
  def handle_event("rt_add", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("rt_update", %{"def_id" => id, "route_id" => route_id} = params, socket) do
    leftover =
      for {tier, value} <- params["leftover"] || %{}, count = parse_int(value, 0), count > 0, into: %{}, do: {tier, count}

    {:noreply,
     update_routes(socket, id, fn routes ->
       Routes.update(routes, route_id, fn route ->
         %{route | "buy_up_to" => parse_optional_int(params["buy_up_to"]), "leftover" => leftover}
       end)
     end)}
  end

  @impl true
  def handle_event("rt_duplicate", %{"def_id" => id, "route_id" => route_id}, socket) do
    {:noreply, update_routes(socket, id, &Routes.duplicate(&1, route_id))}
  end

  @impl true
  def handle_event("rt_delete", %{"def_id" => id, "route_id" => route_id}, socket) do
    {:noreply, update_routes(socket, id, &Routes.delete(&1, route_id))}
  end

  @impl true
  def handle_event("rt_reorder", %{"scope" => scope, "ids" => ids}, socket) do
    [id, parent, tier] = String.split(scope, "|")
    {:noreply, update_routes(socket, id, &Routes.reorder(&1, blank_to_nil(parent), String.to_integer(tier), ids))}
  end

  def tabs, do: @tabs
  def graces, do: @graces
  def gift_tiers, do: @gift_tiers
  def affinities, do: @affinities
  def palette_kinds, do: @palette_kinds
  def library_kinds, do: @library_kinds

  def tab_label(:workflows), do: "Workflows"
  def tab_label(:shop), do: "Shop"
  def tab_label(:grace), do: "Grace"
  def tab_label(:gift_search), do: "Gift Search"

  def accent_tab?(tab), do: tab in [:grace, :gift_search]

  def searchable_gifts(gifts), do: Enum.filter(gifts, &GiftPlans.gift_searchable?/1)

  def lib_label("upties"), do: "Uptie"
  def lib_label("fusions"), do: "Fusion"
  def lib_label("lists"), do: "List"

  def lib_heading("lists"), do: "Item Lists"
  def lib_heading(lib), do: "#{lib_label(lib)}s"

  def grace_pick(plan_data, index), do: Enum.find(plan_data["grace_picks"], &(&1["index"] == index))

  def grace_enhance_icon(0), do: "○"
  def grace_enhance_icon(1), do: "+"
  def grace_enhance_icon(2), do: "++"

  def grace_level_cost(grace, level), do: grace.base_cost * (level + 1)

  def grace_effect(grace, level), do: Map.get(grace.effects, level, Map.get(grace.effects, 0))

  def grace_total_cost(plan_data) do
    Enum.reduce(plan_data["grace_picks"], 0, fn pick, acc ->
      case Enum.find(@graces, &(&1.index == pick["index"])) do
        nil -> acc
        grace -> acc + grace_level_cost(grace, pick["enhance"])
      end
    end)
  end
  def sinner_label(nil), do: "(none)"
  def sinner_label(sinner), do: sinner |> String.split("_") |> Enum.map_join(" ", &String.capitalize/1)

  def skill_option_label("s1_s2"), do: "S1 → S2 (45)"
  def skill_option_label("s2_s3"), do: "S2 → S3 (75)"
  def skill_option_label("s1_s3"), do: "S1 → S3 (120)"

  def selected_workflow(assigns), do: GiftPlans.find_workflow(assigns.plan_data, assigns.selected_workflow_id)

  def selected_milestone(assigns), do: GiftPlans.find_milestone(assigns.plan_data, assigns.selected_milestone_id)

  def milestone_entry_gift(%{lib: "fusions", definition: d}), do: d["target"]
  def milestone_entry_gift(%{lib: "upties", definition: d}), do: d["gift"]
  def milestone_entry_gift(%{lib: "lists", gift: gift}), do: gift
  def milestone_entry_gift(_entry), do: nil

  def milestone_entry_kind(%{lib: "fusions"}), do: "fusion"
  def milestone_entry_kind(%{lib: "upties"}), do: "uptie"
  def milestone_entry_kind(%{lib: "lists"}), do: "list"
  def milestone_entry_kind(%{lib: "milestones"}), do: "milestone"

  def milestone_entry_label(%{lib: "fusions", definition: d}), do: "#{d["name"]} · #{d["target"] || "(no target)"}"
  def milestone_entry_label(%{lib: "upties", definition: d}), do: "#{d["name"]} · #{d["gift"] || "(no gift)"} +#{d["target_level"]}"
  def milestone_entry_label(%{lib: "lists", definition: d, gift: gift}), do: "#{GiftPlans.entry_label(gift)} · #{d["name"]}"
  def milestone_entry_label(%{lib: "milestones", definition: d}), do: "#{d["name"]} (its entries run first)"

  def includable_milestones(data, host_id) do
    included = for %{"lib" => "milestones", "id" => id} <- GiftPlans.milestone_refs(GiftPlans.find_milestone(data, host_id) || %{}), do: id
    Enum.reject(milestone_options(data, host_id), &(&1["id"] in included))
  end

  def milestone_options(data, nil), do: data["milestones"]
  def milestone_options(data, host_id), do: Enum.reject(data["milestones"], &GiftPlans.milestone_cycle?(data, host_id, &1["id"]))

  def selected_definition(assigns, lib), do: GiftPlans.find_definition(assigns.plan_data, lib, assigns.selected_def[lib])

  def list_roles(data, id) do
    steps = Enum.flat_map(data["workflows"], & &1["steps"])

    [
      Enum.any?(data["workflows"], &(&1["keep"] == id)) && "keep",
      Enum.any?(steps, &(&1["kind"] == "buy_list" and &1["list"] == id)) && "buy",
      Enum.any?(steps, &(&1["kind"] == "sell" and &1["list"] == id)) && "sell"
    ]
    |> Enum.filter(& &1)
  end

  def uncaptured_protected(data, workflow, gifts, gifts_by_name) do
    kept = GiftPlans.keep_gifts(data, workflow)

    data
    |> GiftPlans.derived_protected(workflow, gifts)
    |> Enum.reject(fn name ->
      gift = gifts_by_name[name]
      Enum.any?(kept, &(&1 == name or (gift && GiftPlans.entry_matches?(&1, gift))))
    end)
  end

  def workflows_using_keep(data, keep_id), do: data["workflows"] |> Enum.filter(&(&1["keep"] == keep_id)) |> Enum.map(& &1["name"])

  def step_broken?(data, step), do: match?({:error, _}, GiftPlans.definition_for(data, step))

  def step_summary(data, %{"kind" => "uptie"} = step) do
    case GiftPlans.definition_for(data, step) do
      {:ok, defs} -> "up to #{step["max_gifts"]} · " <> Enum.map_join(defs, " › ", &"#{&1["gift"] || "(no gift)"} +#{&1["target_level"]}")
      _ -> nil
    end
  end

  def step_summary(data, %{"kind" => "fusion"} = step) do
    case GiftPlans.definition_for(data, step) do
      {:ok, defs} ->
        targets = Enum.map_join(defs, " › ", &(&1["target"] || "(no target)"))
        if is_integer(step["max_retries"]), do: "#{targets} · #{step["max_retries"]} retries", else: targets
      _ -> nil
    end
  end

  def step_summary(_data, %{"kind" => "buy_list", "done_at" => done_at}) when is_integer(done_at), do: "until owning #{done_at}"

  def step_summary(_data, %{"kind" => "sell"} = step) do
    source = if step["list"], do: "from list", else: Enum.map_join(step["tiers"] || [], " then ", &"T#{&1}")
    stop = if step["stop_at_cost"], do: "until #{step["stop_at_cost"]} or ", else: "up to "
    "#{source} · #{stop}#{step["max_items"]} sold"
  end

  def step_summary(_data, %{"kind" => "skill_replace"} = step), do: Enum.map_join(step["options"] || [], ", ", &String.replace(&1, "_", "→"))

  def step_summary(_data, %{"kind" => kind}) when kind in ~w(heal heal_all revive), do: "costs #{GiftPlans.heal_cost()}"

  def step_summary(data, %{"kind" => "workflow"} = step) do
    case GiftPlans.definition_for(data, step) do
      {:ok, workflow} -> "#{Enum.count(workflow["steps"], &(&1["enabled"] != false))} enabled step(s)"
      _ -> nil
    end
  end

  def step_summary(_data, %{"kind" => "if"} = step), do: "then #{length(step["then"] || [])} · else #{length(step["else"] || [])}"

  def step_summary(_data, _step), do: nil

  def callable_workflows(data, host_id), do: Enum.reject(data["workflows"], &GiftPlans.creates_cycle?(data, host_id, &1["id"]))

  def combo_roman(combo), do: Enum.map_join(combo, " ", &gift_tier_roman/1)

  def combo_shops_label([:normal, :super]), do: nil
  def combo_shops_label([:normal]), do: "normal only"
  def combo_shops_label([:super]), do: "super only"
  def combo_shops_label([]), do: "can't make this tier"

  def selector_combos(tier) do
    tier |> Combos.valid_combos() |> Enum.sort_by(&{&1.shops == [:super], Enum.max(&1.combo) >= tier, &1.points})
  end

  def combo_meta(combo), do: "#{Combos.points(combo)} pts · #{Combos.keyword_odds(combo)}% keyword"

  def fusion_target_eligible?(gift), do: gift.tier in 2..4 and GiftPlans.ingredient_ids(gift) == []

  def fixed_target_eligible?(gift), do: GiftPlans.ingredient_ids(gift) != []

  def sub_fusion_options(data, definition, ingredient) do
    Enum.filter(data["library"]["fusions"], &(&1["target"] == ingredient and &1["id"] != definition["id"]))
  end

  defp auto_sub_fusions(data, id, gift, gifts_by_id) do
    for name <- GiftPlans.ingredient_names(gift, gifts_by_id),
        sub = Enum.find(data["library"]["fusions"], &(&1["target"] == name and &1["id"] != id)),
        into: %{},
        do: {name, sub["id"]}
  end

  def uptie_cost_hint(gift, definition) do
    target = definition["target_level"]
    tier = gift && gift.tier

    [
      GiftPlans.uptie_cost(tier, 0, target) && "0→#{target}: #{GiftPlans.uptie_cost(tier, 0, target)}",
      target == 2 && GiftPlans.uptie_cost(tier, 1, 2) && "1→2: #{GiftPlans.uptie_cost(tier, 1, 2)}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end


  def fusion_ingredient_ids(gift), do: GiftPlans.ingredient_ids(gift)

  def filtered_gifts(gifts, filter, tier_filter, affinity_filter, sort_by) do
    gifts
    |> Enum.filter(&matches_text_filter?(&1, filter))
    |> Enum.filter(&(is_nil(tier_filter) or &1.tier == tier_filter))
    |> Enum.filter(&(is_nil(affinity_filter) or &1.affinity == affinity_filter))
    |> sort_gifts(sort_by)
  end

  def gift_sorts, do: @gift_sorts

  def gift_sort_label("default"), do: "Default order"
  def gift_sort_label("name"), do: "Name"
  def gift_sort_label("tier"), do: "Tier"
  def gift_sort_label("affinity"), do: "Affinity"

  def sort_gifts(gifts, "name"), do: Enum.sort_by(gifts, &{&1.name || "", &1.tier || 0, &1.affinity || ""})
  def sort_gifts(gifts, "tier"), do: Enum.sort_by(gifts, &{&1.tier || 0, &1.affinity || ""})
  def sort_gifts(gifts, "affinity"), do: Enum.sort_by(gifts, &{&1.affinity || "", &1.tier || 0})
  def sort_gifts(gifts, _default), do: Enum.sort_by(gifts, &(&1.sort_id || 999_999))

  @roman_numerals [{5, "V"}, {4, "IV"}, {1, "I"}]

  def gift_tier_roman(nil), do: ""
  def gift_tier_roman(n) when is_integer(n), do: to_roman(n, @roman_numerals)

  defp to_roman(0, _table), do: ""
  defp to_roman(n, [{value, numeral} | rest]) when n >= value, do: numeral <> to_roman(n - value, [{value, numeral} | rest])
  defp to_roman(n, [_ | rest]), do: to_roman(n, rest)
  defp to_roman(_n, []), do: ""

  def gift_affinity_icon(affinity), do: "/images/affinity/#{affinity}.webp"

  def uptie_views, do: @uptie_views

  def uptie_view_icon("base"), do: "○"
  def uptie_view_icon("uptie2"), do: "+"
  def uptie_view_icon("uptie3"), do: "++"

  def uptie_view_available?(gift, "base", gifts_by_id), do: not is_nil(clean_gift_text(gift.description, gifts_by_id))
  def uptie_view_available?(gift, "uptie2", gifts_by_id), do: not is_nil(clean_gift_text(gift.uptie2, gifts_by_id))
  def uptie_view_available?(gift, "uptie3", gifts_by_id), do: not is_nil(clean_gift_text(gift.uptie3, gifts_by_id))

  def gift_detail_text(gift, "base", gifts_by_id),
    do: clean_gift_text(gift.description, gifts_by_id) || "No description available."

  def gift_detail_text(gift, "uptie2", gifts_by_id),
    do: clean_gift_text(gift.uptie2, gifts_by_id) || "No + uptie change."

  def gift_detail_text(gift, "uptie3", gifts_by_id),
    do: clean_gift_text(gift.uptie3, gifts_by_id) || "No ++ uptie change."

  def obtain_method_text(%{obtain_method: nil}, _gifts_by_id), do: nil

  def obtain_method_text(%{obtain_method: text}, gifts_by_id) do
    Regex.replace(~r/#?(gift_\w+)#?/, text, fn ref, id ->
      gift_ref_name(id, gifts_by_id) || String.trim(ref, "#")
    end)
  end

  def gift_ref_name("gift_0", _gifts_by_id), do: "unknown gift"

  def gift_ref_name(id, gifts_by_id) do
    case Map.get(gifts_by_id, id) do
      %{name: name} -> name
      nil -> nil
    end
  end

  def clean_gift_text(nil, _gifts_by_id), do: nil

  def clean_gift_text(text, gifts_by_id) do
    text
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<\/?span[^>]*>/i, "")
    |> String.replace(~r/\$\[([^\]]*)\]\$+\s*/, "[\\1] ")
    |> replace_entity_tokens(gifts_by_id)
    |> replace_stat_tokens()
    |> String.replace("#", "")
    |> String.trim()
    |> case do
      "" -> nil
      cleaned -> cleaned
    end
  end

  defp refresh_plans(socket), do: assign(socket, :plans, Plans.list(:gift_plans))

  defp reset_editor(socket) do
    socket
    |> assign(:editing_id, nil)
    |> assign(:name, "")
    |> assign(:plan_data, GiftPlans.blank())
    |> assign(:active_tab, :workflows)
    |> assign(:selected_workflow_id, nil)
    |> assign(:expanded_step_id, nil)
    |> assign(:selected_def, %{})
    |> assign(:selected_milestone_id, nil)
    |> assign(:shop_lib, "fusions")
    |> assign(:add_target, "")
    |> reset_browser()
  end

  defp reset_browser(socket) do
    socket
    |> assign(:gift_filter, "")
    |> assign(:gift_tier_filter, nil)
    |> assign(:gift_affinity_filter, nil)
    |> assign(:gift_sort, "default")
    |> assign(:selected_gift_name, nil)
    |> assign(:uptie_view, "base")
  end

  defp load_plan(socket, id) do
    case Plans.get(:gift_plans, id) do
      nil ->
        put_flash(socket, :error, "Plan not found.")

      plan ->
        data = GiftPlans.normalize(plan.data)

        socket
        |> assign(:editing_id, plan.id)
        |> assign(:name, plan.name)
        |> assign(:plan_data, data)
        |> assign(:active_tab, :workflows)
        |> assign(:selected_workflow_id, first_id(data["workflows"]))
        |> assign(:expanded_step_id, nil)
        |> assign(:selected_def, Map.new(GiftPlans.library_keys(), &{&1, first_id(data["library"][&1])}))
        |> assign(:selected_milestone_id, first_id(data["milestones"]))
        |> assign(:add_target, "")
        |> assign(:shop_lib, if(data["milestones"] != [], do: "milestones", else: Enum.find(GiftPlans.library_keys(), "fusions", &(data["library"][&1] != []))))
        |> reset_browser()
    end
  end

  defp persist_plan(socket) do
    attrs = %{id: socket.assigns.editing_id, name: socket.assigns.name, data: socket.assigns.plan_data}

    case Plans.save(:gift_plans, attrs) do
      {:ok, _id} -> refresh_plans(socket)
      {:error, reason} -> put_flash(socket, :error, "Save failed: #{inspect(reason)}")
    end
  end

  defp update_plan(socket, fun), do: socket |> assign(:plan_data, fun.(socket.assigns.plan_data)) |> persist_plan()

  defp update_workflow(data, id, fun) do
    Map.update!(data, "workflows", fn workflows -> Enum.map(workflows, &if(&1["id"] == id, do: fun.(&1), else: &1)) end)
  end

  defp selected_steps(socket), do: selected_workflow(socket.assigns)["steps"]

  defp update_selected_steps(socket, fun) do
    update_plan(socket, &update_workflow(&1, socket.assigns.selected_workflow_id, fn workflow -> Map.update!(workflow, "steps", fun) end))
  end

  defp update_step(socket, id, fun), do: update_selected_steps(socket, &GiftPlans.update_step_in(&1, id, fun))

  defp add_to_target(socket, step) do
    target = add_target(socket.assigns)

    socket
    |> update_selected_steps(&GiftPlans.update_step_list(&1, target, fn steps -> steps ++ [step] end))
    |> assign(:expanded_step_id, step["id"])
  end

  def add_target_label(data, workflow, target) do
    [id, branch] = String.split(target, ":")
    step = GiftPlans.find_step(workflow["steps"], id)
    "If #{GiftPlans.condition_label(step["condition"], data) || "always"} › #{branch}"
  end

  def add_target(%{add_target: ""}), do: ""

  def add_target(assigns) do
    [id, _branch] = String.split(assigns.add_target, ":")
    if GiftPlans.find_step(selected_workflow(assigns)["steps"], id), do: assigns.add_target, else: ""
  end

  defp update_condition(socket, %{"milestone_id" => id}, fun) do
    update_milestone(socket, id, fn milestone -> Map.put(milestone, "condition", milestone["condition"] |> fun.() |> GiftPlans.prune_condition()) end)
  end

  defp update_condition(socket, %{"step_id" => id}, fun) do
    update_step(socket, id, fn step -> Map.put(step, "condition", step["condition"] |> fun.() |> GiftPlans.prune_condition()) end)
  end

  defp update_milestone(socket, id, fun), do: update_plan(socket, &GiftPlans.update_milestone(&1, id, fun))

  defp update_routes(socket, id, fun) do
    update_plan(socket, &update_definition(&1, "fusions", id, fn definition -> Map.update(definition, "routes", fun.([]), fun) end))
  end

  defp update_definition(data, lib, id, fun) do
    update_in(data, ["library", lib], fn defs -> Enum.map(defs, &if(&1["id"] == id, do: fun.(&1), else: &1)) end)
  end

  defp select_definition(socket, lib, id) do
    socket
    |> assign(:selected_def, Map.put(socket.assigns.selected_def, lib, id))
    |> assign(:shop_lib, lib)
    |> assign(:selected_gift_name, nil)
  end

  defp apply_step_params(%{"kind" => "milestone"} = step, p), do: Map.put(step, "milestone", blank_to_nil(p["milestone"]))
  defp apply_step_params(%{"kind" => "uptie"} = step, p), do: Map.put(step, "max_gifts", max(parse_int(p["max_gifts"], 1), 1))

  defp apply_step_params(%{"kind" => "fusion"} = step, p) do
    Map.put(step, "max_retries", if(p["max_retries"] in [nil, ""], do: nil, else: max(parse_int(p["max_retries"], 0), 0)))
  end

  defp apply_step_params(%{"kind" => "buy_list"} = step, p) do
    %{step | "list" => blank_to_nil(p["list"])} |> Map.put("done_at", if(p["done_at"] in [nil, ""], do: nil, else: max(parse_int(p["done_at"], 1), 1)))
  end

  defp apply_step_params(%{"kind" => "affinity_refresh"} = step, p), do: Map.put(step, "affinity", blank_to_nil(p["affinity"]))

  defp apply_step_params(%{"kind" => "sell"} = step, p) do
    %{Map.put(step, "list", blank_to_nil(p["list"])) | "stop_at_cost" => parse_optional_int(p["stop_at_cost"]), "max_items" => max(parse_int(p["max_items"], 1), 1)}
  end

  defp apply_step_params(%{"kind" => "skill_replace"} = step, p), do: Map.put(step, "sinner", blank_to_nil(p["sinner"]))
  defp apply_step_params(%{"kind" => kind} = step, p) when kind in ["heal", "revive"], do: Map.put(step, "sinner", blank_to_nil(p["sinner"]))
  defp apply_step_params(%{"kind" => "budget"} = step, p), do: Map.put(step, "amount", parse_int(p["amount"], 0))
  defp apply_step_params(step, _p), do: step

  defp update_step_with_between(socket, id, params, fun) do
    between = blank_to_nil(params["between"])

    if between && GiftPlans.creates_cycle?(socket.assigns.plan_data, socket.assigns.selected_workflow_id, between) do
      {:noreply, put_flash(socket, :error, "That would make the workflow run itself.")}
    else
      {:noreply, update_step(socket, id, &(&1 |> fun.() |> apply_between(params)))}
    end
  end

  defp apply_between(step, %{"between" => between}) do
    case blank_to_nil(between) do
      nil -> Map.delete(step, "between")
      id -> Map.put(step, "between", id)
    end
  end

  defp apply_between(step, _p), do: step

  defp apply_repeat(step, %{"repeat" => repeat}) do
    case parse_optional_int(repeat) do
      n when is_integer(n) and n > 0 -> Map.put(step, "repeat", n)
      _ -> Map.delete(step, "repeat")
    end
  end

  defp apply_repeat(step, _p), do: step

  defp apply_definition_params("upties", definition, p) do
    %{definition | "name" => p["name"] || definition["name"], "target_level" => parse_int(p["target_level"], 2)}
  end

  defp apply_definition_params("fusions", %{"type" => "fixed"} = definition, p) do
    %{definition | "name" => p["name"] || definition["name"], "buy_missing" => p["buy_missing"] == "true"}
  end

  defp apply_definition_params(_lib, definition, p), do: Map.put(definition, "name", p["name"] || definition["name"])

  defp sort_schedule(rows) do
    case Enum.sort_by(rows, & &1["from_floor"]) do
      [first | rest] -> [Map.put(first, "from_floor", 1) | rest]
      [] -> []
    end
  end

  defp reorder_by_ids(items, ids, key_fun) do
    by_key = Map.new(items, &{key_fun.(&1), &1})
    ordered = ids |> Enum.map(&Map.get(by_key, &1)) |> Enum.reject(&is_nil/1)
    ordered ++ Enum.reject(items, &(&1 in ordered))
  end

  defp first_id([%{"id" => id} | _]), do: id
  defp first_id(_), do: nil

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(val), do: val

  defp parse_int(val, default) do
    case Integer.parse(val || "") do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_optional_int(val) do
    case Integer.parse(val || "") do
      {int, _} -> int
      :error -> nil
    end
  end

  defp replace_entity_tokens(text, gifts_by_id) do
    text
    |> replace_regex(~r/&(ids|egos)_(\d+)&/, fn
      _, "ids", id -> "[Identity ##{id}]"
      _, "egos", id -> "[E.G.O ##{id}]"
    end)
    |> replace_regex(~r/@(gift_\d+)@/, fn _, id ->
      case Map.get(gifts_by_id, id) do
        %{name: name} -> "[→ #{name}]"
        nil -> "[Gift ##{id}]"
      end
    end)
  end

  defp replace_regex(text, regex, fun), do: Regex.replace(regex, text, fun)

  defp replace_stat_tokens(text) do
    Regex.replace(~r/&\s*([+-]?\d*)\s*([a-zA-Z]{2,3})\s*([+-]?\d*)\s*&/, text, fn _, lead, code, trail ->
      label = Map.get(@stat_codes, String.downcase(code), String.upcase(code))

      case pick_number(lead, trail) do
        nil -> label
        number -> "#{label} #{number}"
      end
    end)
  end

  defp pick_number(lead, trail) do
    cond do
      lead =~ ~r/\d/ -> lead
      trail =~ ~r/\d/ -> trail
      true -> nil
    end
  end

  defp matches_text_filter?(_gift, ""), do: true
  defp matches_text_filter?(gift, filter), do: String.contains?(String.downcase(gift.name || ""), String.downcase(filter))

  def gift_leaf(assigns) do
    ~H"""
    <select name="op" class="select select-bordered select-xs">
      <option value="cost_gte" selected={@node["op"] == "cost_gte"}>cost at least</option>
      <option value="cost_lt" selected={@node["op"] == "cost_lt"}>cost under</option>
      <option value="refreshes_lt" selected={@node["op"] == "refreshes_lt"}>refreshes this shop under</option>
      <option value="refreshes_gte" selected={@node["op"] == "refreshes_gte"}>refreshes this shop at least</option>
      <option value="has_gift" selected={@node["op"] == "has_gift"}>owns gift</option>
      <option value="missing_gift" selected={@node["op"] == "missing_gift"}>doesn't own gift</option>
      <option value="fusions_complete" selected={@node["op"] == "fusions_complete"}>all fusions complete</option>
      <option value="upties_complete" selected={@node["op"] == "upties_complete"}>all upties complete</option>
      <option value="fusion_done" selected={@node["op"] == "fusion_done"}>fusion done</option>
      <option value="uptie_done" selected={@node["op"] == "uptie_done"}>uptie done</option>
      <option value="milestone" selected={@node["op"] == "milestone"}>milestone reached</option>
    </select>
    <%= cond do %>
      <% @node["op"] in ["cost_gte", "cost_lt", "refreshes_lt", "refreshes_gte"] -> %>
        <input type="number" name="value" value={@node["value"]} phx-debounce="400" class="input input-bordered input-xs w-24" />
      <% @node["op"] in ["fusions_complete", "upties_complete"] -> %>
        <span class="flex-1"></span>
      <% @node["op"] == "fusion_done" -> %>
        <select name="fusion" class="select select-bordered select-xs flex-1 min-w-0">
          <option value="">pick one</option>
          <option :for={fusion <- @plan_data["library"]["fusions"]} value={fusion["id"]} selected={@node["fusion"] == fusion["id"]}><%= fusion["name"] %></option>
        </select>
      <% @node["op"] == "uptie_done" -> %>
        <select name="uptie" class="select select-bordered select-xs flex-1 min-w-0">
          <option value="">pick one</option>
          <option :for={uptie <- @plan_data["library"]["upties"]} value={uptie["id"]} selected={@node["uptie"] == uptie["id"]}><%= uptie["name"] %></option>
        </select>
      <% @node["op"] == "milestone" -> %>
        <select name="milestone" class="select select-bordered select-xs flex-1 min-w-0">
          <option value="">pick one</option>
          <option :for={milestone <- milestone_options(@plan_data, @milestone_host)} value={milestone["id"]} selected={@node["milestone"] == milestone["id"]}><%= milestone["name"] %></option>
        </select>
      <% true -> %>
        <input type="text" name="gift" value={@node["gift"]} list="gift-name-options" phx-debounce="blur"
               placeholder="Gift name" class="input input-bordered input-xs flex-1 min-w-0" />
    <% end %>
    """
  end

  attr :entry, :map, required: true
  attr :milestone_id, :string, required: true
  attr :letters, :list, required: true
  attr :gifts_by_name, :map, required: true

  def milestone_entry_row(assigns) do
    ~H"""
    <div data-sort-id={GiftPlans.entry_key(@entry.ref)} data-sort-stay={GiftPlans.fixed_placement?(@entry.ref)}
         class={"flex items-center gap-2 rounded px-1 py-0.5 " <> if(@entry.optional, do: "border border-dashed border-base-300 opacity-70", else: "bg-base-200")}>
      <span data-sort-handle class="cursor-grab text-base-content/40 select-none px-1">⠿</span>
      <span class="badge badge-ghost badge-xs w-16"><%= milestone_entry_kind(@entry) %></span>
      <% gift = @gifts_by_name[milestone_entry_gift(@entry)] %>
      <img :if={gift} src={gift.image_path} title={gift.name} class="w-6 h-6 rounded object-cover shrink-0" />
      <span :if={is_nil(gift)} class="w-6 h-6 shrink-0"></span>
      <span class="text-[11px] flex-1 truncate"><%= milestone_entry_label(@entry) %></span>
      <span :if={GiftPlans.pattern_ref?(@entry.ref)} class="text-[11px] text-base-content/50" title="Tier and affinity entries are always optional: bought if seen on the shelf">optional, buy if seen</span>
      <form :if={not GiftPlans.fixed_placement?(@entry.ref)} phx-change="set_entry_group">
        <input type="hidden" name="milestone_id" value={@milestone_id} />
        <input type="hidden" name="lib" value={@entry.lib} />
        <input type="hidden" name="def_id" value={@entry.definition["id"]} />
        <input :if={@entry.gift} type="hidden" name="gift" value={@entry.gift} />
        <select name="group" class="select select-bordered select-xs">
          <option value="" selected={is_nil(@entry.group) and not @entry.optional}>required</option>
          <option value="optional" selected={@entry.optional}>optional</option>
          <option :for={letter <- @letters} value={letter} selected={@entry.group == letter}>group <%= letter %></option>
          <option value="new">new group</option>
        </select>
      </form>
      <button type="button" phx-click="toggle_milestone" phx-value-milestone={@milestone_id}
              phx-value-lib={@entry.lib} phx-value-id={@entry.definition["id"]} phx-value-gift={@entry.gift}
              class="btn btn-ghost btn-2xs px-1 text-error" title="Remove from this milestone">✕</button>
    </div>
    """
  end

  attr :milestones, :list, required: true
  attr :assigned, :map, required: true
  attr :lib, :string, required: true
  attr :def_id, :string, required: true
  attr :gift, :string, default: nil

  def milestone_picker(assigns) do
    ~H"""
    <div :if={@milestones != []} class="flex items-center gap-1 flex-wrap">
      <span class="text-[10px] text-base-content/50">Milestones</span>
      <button :for={milestone <- @milestones} type="button" phx-click="toggle_milestone"
              phx-value-lib={@lib} phx-value-id={@def_id} phx-value-gift={@gift} phx-value-milestone={milestone["id"]}
              class={"btn btn-2xs " <> if(Map.has_key?(@assigned, milestone["id"]), do: "btn-secondary", else: "btn-outline")}>
        <%= milestone["name"] %><%= if group = @assigned[milestone["id"]], do: " · #{group}" %>
      </button>
    </div>
    """
  end

  attr :def_id, :string, required: true
  attr :routes, :list, required: true
  attr :tier, :integer, required: true
  attr :parent, :string, default: ""

  def route_list(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <div id={"routes-#{@def_id}-#{@parent}-#{@tier}"} phx-hook="SortableList" data-sort-event="rt_reorder"
           data-sort-scope={"#{@def_id}|#{@parent}|#{@tier}"} class="flex flex-col gap-1">
        <div :for={{route, index} <- Enum.with_index(@routes, 1)} data-sort-id={route["id"]}
             class="border border-base-300 rounded-lg p-1.5 flex flex-col gap-1 bg-base-100">
          <div class="flex items-center gap-2">
            <span data-sort-handle class="cursor-grab text-base-content/40 select-none px-1">⠿</span>
            <span class="text-[10px] text-base-content/40 w-4 text-right"><%= index %></span>
            <span class="text-xs font-semibold" style="font-family: ui-serif, Georgia, serif;"><%= combo_roman(route["combo"]) %></span>
            <span class="text-[10px] text-base-content/50"><%= combo_meta(route["combo"]) %></span>
            <span :if={label = combo_shops_label(Combos.shops(route["combo"], @tier))} class="badge badge-outline badge-xs"><%= label %></span>
            <button type="button" phx-click="rt_duplicate" phx-value-def_id={@def_id} phx-value-route_id={route["id"]}
                    class="btn btn-ghost btn-2xs ml-auto">Dup</button>
            <button type="button" phx-click="rt_delete" phx-value-def_id={@def_id} phx-value-route_id={route["id"]}
                    class="btn btn-ghost btn-2xs text-error">✕</button>
          </div>
          <form phx-change="rt_update" class="flex items-center gap-2 flex-wrap pl-8">
            <input type="hidden" name="def_id" value={@def_id} />
            <input type="hidden" name="route_id" value={route["id"]} />
            <label class="flex items-center gap-1">
              <span class="text-[11px] text-base-content/60">Buy missing</span>
              <select name="buy_up_to" class="select select-bordered select-xs">
                <option value="" selected={is_nil(route["buy_up_to"])}>don't buy</option>
                <option :for={tier <- 1..4} value={tier} selected={route["buy_up_to"] == tier}>up to T<%= tier %></option>
              </select>
            </label>
            <span class="text-[11px] text-base-content/60">Leftover required</span>
            <label :for={tier <- 1..4} class="flex items-center gap-0.5">
              <span class="text-[10px] text-base-content/50">T<%= tier %></span>
              <input type="number" min="0" name={"leftover[#{tier}]"} value={Routes.leftover_for(route, tier)}
                     phx-debounce="400" class="input input-bordered input-xs w-12" />
            </label>
          </form>
          <div :for={sub_tier <- Routes.subgoal_tiers(route["combo"])} class="pl-8 flex flex-col gap-1">
            <span class="text-[11px] text-base-content/60">
              Sub-goal: make T<%= sub_tier %>s
              <span :if={Routes.subgoals_for(route, sub_tier) == []} class="text-base-content/40">(empty: won't fuse for T<%= sub_tier %>)</span>
            </span>
            <.route_list def_id={@def_id} routes={Routes.subgoals_for(route, sub_tier)} tier={sub_tier} parent={route["id"]} />
          </div>
        </div>
      </div>
      <form phx-change="rt_add">
        <input type="hidden" name="def_id" value={@def_id} />
        <input type="hidden" name="parent" value={@parent} />
        <input type="hidden" name="tier" value={@tier} />
        <select name="combo" class="select select-bordered select-xs">
          <option value="" selected>+ add T<%= @tier %> route…</option>
          <option :for={%{combo: combo, shops: shops} <- selector_combos(@tier)} value={Combos.combo_key(combo)}>
            <%= Combos.combo_key(combo) %> · <%= combo_meta(combo) %><%= if label = combo_shops_label(shops), do: " · #{label}" %>
          </option>
        </select>
      </form>
    </div>
    """
  end

  attr :lib, :string, required: true
  attr :defs, :list, required: true
  attr :selected_id, :any, required: true
  attr :roles, :any, default: nil

  def library_list(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <div class="flex items-center gap-2">
        <span class="text-xs font-semibold text-base-content/70"><%= lib_heading(@lib) %></span>
        <%= if @lib == "fusions" do %>
          <button phx-click="lib_add" phx-value-lib={@lib} phx-value-type="tiered" class="btn btn-primary btn-xs ml-auto">+ Tiered</button>
          <button phx-click="lib_add" phx-value-lib={@lib} phx-value-type="fixed" class="btn btn-primary btn-xs">+ Fixed</button>
        <% else %>
          <button phx-click="lib_add" phx-value-lib={@lib} class="btn btn-primary btn-xs ml-auto">+ New</button>
        <% end %>
      </div>
      <div :for={definition <- @defs}
           phx-click="lib_select" phx-value-lib={@lib} phx-value-id={definition["id"]}
           class={"flex items-center gap-1 rounded px-2 py-1 cursor-pointer text-xs " <>
             if(definition["id"] == @selected_id, do: "bg-primary/10 border-l-2 border-primary", else: "hover:bg-base-200")}>
        <span class="flex-1 truncate"><%= definition["name"] %></span>
        <span :if={@lib == "fusions"} class={"badge badge-xs " <> if(GiftPlans.fixed_fusion?(definition), do: "badge-accent", else: "badge-ghost")}>
          <%= if GiftPlans.fixed_fusion?(definition), do: "fixed", else: "tiered" %>
        </span>
        <span :for={role <- if(@roles, do: @roles.(definition["id"]), else: [])} class="badge badge-ghost badge-xs"><%= role %></span>
        <button phx-click="lib_delete" phx-value-lib={@lib} phx-value-id={definition["id"]}
                data-confirm={"Delete '#{definition["name"]}'? Steps using it will break."}
                class="btn btn-ghost btn-2xs text-error">✕</button>
      </div>
      <div :if={@defs == []} class="text-[11px] text-base-content/40 italic">None yet.</div>
    </div>
    """
  end

  attr :step, :map, required: true
  attr :field, :string, required: true
  attr :defs, :list, required: true
  attr :label, :string, required: true

  def step_definition_list(assigns) do
    assigns = assign(assigns, :by_id, Map.new(assigns.defs, &{&1["id"], &1}))

    ~H"""
    <div class="flex items-center gap-1 flex-wrap">
      <span class="text-[11px] text-base-content/60"><%= @label %></span>
      <div id={"#{@field}-#{@step["id"]}"} phx-hook="SortableList" data-sort-event="reorder_step_field"
           data-sort-scope={"#{@step["id"]}:#{@field}"} class="flex items-center gap-1 flex-wrap">
        <span :for={id <- @step[@field] || []} data-sort-id={id}
              class={"badge badge-sm gap-1 " <> if(@by_id[id], do: "badge-secondary", else: "badge-error")}>
          <span data-sort-handle class="cursor-grab">⠿</span><%= if d = @by_id[id], do: d["name"], else: "(deleted)" %>
          <button type="button" phx-click="toggle_step_list_item" phx-value-id={@step["id"]} phx-value-field={@field} phx-value-item={id}>✕</button>
        </span>
      </div>
      <button :for={d <- Enum.reject(@defs, &(&1["id"] in (@step[@field] || [])))} type="button"
              phx-click="toggle_step_list_item" phx-value-id={@step["id"]} phx-value-field={@field} phx-value-item={d["id"]}
              class="btn btn-outline btn-2xs">+ <%= d["name"] %></button>
    </div>
    """
  end

  attr :lib, :string, required: true
  attr :definition, :map, required: true
  attr :clipboard, :any, required: true

  def gift_clipboard(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <button type="button" phx-click="gifts_copy" phx-value-lib={@lib} phx-value-def_id={@definition["id"]} class="btn btn-xs">Copy gifts</button>
      <button type="button" phx-click="gifts_paste" phx-value-lib={@lib} phx-value-def_id={@definition["id"]} class="btn btn-xs"
              disabled={is_nil(@clipboard)} data-confirm="Replace all gifts with the copied ones?">Paste gifts</button>
      <span :if={@clipboard} class="text-[11px] text-base-content/60">
        Clipboard: <%= @clipboard.name %> (<%= lib_label(@clipboard.lib) %>, <%= length(@clipboard.gifts) %> gift(s))
      </span>
    </div>
    """
  end

  attr :lib, :string, required: true
  attr :definition, :map, required: true
  attr :gifts_by_name, :map, required: true
  attr :selected_gift_name, :any, default: nil
  slot :extra

  def gift_order_list(assigns) do
    ~H"""
    <div id={"gift-order-#{@definition["id"]}"} phx-hook="SortableList" data-sort-event="lib_reorder_gifts"
         data-sort-scope={"#{@lib}:#{@definition["id"]}"} class="flex flex-col gap-1">
      <div :for={{name, index} <- Enum.with_index(@definition["gifts"], 1)} data-sort-id={name}
           class="flex items-center gap-2 bg-base-200 rounded px-1 py-0.5">
        <span data-sort-handle class="cursor-grab text-base-content/40 select-none px-1">⠿</span>
        <span class="text-[10px] text-base-content/40 w-4 text-right"><%= index %></span>
        <% gift = @gifts_by_name[name] %>
        <div phx-click={gift && "show_gift"} phx-value-gift={gift && name}
             class={"flex items-center gap-2 flex-1 min-w-0 " <> if(gift, do: "cursor-pointer", else: "")}>
          <img :if={gift} src={gift.image_path} class="w-6 h-6 rounded object-cover" />
          <span :if={gift} class="badge badge-ghost badge-xs">T<%= gift.tier %></span>
          <span :if={GiftPlans.pattern_entry?(name)} class="badge badge-secondary badge-xs">any</span>
          <span class={"text-[11px] flex-1 truncate " <> if(gift && @selected_gift_name == name, do: "font-semibold text-primary", else: "")}><%= GiftPlans.entry_label(name) %></span>
        </div>
        <%= render_slot(@extra, %{name: name, gift: gift}) %>
        <button phx-click="lib_toggle_gift" phx-value-lib={@lib} phx-value-id={@definition["id"]} phx-value-gift={name}
                class="btn btn-ghost btn-2xs px-1">✕</button>
      </div>
      <div :if={@definition["gifts"] == []} class="text-[11px] text-base-content/40 italic">
        No gifts yet. Pick one from the browser below.
      </div>
    </div>
    """
  end

  attr :gifts, :list, required: true
  attr :gifts_by_id, :map, required: true
  attr :gift_filter, :string, required: true
  attr :gift_tier_filter, :any, required: true
  attr :gift_affinity_filter, :any, required: true
  attr :gift_sort, :string, required: true
  attr :selected_gift_name, :any, required: true
  attr :uptie_view, :string, required: true
  attr :show_fusion_info, :boolean, default: false
  slot :form, required: true

  def gift_browser(assigns) do
    ~H"""
    <div class="flex-1 min-h-0 flex flex-col gap-2">
      <div class="flex flex-col gap-1">
        <div class="flex items-center gap-2 flex-wrap">
          <span class="text-xs font-medium text-base-content/70">Browse gifts</span>
          <input type="text" placeholder="Search gifts…" value={@gift_filter} phx-keyup="filter_gifts"
                 class="input input-bordered input-xs w-48" />
          <form phx-change="set_gift_tier_filter">
            <select name="value" class="select select-bordered select-xs">
              <option value="">any tier</option>
              <option :for={tier <- gift_tiers()} value={tier} selected={@gift_tier_filter == tier}>Tier <%= tier %></option>
            </select>
          </form>
          <form phx-change="set_gift_affinity_filter">
            <select name="value" class="select select-bordered select-xs">
              <option value="">any affinity</option>
              <option :for={affinity <- affinities()} value={affinity} selected={@gift_affinity_filter == affinity}><%= affinity %></option>
              <option disabled>──────────</option>
              <option value="none" selected={@gift_affinity_filter == "none"}>none</option>
            </select>
          </form>
          <form phx-change="set_gift_sort">
            <select name="value" class="select select-bordered select-xs">
              <option :for={sort_by <- gift_sorts()} value={sort_by} selected={@gift_sort == sort_by}>Sort: <%= gift_sort_label(sort_by) %></option>
            </select>
          </form>
        </div>

        <div class="grid gap-2 overflow-y-auto max-h-64 p-1" style="grid-template-columns: repeat(auto-fill, minmax(8.5rem, 1fr));">
          <div :for={gift <- filtered_gifts(@gifts, @gift_filter, @gift_tier_filter, @gift_affinity_filter, @gift_sort)}
               phx-click="select_gift" phx-value-gift={gift.name}
               class={"cursor-pointer flex items-center gap-1.5 p-1 rounded-lg " <>
                 if(@selected_gift_name == gift.name, do: "bg-primary/10", else: "hover:bg-base-200")}>
            <div class={"relative w-12 h-12 shrink-0 rounded-lg overflow-hidden bg-base-200 " <>
              if(@selected_gift_name == gift.name, do: "ring-2 ring-primary", else: "ring-1 ring-base-300")}>
              <img src={gift.image_path} class="w-full h-full object-cover" />
              <span :if={gift.tier} class="absolute top-0 left-0.5 font-black text-xs leading-none pointer-events-none"
                    style="font-family: ui-serif, Georgia, 'Times New Roman', serif; color: #fde047; text-shadow: -1px -1px 0 #7c2d12, 1px -1px 0 #7c2d12, -1px 1px 0 #7c2d12, 1px 1px 0 #7c2d12, 0 0 3px #f97316, 0 0 6px #ea580c;">
                <%= gift_tier_roman(gift.tier) %>
              </span>
              <img :if={gift.affinity not in [nil, "none"]} src={gift_affinity_icon(gift.affinity)} title={gift.affinity}
                   class="absolute bottom-0 right-0 w-3.5 h-3.5 object-contain drop-shadow" />
            </div>
            <span class="text-[10px] leading-tight line-clamp-3 flex-1 min-w-0" title={gift.name}><%= gift.name %></span>
          </div>
          <div :if={filtered_gifts(@gifts, @gift_filter, @gift_tier_filter, @gift_affinity_filter, @gift_sort) == []}
               class="col-span-full text-xs text-base-content/40 italic p-1">
            No matching gifts.
          </div>
        </div>
      </div>

      <div class="divider my-0"></div>

      <% selected = @selected_gift_name && Enum.find(@gifts, &(&1.name == @selected_gift_name)) %>
      <%= if selected do %>
        <div class="flex gap-2 border border-base-300 rounded-lg p-2">
          <div class="flex flex-col gap-2 flex-1 min-w-0">
            <div class="flex items-start gap-3">
              <img src={selected.image_path} class="w-16 h-16 rounded object-cover shrink-0" />
              <div class="flex flex-col gap-1 flex-1 min-w-0">
                <div class="text-sm font-semibold"><%= selected.name %></div>
                <div class="flex gap-1 flex-wrap">
                  <span class="badge badge-primary badge-xs">Tier <%= selected.tier %></span>
                  <span class="badge badge-ghost badge-xs"><%= selected.affinity %></span>
                  <span class="badge badge-ghost badge-xs"><%= selected.sin %></span>
                </div>
                <div class="text-xs text-base-content/70 flex gap-3">
                  <span>Buy: <%= selected.buying_cost || "—" %></span>
                  <span>Sell: <%= selected.selling_cost || "—" %></span>
                </div>
                <% obtain = obtain_method_text(selected, @gifts_by_id) %>
                <div :if={obtain} class="text-[11px] text-base-content/50 truncate" title={obtain}>
                  <%= obtain %>
                </div>
              </div>
            </div>

            <div class="flex items-center gap-1">
              <button :for={level <- uptie_views()} type="button"
                      phx-click="set_uptie_view" phx-value-level={level}
                      disabled={not uptie_view_available?(selected, level, @gifts_by_id)}
                      class={"btn btn-2xs " <>
                        cond do
                          @uptie_view == level -> "btn-secondary"
                          not uptie_view_available?(selected, level, @gifts_by_id) -> "btn-outline btn-disabled"
                          true -> "btn-outline"
                        end}>
                <%= uptie_view_icon(level) %>
              </button>
              <span class="text-[10px] text-base-content/40">uptie</span>
            </div>
            <p class="text-xs whitespace-pre-line"><%= gift_detail_text(selected, @uptie_view, @gifts_by_id) %></p>

            <%= if @show_fusion_info do %>
              <div class="border-t border-base-300 pt-1 flex flex-col gap-1">
                <%= if fusion_ingredient_ids(selected) != [] do %>
                  <span class="text-[11px] font-medium text-base-content/70">Fixed recipe — requires:</span>
                  <div class="flex flex-wrap gap-1">
                    <%= for ing_id <- fusion_ingredient_ids(selected) do %>
                      <span class="badge badge-outline badge-xs"><%= gift_ref_name(ing_id, @gifts_by_id) || ing_id %></span>
                    <% end %>
                  </div>
                <% else %>
                  <span class="text-[11px] text-base-content/50">
                    No fixed recipe — obtained via tier-based fusion (combine lower-tier <%= selected.affinity %> gifts).
                  </span>
                <% end %>
              </div>
            <% end %>
          </div>

          <div class="w-56 shrink-0 border-l border-base-300 pl-2 flex flex-col gap-2">
            <%= render_slot(@form, selected) %>
          </div>
        </div>
      <% else %>
        <div class="text-xs text-base-content/40 italic">Select a gift above to add it to the plan.</div>
      <% end %>
    </div>
    """
  end
end
