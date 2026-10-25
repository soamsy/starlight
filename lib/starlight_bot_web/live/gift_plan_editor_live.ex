defmodule StarlightBotWeb.Live.GiftPlanEditorLive do
  use StarlightBotWeb, :live_view
  import StarlightBotWeb.Components.ConditionTree
  import StarlightBotWeb.Components.PlanPicker

  alias StarlightBot.{Conditions, EgoGifts, GiftPlans, Plans, Teams}
  alias StarlightBot.GiftPlans.{Routes, RouteDefaults, Combos}

  embed_templates "gift_plan_editor/*"

  @tabs ~w(workflows shop loadout)a
  @gift_tiers 1..6
  @affinities ~w(bleed blunt burn charge pierce poise rupture sinking slash tremor)
  @gift_sorts ~w(default name tier affinity)
  @uptie_views ~w(base uptie2 uptie3)
  @stat_codes %{"cp" => "Clash Power", "fc" => "Final Power", "bc" => "Base Power", "cg" => "Coin Count"}
  @palette_kinds ~w(if refresh affinity_refresh skill_replace heal heal_all revive budget bail leave)
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
      |> assign(:route_shop, :normal)
      |> assign(:route_defaults, RouteDefaults.all())
      |> assign(:import_source, nil)
      |> assign(:gift_popup, nil)
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
    {:noreply, socket |> assign(:active_tab, String.to_existing_atom(tab)) |> assign(:selected_gift_name, nil) |> assign(:gift_popup, nil)}
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
  def handle_event("show_gift_popup", %{"gift" => gift, "x" => x, "y" => y} = params, socket) do
    view =
      case params["uptie"] do
        "1" -> "uptie2"
        "2" -> "uptie3"
        _ -> "base"
      end

    view = if (found = socket.assigns.gifts_by_name[gift]) && uptie_view_available?(found, view, socket.assigns.gifts_by_id), do: view, else: "base"
    {:noreply, assign(socket, :gift_popup, %{name: gift, x: x, y: y, view: view})}
  end

  @impl true
  def handle_event("set_gift_popup_view", %{"level" => level}, socket) when level in @uptie_views do
    {:noreply, update(socket, :gift_popup, &(&1 && %{&1 | view: level}))}
  end

  @impl true
  def handle_event("hide_gift_popup", _params, socket) do
    {:noreply, assign(socket, :gift_popup, nil)}
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
  def handle_event("set_route_shop", %{"shop" => shop}, socket) when shop in ~w(normal super) do
    {:noreply, assign(socket, :route_shop, String.to_existing_atom(shop))}
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
    workflow = %{"id" => GiftPlans.new_id("wf"), "name" => "Workflow #{length(data["workflows"]) + 1}", "steps" => []}

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
         Map.put(workflow, "name", String.trim(params["name"] || workflow["name"]))
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
  def handle_event("reorder_workflows", %{"ids" => ids}, socket) do
    {:noreply, update_plan(socket, &Map.update!(&1, "workflows", fn workflows -> reorder_by_ids(workflows, ids, fn wf -> wf["id"] end) end))}
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
  def handle_event("add_mounting_row", _, socket) do
    rows = socket.assigns.plan_data["mounting_trials"]
    next_floor = (rows |> Enum.map(& &1["from_floor"]) |> Enum.max(fn -> 0 end)) |> Kernel.+(1) |> min(15)
    mode = if rows == [], do: "avoid_hp", else: List.last(rows)["mode"]

    {:noreply, update_plan(socket, &Map.put(&1, "mounting_trials", sort_schedule(rows ++ [%{"from_floor" => next_floor, "mode" => mode}])))}
  end

  @impl true
  def handle_event("update_mounting", %{"rows" => rows}, socket) do
    modes = GiftPlans.mounting_trials_modes()

    rows =
      rows
      |> Enum.sort_by(fn {index, _row} -> String.to_integer(index) end)
      |> Enum.map(fn {_index, row} ->
        %{"from_floor" => parse_int(row["from_floor"], 1) |> max(1) |> min(15), "mode" => if(row["mode"] in modes, do: row["mode"], else: "best_gift")}
      end)
      |> sort_schedule()

    {:noreply, update_plan(socket, &Map.put(&1, "mounting_trials", rows))}
  end

  @impl true
  def handle_event("remove_mounting_row", %{"index" => index}, socket) do
    {:noreply, update_plan(socket, &Map.update!(&1, "mounting_trials", fn rows -> rows |> List.delete_at(String.to_integer(index)) |> sort_schedule() end))}
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
  def handle_event("add_step", %{"kind" => kind}, socket) do
    {:noreply, add_to_target(socket, GiftPlans.new_step(kind, socket.assigns.plan_data))}
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
  def handle_event("toggle_step_list_item", %{"id" => id, "field" => "options", "item" => item}, socket) do
    {:noreply,
     update_step(socket, id, fn step ->
       items = step["options"] || []
       Map.put(step, "options", if(item in items, do: List.delete(items, item), else: items ++ [item]))
     end)}
  end

  @impl true
  def handle_event("reorder_step_field", %{"scope" => scope, "ids" => ids}, socket) do
    [id, field] = String.split(scope, ":")
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
        op when op in ["milestone", "milestone_not"] -> %{"op" => op, "milestone" => blank_to_nil(params["milestone"])}
        op -> %{"op" => op, "gift" => String.trim(params["gift"] || "")}
      end

    {:noreply, update_condition(socket, params, &Conditions.put_leaf(&1, path, leaf))}
  end

  @impl true
  def handle_event("add_milestone", _, socket) do
    milestone = GiftPlans.new_milestone("Milestone #{length(socket.assigns.plan_data["milestones"]) + 1}")

    {:noreply,
     socket
     |> update_plan(&Map.update!(&1, "milestones", fn milestones -> milestones ++ [milestone] end))
     |> assign(:selected_milestone_id, milestone["id"])
     |> assign(:editing_milestone_id, milestone["id"])}
  end

  @impl true
  def handle_event("edit_milestone_name", %{"id" => id}, socket) do
    {:noreply, assign(socket, :editing_milestone_id, id)}
  end

  @impl true
  def handle_event("rename_milestone", %{"id" => id, "value" => name}, socket) do
    socket = assign(socket, :editing_milestone_id, nil)
    name = String.trim(name)
    {:noreply, if(name == "", do: socket, else: update_milestone(socket, id, &Map.put(&1, "name", name)))}
  end

  @impl true
  def handle_event("select_milestone", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:selected_milestone_id, id) |> assign(:fusion_entry_id, nil)}
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
  def handle_event("ms_add_gift", %{"gift" => name}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.add_gift(&1, socket.assigns.selected_milestone_id, name, socket.assigns.gifts_by_name, fn tier -> RouteDefaults.get(tier) end))}
  end

  @impl true
  def handle_event("ms_add_tier", %{"tier" => tier}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.add_pattern(&1, socket.assigns.selected_milestone_id, GiftPlans.tier_subject([String.to_integer(tier)])))}
  end

  @impl true
  def handle_event("ms_add_affinity", %{"affinity" => affinity, "tier" => tier}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.add_pattern(&1, socket.assigns.selected_milestone_id, GiftPlans.affinity_subject(affinity, [String.to_integer(tier)])))}
  end

  @impl true
  def handle_event("ms_add_action", %{"action" => action} = params, socket) do
    {:noreply, update_plan(socket, &GiftPlans.add_action(&1, socket.assigns.selected_milestone_id, action, params["sinner"]))}
  end

  @impl true
  def handle_event("ms_toggle_heal_sinner", %{"entry" => entry_id, "from" => from, "sinner" => sinner}, socket) do
    {:noreply,
     update_segment(socket, entry_id, from, fn segment ->
       picked = segment["sinners"] || []
       picked = if sinner in picked, do: List.delete(picked, sinner), else: picked ++ [sinner]
       Map.put(segment, "sinners", Enum.filter(Teams.all_sinners(), &(&1 in picked)))
     end)}
  end

  @impl true
  def handle_event("ms_toggle_skill_option", %{"entry" => entry_id, "from" => from, "option" => option}, socket) do
    {:noreply,
     update_segment(socket, entry_id, from, fn segment ->
       picked = segment["options"] || []
       picked = if option in picked, do: List.delete(picked, option), else: picked ++ [option]
       Map.put(segment, "options", Enum.filter(GiftPlans.skill_options(), &(&1 in picked)))
     end)}
  end

  @impl true
  def handle_event("ms_set_heal_repeat", %{"entry" => entry_id, "from" => from, "repeat" => repeat}, socket) when repeat in ~w(once 2 3 until_full) do
    {:noreply, update_segment(socket, entry_id, from, &Map.put(&1, "repeat", repeat))}
  end

  @impl true
  def handle_event("ms_add_refresh_case", _params, socket) do
    {:noreply, update_plan(socket, &GiftPlans.add_refresh_case(&1, socket.assigns.selected_milestone_id))}
  end

  @impl true
  def handle_event("ms_update_refresh_case", %{"case_id" => id, "action" => action} = params, socket) do
    {:noreply,
     update_plan(socket, &GiftPlans.update_refresh_case(&1, socket.assigns.selected_milestone_id, id, fn refresh_case ->
       Map.merge(refresh_case, %{
         "action" => if(action in GiftPlans.refresh_actions(), do: action, else: refresh_case["action"]),
         "affinity" => blank_to_nil(params["affinity"])
       })
     end))}
  end

  @impl true
  def handle_event("ms_remove_refresh_case", %{"case_id" => id}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.remove_refresh_case(&1, socket.assigns.selected_milestone_id, id))}
  end

  @impl true
  def handle_event("ms_reorder_refresh", %{"ids" => ids}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.reorder_refresh_cases(&1, socket.assigns.selected_milestone_id, ids))}
  end

  @impl true
  def handle_event("ms_remove_entry", %{"entry" => entry_id}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.remove_entry(&1, socket.assigns.selected_milestone_id, entry_id))}
  end

  @impl true
  def handle_event("ms_reorder_entries", %{"scope" => "group:" <> key, "ids" => ids}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.reorder_group(&1, socket.assigns.selected_milestone_id, key, ids))}
  end

  def handle_event("ms_reorder_entries", %{"scope" => id, "ids" => ids}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.reorder_entries(&1, id, ids))}
  end

  @impl true
  def handle_event("ms_move_entry", %{"scope" => "group:" <> key, "id" => entry_id, "ids" => ids}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.join_group(&1, socket.assigns.selected_milestone_id, entry_id, key, ids))}
  end

  def handle_event("ms_move_entry", %{"id" => entry_id, "ids" => ids}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.leave_group(&1, socket.assigns.selected_milestone_id, entry_id, ids))}
  end

  @impl true
  def handle_event("ms_update_segment", %{"entry" => entry_id, "from" => from, "segment" => params}, socket) do
    {:noreply,
     update_segment(socket, entry_id, from, fn segment ->
       segment
       |> Map.put("disposition", if(params["disposition"] in GiftPlans.dispositions(), do: params["disposition"], else: segment["disposition"]))
       |> apply_goal(params["goal"])
       |> Map.put("max", if(Map.has_key?(params, "max"), do: parse_optional_int(params["max"]), else: segment["max"]))
     end)}
  end

  @impl true
  def handle_event("ms_toggle", %{"entry" => entry_id, "from" => from, "field" => "fuse"}, socket) do
    {:noreply, socket |> ensure_fusion(entry_id) |> update_segment(entry_id, from, &Map.put(&1, "fuse", &1["fuse"] != true))}
  end

  def handle_event("ms_toggle", %{"entry" => entry_id, "from" => from, "field" => "buy"}, socket) do
    {:noreply,
     update_segment(socket, entry_id, from, fn segment ->
       if segment["buy"] == true and segment["disposition"] != "sell",
         do: Map.put(segment, "buy", false),
         else: Map.merge(segment, %{"buy" => true, "disposition" => if(segment["disposition"] == "sell", do: "keep", else: segment["disposition"])})
     end)}
  end

  def handle_event("ms_toggle", %{"entry" => entry_id, "from" => from, "field" => "sell"}, socket) do
    {:noreply,
     update_segment(socket, entry_id, from, fn segment ->
       if segment["disposition"] == "sell",
         do: Map.put(segment, "disposition", "keep"),
         else: Map.merge(segment, %{"disposition" => "sell", "buy" => false})
     end)}
  end

  @impl true
  def handle_event("ms_set_segment_mode", %{"entry" => entry_id, "from" => from, "mode" => mode}, socket) when mode in ~w(abandon change) do
    key = tab_key(socket, entry_id)

    {:noreply,
     socket
     |> for_group(entry_id, fn socket, id ->
       update_segment(socket, id, from, fn segment ->
         segment = Map.put(segment, "abandoned", mode == "abandon")
         if mode == "change" and segment["disposition"] == "ignore", do: Map.put(segment, "disposition", "keep"), else: segment
       end)
     end)
     |> assign(:entry_tabs, Map.put(socket.assigns.entry_tabs, key, String.to_integer(from)))}
  end

  @impl true
  def handle_event("ms_set_uptie", %{"entry" => entry_id, "from" => from, "level" => level}, socket) do
    level = level |> parse_int(0) |> max(0) |> min(GiftPlans.max_uptie())
    {:noreply, update_segment(socket, entry_id, from, &Map.put(&1, "uptie", level))}
  end

  @impl true
  def handle_event("ms_split", %{"entry" => entry_id, "floor" => floor}, socket) when floor != "" do
    floor = String.to_integer(floor)
    key = tab_key(socket, entry_id)

    {:noreply,
     socket
     |> for_group(entry_id, fn socket, id ->
       socket
       |> update_plan(&GiftPlans.split_entry(&1, socket.assigns.selected_milestone_id, id, floor))
       |> set_scheduled(id)
     end)
     |> assign(:entry_tabs, Map.put(socket.assigns.entry_tabs, key, floor))}
  end

  @impl true
  def handle_event("ms_split", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("ms_add_schedule", %{"entry" => entry_id}, socket) do
    {:noreply, set_scheduled(socket, entry_id)}
  end

  @impl true
  def handle_event("ms_remove_schedule", %{"entry" => entry_id}, socket) do
    {:noreply,
     for_group(socket, entry_id, fn socket, id ->
       socket
       |> update_segment(id, "1", fn segment ->
         segment = Map.put(segment, "abandoned", false)
         if segment["disposition"] == "ignore", do: Map.put(segment, "disposition", "keep"), else: segment
       end)
       |> update_plan(&GiftPlans.update_entry(&1, socket.assigns.selected_milestone_id, id, fn entry -> entry |> Map.put("scheduled", false) |> Map.delete("group") end))
     end)}
  end

  @impl true
  def handle_event("ms_move_segment", %{"entry" => entry_id, "from" => from, "to" => to}, socket) do
    to = String.to_integer(to)
    key = tab_key(socket, entry_id)

    {:noreply,
     socket
     |> for_group(entry_id, fn socket, id -> update_plan(socket, &GiftPlans.move_segment(&1, socket.assigns.selected_milestone_id, id, String.to_integer(from), to)) end)
     |> assign(:entry_tabs, Map.put(socket.assigns.entry_tabs, key, to))}
  end

  @impl true
  def handle_event("ms_remove_segment", %{"entry" => entry_id, "from" => from}, socket) do
    key = tab_key(socket, entry_id)

    {:noreply,
     socket
     |> for_group(entry_id, fn socket, id -> update_plan(socket, &GiftPlans.remove_segment(&1, socket.assigns.selected_milestone_id, id, String.to_integer(from))) end)
     |> assign(:entry_tabs, Map.delete(socket.assigns.entry_tabs, key))}
  end

  @impl true
  def handle_event("ms_select_tab", %{"entry" => entry_id, "from" => from}, socket) do
    {:noreply, assign(socket, :entry_tabs, Map.put(socket.assigns.entry_tabs, tab_key(socket, entry_id), String.to_integer(from)))}
  end

  @impl true
  def handle_event("ms_add_goal", _params, socket) do
    {:noreply, update_plan(socket, &GiftPlans.add_goal(&1, socket.assigns.selected_milestone_id))}
  end

  @impl true
  def handle_event("ms_set_goal_min", %{"letter" => letter, "min" => min}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.set_goal_min(&1, socket.assigns.selected_milestone_id, letter, parse_int(min, 1)))}
  end

  @impl true
  def handle_event("ms_remove_goal", %{"letter" => letter}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.remove_goal(&1, socket.assigns.selected_milestone_id, letter))}
  end

  @impl true
  def handle_event("ms_open_fusion", %{"entry" => entry_id}, socket) do
    {:noreply, assign(socket, :fusion_entry_id, entry_id)}
  end

  @impl true
  def handle_event("ms_close_fusion", _params, socket) do
    {:noreply, assign(socket, :fusion_entry_id, nil)}
  end

  @impl true
  def handle_event("rt_copy", %{"def_id" => id}, socket) do
    {entry, gift} = fusion_entry(socket, id)
    clipboard = %{name: gift.name, tier: gift.tier, routes: entry["fusion"]["routes"] || []}
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
    {entry, %{tier: tier}} = fusion_entry(socket, id)

    case RouteDefaults.put(tier, entry["fusion"]["routes"] || []) do
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
    {_entry, %{tier: tier}} = fusion_entry(socket, id)
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

  def tab_label(:workflows), do: "Workflows"
  def tab_label(:shop), do: "Shop"
  def tab_label(:loadout), do: "Loadout"

  def accent_tab?(tab), do: tab in [:loadout]

  def searchable_gifts(gifts), do: Enum.filter(gifts, &GiftPlans.gift_searchable?/1)

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

  def active_from(entry_tabs, entry) do
    froms = Enum.map(entry["floors"], & &1["from"])

    case entry_tabs[GiftPlans.group_key(entry)] do
      from when is_integer(from) -> if from in froms, do: from, else: hd(froms)
      _ -> hd(froms)
    end
  end

  def segment_label(entry, from) do
    next = entry["floors"] |> Enum.map(& &1["from"]) |> Enum.filter(&(&1 > from)) |> Enum.min(fn -> nil end)

    cond do
      is_nil(next) -> "F#{from}+"
      next - 1 == from -> "F#{from}"
      true -> "F#{from}-#{next - 1}"
    end
  end

  @required_colors {"border-base-content/20 bg-base-content/10", "bg-neutral border-neutral text-neutral-content"}

  @goal_colors [
    {"bg-sky-500/15 border-sky-500/50", "bg-sky-600 border-sky-700 text-white"},
    {"bg-amber-500/15 border-amber-500/50", "bg-amber-600 border-amber-700 text-white"},
    {"bg-emerald-500/15 border-emerald-500/50", "bg-emerald-600 border-emerald-700 text-white"},
    {"bg-fuchsia-500/15 border-fuchsia-500/50", "bg-fuchsia-600 border-fuchsia-700 text-white"},
    {"bg-orange-500/15 border-orange-500/50", "bg-orange-600 border-orange-700 text-white"},
    {"bg-teal-500/15 border-teal-500/50", "bg-teal-600 border-teal-700 text-white"},
    {"bg-violet-500/15 border-violet-500/50", "bg-violet-600 border-violet-700 text-white"},
    {"bg-lime-500/15 border-lime-500/50", "bg-lime-600 border-lime-700 text-white"}
  ]

  defp goal_colors("required"), do: @required_colors
  defp goal_colors(<<letter, _::binary>>), do: Enum.at(@goal_colors, rem(letter - ?A, length(@goal_colors)))

  def goal_color(goal), do: elem(goal_colors(goal), 0)

  def goal_select_color("optional"), do: ""
  def goal_select_color(goal), do: elem(goal_colors(goal), 1)

  def action_repeats("heal"), do: [{"once", "Once each"}, {"until_full", "Until healed"}]
  def action_repeats("heal_all"), do: [{"once", "1 time"}, {"2", "2 times"}, {"3", "3 times"}, {"until_full", "Until all healed"}]
  def action_repeats(_action), do: []

  def goal_label("required"), do: "Required"
  def goal_label("optional"), do: "Optional"
  def goal_label("abandon"), do: "Abandon"
  def goal_label(letter), do: "Goal #{letter}"

  def goal_member_count(milestone, letter) do
    Enum.count(milestone["entries"] || [], fn entry -> Enum.any?(entry["floors"], &(&1["goal"] == letter and &1["disposition"] == "keep")) end)
  end

  def uptie_title(nil, _level), do: nil
  def uptie_title(_gift, 0), do: "No uptie"

  def uptie_title(gift, level) do
    case GiftPlans.uptie_cost(gift.tier, 0, level) do
      nil -> "Uptie to +#{level}"
      cost -> "Uptie to +#{level} (#{cost} from +0, estimate)"
    end
  end

  def recipe_parts(milestone, gift, gifts_by_id) do
    names = for name <- GiftPlans.recipe_names(gift, gifts_by_id), do: {name, GiftPlans.has_gift?(milestone, name)}
    slots = GiftPlans.fragment_slots(gift)
    fragments = Enum.count(milestone["entries"] || [], &(GiftPlans.subject_gift(&1) in GiftPlans.sin_fragments()))
    if slots > 0, do: names ++ [{"#{slots} Sin Fragments", fragments >= slots}], else: names
  end

  def step_broken?(data, step), do: match?({:error, _}, GiftPlans.definition_for(data, step))

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

  def combo_sum(combo), do: Enum.join(combo, "+")

  def combo_shops_label([:normal, :super]), do: nil
  def combo_shops_label([:normal]), do: "normal only"
  def combo_shops_label([:super]), do: "super only"
  def combo_shops_label([]), do: "can't make this tier"

  def route_in_shop?(route, tier, shop) do
    case Combos.shops(route["combo"], tier) do
      [] -> true
      shops -> shop in shops
    end
  end

  def selector_combos(tier, shop) do
    tier |> Combos.valid_combos() |> Enum.filter(&(shop in &1.shops)) |> Enum.sort_by(&{&1.shops == [:super], Enum.max(&1.combo) >= tier, &1.points})
  end

  def combo_meta(combo), do: "#{Combos.points(combo)} pts · #{Combos.keyword_odds(combo)}% keyword"

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
    |> assign(:selected_milestone_id, nil)
    |> assign(:editing_milestone_id, nil)
    |> assign(:entry_tabs, %{})
    |> assign(:fusion_entry_id, nil)
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
        |> assign(:selected_milestone_id, first_id(data["milestones"]))
        |> assign(:editing_milestone_id, nil)
        |> assign(:entry_tabs, %{})
        |> assign(:fusion_entry_id, nil)
        |> assign(:add_target, "")
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

  defp update_condition(socket, %{"case_id" => id}, fun) do
    update_plan(socket, &GiftPlans.update_refresh_case(&1, socket.assigns.selected_milestone_id, id, fn refresh_case ->
      Map.put(refresh_case, "condition", refresh_case["condition"] |> fun.() |> GiftPlans.prune_condition())
    end))
  end

  defp update_condition(socket, %{"step_id" => id}, fun) do
    update_step(socket, id, fn step -> Map.put(step, "condition", step["condition"] |> fun.() |> GiftPlans.prune_condition()) end)
  end

  defp update_milestone(socket, id, fun), do: update_plan(socket, &GiftPlans.update_milestone(&1, id, fun))

  defp update_routes(socket, entry_id, fun) do
    update_plan(socket, &GiftPlans.update_entry(&1, socket.assigns.selected_milestone_id, entry_id, fn entry ->
      Map.update!(entry, "fusion", fn fusion -> Map.update(fusion, "routes", fun.([]), fun) end)
    end))
  end

  defp apply_goal(segment, nil), do: segment
  defp apply_goal(segment, "abandon"), do: Map.put(segment, "abandoned", true)

  defp apply_goal(segment, goal) do
    segment = Map.merge(segment, %{"goal" => goal, "abandoned" => false})
    if segment["disposition"] == "ignore", do: Map.put(segment, "disposition", "keep"), else: segment
  end

  defp set_scheduled(socket, entry_id) do
    update_plan(socket, &GiftPlans.update_entry(&1, socket.assigns.selected_milestone_id, entry_id, fn entry -> Map.put(entry, "scheduled", true) end))
  end

  defp tab_key(socket, entry_id), do: GiftPlans.group_key(GiftPlans.find_entry(selected_milestone(socket.assigns), entry_id))

  defp for_group(socket, entry_id, fun) do
    socket.assigns
    |> selected_milestone()
    |> GiftPlans.group_members(entry_id)
    |> Enum.reduce(socket, &fun.(&2, &1["id"]))
  end

  defp update_segment(socket, entry_id, from, fun) do
    update_plan(socket, &GiftPlans.update_segment(&1, socket.assigns.selected_milestone_id, entry_id, String.to_integer(from), fun))
  end

  defp ensure_fusion(socket, entry_id) do
    case fusion_entry(socket, entry_id) do
      {%{"fusion" => nil}, %{} = gift} ->
        fusion = GiftPlans.default_fusion(gift, &RouteDefaults.get/1)
        update_plan(socket, &GiftPlans.update_entry(&1, socket.assigns.selected_milestone_id, entry_id, fn entry -> Map.put(entry, "fusion", fusion) end))

      _ ->
        socket
    end
  end

  defp fusion_entry(socket, entry_id) do
    entry = socket.assigns |> selected_milestone() |> GiftPlans.find_entry(entry_id)
    {entry, socket.assigns.gifts_by_name[GiftPlans.subject_gift(entry)]}
  end

  defp apply_step_params(%{"kind" => "milestone"} = step, p), do: Map.put(step, "milestone", blank_to_nil(p["milestone"]))
  defp apply_step_params(%{"kind" => "affinity_refresh"} = step, p), do: Map.put(step, "affinity", blank_to_nil(p["affinity"]))

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
      <option value="milestone" selected={@node["op"] == "milestone"}>milestone reached</option>
      <option value="milestone_not" selected={@node["op"] == "milestone_not"}>milestone not reached</option>
    </select>
    <%= cond do %>
      <% @node["op"] in ["cost_gte", "cost_lt", "refreshes_lt", "refreshes_gte"] -> %>
        <input type="number" name="value" value={@node["value"]} phx-debounce="400" class="input input-bordered input-xs w-24" />
      <% @node["op"] in ["milestone", "milestone_not"] -> %>
        <select name="milestone" class="select select-bordered select-xs flex-1 min-w-0">
          <option value="">pick one</option>
          <option :for={milestone <- @plan_data["milestones"]} value={milestone["id"]} selected={@node["milestone"] == milestone["id"]}><%= milestone["name"] %></option>
        </select>
      <% true -> %>
        <input type="text" name="gift" value={@node["gift"]} list="gift-name-options" phx-debounce="blur"
               placeholder="Gift name" class="input input-bordered input-xs flex-1 min-w-0" />
    <% end %>
    """
  end

  attr :entry, :map, required: true
  attr :members, :list, required: true
  attr :from, :integer, required: true

  def schedule_tabs(assigns) do
    froms = Enum.map(assigns.entry["floors"], & &1["from"])

    abandoned_by_from =
      Map.new(froms, fn from ->
        {from,
         Enum.map(assigns.members, fn member ->
           segment = Enum.find(member["floors"], &(&1["from"] == from))
           segment != nil and GiftPlans.abandoned?(member, segment)
         end)}
      end)

    assigns =
      assign(assigns,
        froms: froms,
        abandoned_froms: for({from, flags} <- abandoned_by_from, Enum.all?(flags), do: from),
        kept_froms: for({from, flags} <- abandoned_by_from, not Enum.any?(flags), do: from)
      )

    ~H"""
      <div class="flex items-end gap-0.5">
        <span data-sort-handle class="cursor-grab text-base-content/40 select-none px-1 pb-0.5" title="Drag this schedule and its entries">⠿</span>
        <div :for={from <- @froms}
             class={"flex items-center gap-0.5 rounded-t-lg border border-b-0 px-2 py-0.5 text-[11px] " <>
               if(from == @from, do: "border-primary bg-primary text-primary-content font-semibold", else: "border-primary/40 bg-primary/25 hover:bg-primary/40")}
             style={if from in @abandoned_froms, do: StarlightBotWeb.Live.PackPlanEditorLive.disabled_stripes_style()}>
          <button type="button" phx-click="ms_select_tab" phx-value-entry={@entry["id"]} phx-value-from={from}><%= segment_label(@entry, from) %></button>
          <div class="dropdown">
            <div tabindex="0" role="button" class="cursor-pointer opacity-60 hover:opacity-100" title={if from == 1, do: "Start later", else: "Change or abandon from a floor"}>
              <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" class="w-3 h-3"><path d="m6 9 6 6 6-6" /></svg>
            </div>
            <div tabindex="0" class={"dropdown-content z-30 mt-1 rounded-lg border border-base-300 bg-base-100 p-1.5 shadow-lg space-y-1 " <> if(from == 1, do: "w-max", else: "w-56")}>
              <button :if={from == 1} type="button" phx-click="ms_set_segment_mode" phx-value-entry={@entry["id"]} phx-value-from={from}
                      phx-value-mode={if from in @abandoned_froms, do: "change", else: "abandon"}
                      class={"btn btn-xs " <> if(from in @abandoned_froms, do: "btn-primary", else: "btn-outline")}>Start later</button>
              <div :if={from != 1} class="join w-full">
                <button :for={{mode, label} <- [{"change", "Change at"}, {"abandon", "Abandon at"}]} type="button" phx-click="ms_set_segment_mode"
                        phx-value-entry={@entry["id"]} phx-value-from={from} phx-value-mode={mode}
                        class={"btn btn-xs join-item flex-1 whitespace-nowrap " <> if(from in if(mode == "abandon", do: @abandoned_froms, else: @kept_froms), do: "btn-primary", else: "btn-outline")}><%= label %></button>
              </div>
              <div :if={from != 1} class="grid grid-cols-5 gap-0.5">
                <button :for={floor <- 2..GiftPlans.max_floor()} type="button" phx-click="ms_move_segment" phx-value-entry={@entry["id"]}
                        phx-value-from={from} phx-value-to={floor} disabled={floor != from and floor in @froms}
                        class={"btn btn-xs " <> if(floor == from, do: "btn-primary", else: "btn-ghost")}>F<%= floor %></button>
              </div>
            </div>
          </div>
          <button :if={from != 1} type="button" phx-click="ms_remove_segment" phx-value-entry={@entry["id"]} phx-value-from={from}
                  class="opacity-60 hover:opacity-100" title={"Close this tab; #{segment_label(@entry, from)} use the earlier tab's settings"}>✕</button>
          <button :if={from == 1 and length(@froms) == 1} type="button" phx-click="ms_remove_schedule" phx-value-entry={@entry["id"]}
                  class="opacity-60 hover:opacity-100" title="Remove the schedule">✕</button>
        </div>
        <button type="button" phx-click="ms_split" phx-value-entry={@entry["id"]} phx-value-floor={Enum.max(@froms) + 1}
                disabled={Enum.max(@froms) >= GiftPlans.max_floor()} title="New tab"
                class="rounded-t-lg border border-b-0 border-dashed border-primary/60 px-2 py-0.5 text-[11px] text-primary hover:bg-primary/20 disabled:opacity-30">+</button>
      </div>
    """
  end

  attr :milestone, :map, required: true
  attr :entry_tabs, :map, required: true
  attr :gifts_by_name, :map, required: true
  attr :gifts_by_id, :map, required: true

  def milestone_entries(assigns) do
    ~H"""
    <div id={"milestone-entries-#{@milestone["id"]}"} phx-hook="SortableList" data-sort-event="ms_reorder_entries" data-sort-move-event="ms_move_entry"
         data-sort-shared={"ms-#{@milestone["id"]}"} data-sort-scope={@milestone["id"]} class="flex flex-col gap-1">
      <%= for chunk <- entry_chunks(@milestone["entries"]) do %>
        <%= case chunk do %>
          <% {:single, entry} -> %>
            <.milestone_entry_row entry={entry} milestone={@milestone} from={active_from(@entry_tabs, entry)} in_group={false}
                                  gifts_by_name={@gifts_by_name} gifts_by_id={@gifts_by_id} />
          <% {:group, key, [lead | _] = members} -> %>
            <div data-sort-id={"group:#{key}"} data-sort-stay class="flex flex-col">
              <.schedule_tabs entry={lead} members={members} from={active_from(@entry_tabs, lead)} />
              <div id={"entry-group-#{key}"} phx-hook="SortableList" data-sort-event="ms_reorder_entries" data-sort-move-event="ms_move_entry"
                   data-sort-shared={"ms-#{@milestone["id"]}"} data-sort-scope={"group:#{key}"} data-sort-highlight
                   class="flex flex-col gap-1 min-h-8 p-1 border-2 border-primary rounded-b-lg rounded-tr-lg transition-colors">
                <.milestone_entry_row :for={entry <- members} entry={entry} milestone={@milestone} from={active_from(@entry_tabs, entry)} in_group={true}
                                      gifts_by_name={@gifts_by_name} gifts_by_id={@gifts_by_id} />
              </div>
            </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp scheduled?(entry), do: entry["scheduled"] == true or length(entry["floors"]) > 1

  def entry_chunks(entries) do
    entries
    |> Enum.chunk_by(&if(scheduled?(&1), do: {:group, GiftPlans.group_key(&1)}, else: {:single, &1["id"]}))
    |> Enum.map(fn [first | _] = run -> if scheduled?(first), do: {:group, GiftPlans.group_key(first), run}, else: {:single, first} end)
  end

  attr :entry, :map, required: true
  attr :milestone, :map, required: true
  attr :from, :integer, required: true
  attr :in_group, :boolean, required: true
  attr :gifts_by_name, :map, required: true
  attr :gifts_by_id, :map, required: true

  def milestone_entry_row(assigns) do
    entry = assigns.entry
    segment = Enum.find(entry["floors"], &(&1["from"] == assigns.from))
    pattern? = GiftPlans.pattern_entry?(entry)
    action? = GiftPlans.action_entry?(entry)
    gift = assigns.gifts_by_name[GiftPlans.subject_gift(entry)]
    abandoned? = GiftPlans.abandoned?(entry, segment)
    sell? = not abandoned? and segment["disposition"] == "sell"
    keep? = not abandoned? and not sell? and not pattern?
    buy? = not abandoned? and not sell? and segment["buy"] == true
    made_from = keep? and segment["fuse"] == true and GiftPlans.fixed_fusion?(entry) and gift && recipe_parts(assigns.milestone, gift, assigns.gifts_by_id)

    assigns =
      assign(assigns,
        segment: segment,
        pattern?: pattern?,
        action?: action?,
        gift: gift,
        keep?: keep?,
        sell?: sell?,
        buy?: buy?,
        abandoned?: abandoned?,
        made_from: made_from || nil,
        fusable?: entry["fusion"] != nil or (gift != nil and GiftPlans.fusable?(gift)),
        uptie?: gift != nil and String.trim(gift.uptie2 || "") != "",
        surface:
          cond do
            abandoned? -> "border-base-300 bg-base-100"
            sell? -> "border-error/40 bg-[color-mix(in_oklab,var(--color-error)_5%,var(--color-base-100))]"
            action? and entry["subject"]["action"] == "skill_replace" -> "border-info/40 bg-info/10"
            action? -> "border-success/40 bg-success/10"
            keep? and segment["goal"] == "optional" -> "border-base-content/10 bg-base-300"
            keep? -> goal_color(segment["goal"] || "required")
            true -> "border-base-300 bg-base-200"
          end
      )

    ~H"""
    <form data-sort-id={@entry["id"]} phx-change="ms_update_segment"
          class={"border px-1 py-1 flex items-center gap-2 flex-wrap " <> @surface <> " rounded"}
          style={
            cond do
              @abandoned? -> StarlightBotWeb.Live.PackPlanEditorLive.disabled_stripes_style()
              @keep? and @segment["goal"] == "optional" -> "background-image: radial-gradient(color-mix(in oklab, var(--color-base-content) 16%, transparent) 0.9px, transparent 1.2px), radial-gradient(color-mix(in oklab, var(--color-base-content) 16%, transparent) 0.9px, transparent 1.2px); background-size: 8px 8px; background-position: -2px -2px, 2px 2px; background-clip: padding-box"
              true -> nil
            end
          }>
      <input type="hidden" name="entry" value={@entry["id"]} />
      <input type="hidden" name="from" value={@from} />
      <span data-sort-handle class="cursor-grab text-base-content/40 select-none px-1">⠿</span>
      <div class="w-24 shrink-0">
        <select :if={@keep? or (@abandoned? and not @pattern?)} name="segment[goal]"
                class={"select select-bordered select-xs w-full " <> if(@abandoned?, do: "", else: goal_select_color(@segment["goal"] || "required"))}>
          <option :for={goal <- ["required", "optional" | GiftPlans.goal_letters(@milestone)] ++ ["abandon"]} value={goal}
                  selected={if @abandoned?, do: goal == "abandon", else: (@segment["goal"] || "required") == goal}><%= goal_label(goal) %></option>
        </select>
      </div>
      <div class="flex items-center gap-1.5 w-52 min-w-0 shrink-0">
        <img :if={@gift} src={@gift.image_path} data-gift-popup={@gift.name} data-gift-uptie={@keep? && @segment["uptie"]} class="w-6 h-6 rounded object-cover shrink-0 cursor-pointer" />
        <span :if={@gift} class="badge badge-ghost badge-xs">T<%= @gift.tier %></span>
        <span :if={@pattern? and not @action?} class="badge badge-secondary badge-xs">any</span>
        <span :if={@action?} class={"badge badge-xs " <> if(@entry["subject"]["action"] == "skill_replace", do: "badge-info", else: "badge-success")}>
          <%= if @entry["subject"]["action"] == "skill_replace", do: "skill", else: "heal" %>
        </span>
        <span data-gift-popup={@gift && @gift.name} data-gift-uptie={@keep? && @segment["uptie"]} class={"text-xs font-medium truncate " <> if(@gift, do: "cursor-pointer select-none", else: "")} title={GiftPlans.subject_label(@entry["subject"])}><%= GiftPlans.subject_label(@entry["subject"]) %></span>
        <span :if={@action? and not @abandoned?} class="ml-auto pr-1 text-[11px] text-base-content/60 whitespace-nowrap">
          Cost <%= case GiftPlans.action_cost_range(@entry["subject"]["action"], @segment) do
            {same, same} -> same
            {low, high} -> "#{low}-#{high}"
          end %>
        </span>
      </div>
      <%= cond do %>
      <% @abandoned? -> %>
        <span class="text-[11px] font-semibold text-base-content/60"><%= if @from == 1, do: "Not started", else: "Abandoned" %></span>
      <% @action? -> %>
        <div :if={@entry["subject"]["action"] in ["heal", "revive", "skill_replace"]} class="grid grid-cols-6 gap-0.5">
          <button :for={sinner <- Teams.all_sinners()} type="button" phx-click="ms_toggle_heal_sinner"
                  phx-value-entry={@entry["id"]} phx-value-from={@from} phx-value-sinner={sinner}
                  class={"btn btn-xs " <> if(sinner in (@segment["sinners"] || []), do: "btn-success", else: "btn-outline")}><%= sinner_label(sinner) %></button>
        </div>
        <div :if={@entry["subject"]["action"] == "skill_replace"} class="join">
          <button :for={option <- GiftPlans.skill_options()} type="button" phx-click="ms_toggle_skill_option"
                  phx-value-entry={@entry["id"]} phx-value-from={@from} phx-value-option={option}
                  class={"btn btn-xs join-item " <> if(option in (@segment["options"] || []), do: "btn-info", else: "btn-outline")}><%= skill_option_label(option) %></button>
        </div>
        <div :if={action_repeats(@entry["subject"]["action"]) != []} class="join">
          <button :for={{repeat, label} <- action_repeats(@entry["subject"]["action"])} type="button" phx-click="ms_set_heal_repeat"
                  phx-value-entry={@entry["id"]} phx-value-from={@from} phx-value-repeat={repeat}
                  class={"btn btn-xs join-item " <> if((@segment["repeat"] || "once") == repeat, do: "btn-success", else: "btn-outline")}><%= label %></button>
        </div>
      <% true -> %>
        <div class="min-w-16 shrink-0">
          <div :if={not @pattern? and @uptie?} class="join">
            <% current = @segment["uptie"] || 0 %>
            <button :for={{level, icon} <- Enum.zip(1..GiftPlans.max_uptie(), ~w(+ ++))} type="button" phx-click="ms_set_uptie"
                    phx-value-entry={@entry["id"]} phx-value-from={@from} phx-value-level={if current == level, do: 0, else: level}
                    disabled={not @keep?} title={uptie_title(@gift, level)}
                    class={"btn btn-xs join-item " <> if(@keep? and level <= current, do: "btn-secondary", else: "btn-outline")}>
              <%= icon %>
            </button>
          </div>
        </div>
        <div class="join">
          <button type="button" phx-click="ms_toggle" phx-value-entry={@entry["id"]} phx-value-from={@from} phx-value-field="buy"
                  class={"btn btn-xs join-item " <> if(@buy?, do: "btn-secondary", else: "btn-outline")}>Buy</button>
          <button type="button" phx-click="ms_toggle" phx-value-entry={@entry["id"]} phx-value-from={@from} phx-value-field="sell"
                  class={"btn btn-xs join-item " <> if(@sell?, do: "btn-error", else: "btn-outline")}>Sell</button>
        </div>
        <div class="min-w-20 shrink-0">
          <div :if={not @pattern?} class="join">
            <button type="button" phx-click="ms_toggle" phx-value-entry={@entry["id"]} phx-value-from={@from} phx-value-field="fuse"
                    disabled={not @keep? or not @fusable?}
                    title={if not @fusable?, do: "This gift can't be fused"}
                    class={"btn btn-xs join-item " <> if(@keep? and @segment["fuse"] == true and @entry["fusion"], do: "btn-secondary", else: "btn-outline")}>
              Fuse
            </button>
            <button :if={@entry["fusion"] != nil and @keep? and @segment["fuse"] == true} type="button" phx-click="ms_open_fusion" phx-value-entry={@entry["id"]}
                    class="btn btn-xs btn-outline join-item" title="Fusion settings">⚙</button>
          </div>
        </div>
        <label :if={@sell? or (@pattern? and @buy?)} class="flex items-center gap-1">
          <span class="text-[11px] text-base-content/60">Max per floor</span>
          <input type="number" min="1" name="segment[max]" value={@segment["max"]} placeholder="no cap" phx-debounce="400" class="input input-bordered input-xs w-20" />
        </label>
      <% end %>
      <span :if={@made_from} class="text-[11px] text-base-content/60 truncate min-w-0 max-w-64">
        Made from:
        <%= for {{name, present?}, index} <- Enum.with_index(@made_from) do %><%= if index > 0, do: ", " %><span class={if present?, do: "", else: "text-error font-semibold"}><%= name %></span><% end %>
      </span>
      <button :if={not @in_group} type="button" phx-click="ms_add_schedule" phx-value-entry={@entry["id"]} class="btn btn-ghost btn-xs ml-auto">Add Schedule</button>
      <button type="button" phx-click="ms_remove_entry" phx-value-entry={@entry["id"]}
              class={"btn btn-ghost btn-xs px-1 text-error " <> if(@in_group, do: "ml-auto", else: "")} title="Remove from this milestone">✕</button>
    </form>
    """
  end

  attr :gift, :map, required: true
  attr :milestone, :map, required: true
  attr :gifts_by_id, :map, required: true
  attr :gifts_by_name, :map, required: true

  def recipe_tree(assigns) do
    ~H"""
    <ul class="pl-4 flex flex-col gap-0.5 list-disc">
      <li :for={{name, present?} <- recipe_parts(@milestone, @gift, @gifts_by_id)} class="text-[11px]">
        <span class={if present?, do: "", else: "text-error font-semibold"}><%= name %></span>
        <span :if={not present?} class="text-error">(not in this milestone)</span>
        <% ingredient = @gifts_by_name[name] %>
        <.recipe_tree :if={ingredient && GiftPlans.fixed_recipe?(ingredient)} gift={ingredient} milestone={@milestone} gifts_by_id={@gifts_by_id} gifts_by_name={@gifts_by_name} />
      </li>
    </ul>
    """
  end

  attr :def_id, :string, required: true
  attr :routes, :list, required: true
  attr :tier, :integer, required: true
  attr :shop, :atom, required: true
  attr :parent, :string, default: ""

  def route_list(assigns) do
    assigns = assign(assigns, :visible, Enum.filter(assigns.routes, &route_in_shop?(&1, assigns.tier, assigns.shop)))

    ~H"""
    <div class="flex flex-col gap-1">
      <div id={"routes-#{@def_id}-#{@parent}-#{@tier}"} phx-hook="SortableList" data-sort-event="rt_reorder"
           data-sort-scope={"#{@def_id}|#{@parent}|#{@tier}"} class="flex flex-col gap-1">
        <div :for={{route, index} <- Enum.with_index(@visible, 1)} data-sort-id={route["id"]}
             class="border border-base-300 rounded-lg p-1.5 flex flex-col gap-1 bg-base-100">
          <div class="flex items-center gap-2">
            <span data-sort-handle class="cursor-grab text-base-content/40 select-none px-1">⠿</span>
            <span class="text-[10px] text-base-content/40 w-4 text-right"><%= index %></span>
            <span class="text-xs font-semibold"><%= combo_sum(route["combo"]) %></span>
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
            <.route_list def_id={@def_id} routes={Routes.subgoals_for(route, sub_tier)} tier={sub_tier} shop={@shop} parent={route["id"]} />
          </div>
        </div>
      </div>
      <span :if={length(@visible) < length(@routes)} class="text-[11px] text-base-content/40 italic">
        <%= length(@routes) - length(@visible) %> more route(s) only work in the <%= if @shop == :normal, do: "super", else: "normal" %> shop.
      </span>
      <form phx-change="rt_add">
        <input type="hidden" name="def_id" value={@def_id} />
        <input type="hidden" name="parent" value={@parent} />
        <input type="hidden" name="tier" value={@tier} />
        <select name="combo" class="select select-bordered select-xs">
          <option value="" selected>+ add T<%= @tier %> route…</option>
          <option :for={%{combo: combo, shops: shops} <- selector_combos(@tier, @shop)} value={Combos.combo_key(combo)}>
            <%= combo_sum(combo) %> · <%= combo_meta(combo) %><%= if label = combo_shops_label(shops), do: " · #{label}" %>
          </option>
        </select>
      </form>
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
