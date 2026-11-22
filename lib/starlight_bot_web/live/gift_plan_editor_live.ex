defmodule StarlightBotWeb.Live.GiftPlanEditorLive do
  use StarlightBotWeb, :live_view
  import StarlightBotWeb.Components.ConditionTree
  import StarlightBotWeb.Components.GiftPopup, only: [gift_popup: 1]
  import StarlightBotWeb.Components.PlanPicker
  import StarlightBotWeb.Components.PlanTemplates

  alias StarlightBot.{PlanClipboard, PlanCounts, PlanTemplates, Conditions, EgoGifts, GiftPlans, GiftStarterPacks, Plans, Teams, ThemePacks}
  alias StarlightBot.GiftPlans.{Routes, FusionRouteTemplates, Combos, RefreshCosts}
  alias StarlightBotWeb.Components.PlanHistory

    @gift_tiers 1..6
  @affinities ~w(bleed blunt burn charge pierce poise rupture sinking slash tremor)
  @affinity_order ~w(burn bleed tremor rupture sinking poise charge slash pierce blunt)
  @gift_sorts ~w(default name tier affinity)
  @gift_modes ~w(normal hard extreme)
  @uptie_views ~w(base uptie2 uptie3)
  @stat_codes %{"cp" => "Clash Power", "fc" => "Final Power", "bc" => "Base Power", "cg" => "Coin Count"}

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

  @read_only_events ~w(restore_view restore_browser set_tab toggle_help filter_gifts set_gift_tier_filter set_gift_affinity_filter set_gift_mode_filter toggle_gift_fixed_filter toggle_gift_no_pack_filter set_gift_pack_filter clear_gift_filters set_gift_sort show_gift_popup set_gift_popup_view hide_gift_popup set_route_shop open_case_condition close_case_condition list_select_branch list_copy_entries list_select_tab list_refresh_select_tab start_rename_stage cancel_rename_stage rf_pick rf_reset rf_cheapest list_open_fusion list_close_fusion rt_copy copy_plan clipboard_status plan_clipboard_failed pack_new pack_edit pack_close)

  def read_only_events, do: @read_only_events

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: PlanCounts.subscribe()

    gifts = EgoGifts.list_gifts()
    team = session["team_id"] && Teams.get_team(session["team_id"])

    socket =
      socket
      |> assign(:team_id, team && team.id)
      |> assign(:paste_status, :unknown)
      |> assign(:template_id, nil)
      |> assign(:team_locked, !!(team && Teams.locked?(team)))
      |> assign(:team_template, !!(team && team.template))
      |> read_only_guard(@read_only_events, &plan_locked?/1)
      |> pack_entry_guard()
      |> PlanHistory.attach(:plan_data, persist: &persist_plan/1, reconcile: &reconcile_selection/1)
      |> assign_templates(:gift_plans)
      |> assign(:tab_counts, PlanCounts.for_team(team && team.id))
      |> assign(:gifts, Enum.reject(gifts, &EgoGifts.unobtainable?/1))
      |> assign(:gifts_by_name, Map.new(gifts, &{&1.name, &1}))
      |> assign(:gifts_by_id, Map.new(gifts, &{&1.id, &1}))
      |> assign(:theme_packs_by_gift_id, ThemePacks.names_by_gift_id())
      |> assign(:theme_pack_images, Map.new(ThemePacks.list_theme_packs(), &{&1.name_en, &1.image_path}))
      |> assign(:sinners, Teams.all_sinners())
      |> assign(:route_clipboard, nil)
      |> assign(:route_shop, :normal)
      |> assign(:route_templates, FusionRouteTemplates.all())
      |> assign(:gift_popup, nil)
      |> assign(:show_help, false)
      |> assign(:view_from_url, false)
      |> assign(:starter_packs, GiftStarterPacks.list())
      |> reset_editor()

    socket = if team && team.gift_plan_id, do: socket |> load_plan(team.gift_plan_id, team.gift_template_id) |> apply_url_view(session), else: socket

    {:ok, if(connected?(socket), do: attach_hook(socket, :gift_view_url, :after_render, &publish_view/1), else: socket)}
  end

  defp apply_url_view(socket, session) do
    if session["tab"] == "loadout", do: socket |> assign(:active_tab, :loadout) |> assign(:view_from_url, true), else: socket
  end

  def plan_locked?(%{assigns: %{pack_edit: %{}}} = socket), do: socket.assigns.pack_locked
  def plan_locked?(socket), do: StarlightBotWeb.Components.PlanTemplates.template_locked?(socket)

  defp pack_entry_guard(socket) do
    if connected?(socket) do
      attach_hook(socket, :pack_entry_guard, :handle_event, fn
        _event, %{"entry" => id}, socket when is_binary(id) -> if String.contains?(id, "~"), do: {:halt, socket}, else: {:cont, socket}
        _event, _params, socket -> {:cont, socket}
      end)
    else
      socket
    end
  end

  defp publish_view(%{assigns: %{pack_edit: %{}}} = socket), do: socket

  defp publish_view(%{parent_pid: parent, assigns: %{editing_id: id, team_id: team_id}} = socket) when is_pid(parent) and id != nil do
    tab = socket.assigns.active_tab

    if Process.get(:gift_view_published) != tab do
      Process.put(:gift_view_published, tab)
      send(parent, {:gift_view, team_id, if(tab == :loadout, do: "loadout")})
    end

    socket
  end

  defp publish_view(socket), do: socket

  @impl true
  def handle_info({:plan_count, team_id, table, count}, %{assigns: %{team_id: team_id}} = socket), do: {:noreply, update(socket, :tab_counts, &Map.put(&1, table, count))}

  @impl true
  def handle_info({:plan_count, _team_id, _table, _count}, socket), do: {:noreply, socket}

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("new_plan", _, socket) do
    attrs = %{name: Plans.new_name(:gift_plans, socket.assigns.team_id), data: GiftPlans.blank(), team_id: socket.assigns.team_id}

    case Plans.save(:gift_plans, attrs) do
      {:ok, id} -> {:noreply, socket |> load_plan(id) |> link_team(:gift_plan_id)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("copy_plan", _, socket), do: {:noreply, copy_plan(socket, :gift_plans)}

  @impl true
  def handle_event("paste_plan", %{"text" => text}, socket), do: {:noreply, paste_plan(socket, :gift_plans, :gift_plan_id, text, &load_plan/3)}

  @impl true
  def handle_event("plan_clipboard_failed", %{"message" => message}, socket), do: {:noreply, put_flash(socket, :error, message)}

  @impl true
  def handle_event("template_" <> action, params, socket), do: {:noreply, template_event(socket, action, params, :gift_plans, :gift_plan_id, &load_plan/3)}

  @impl true
  def handle_event("clipboard_status", %{"text" => text}, socket), do: {:noreply, paste_status(socket, :gift_plans, text)}

  @impl true
  def handle_event("set_affinity", %{"affinity" => affinity}, socket) do
    affinity = blank_to_nil(affinity)

    {:noreply,
     update_plan(socket, fn data ->
       data
       |> Map.merge(%{"affinity" => affinity, "cabinet_gifts" => GiftPlans.starting_gifts(affinity)})
       |> GiftPlans.clear_perfected_priority()
     end)}
  end

  @impl true
  def handle_event("reorder_perfected_gifts", %{"scope" => "priority", "ids" => ids}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.set_perfected_priority(&1, ids, GiftPlans.perfected_unprioritized(&1, perfected_options(&1))))}
  end

  @impl true
  def handle_event("reorder_perfected_gifts", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("move_perfected_gift", %{"scope" => scope, "id" => id}, socket) do
    {:noreply,
     update_plan(socket, fn data ->
       options = perfected_options(data)
       priority = GiftPlans.perfected_priority(data, options)
       pool = GiftPlans.perfected_unprioritized(data, options)

       if scope == "priority",
         do: GiftPlans.set_perfected_priority(data, priority ++ [id], List.delete(pool, id)),
         else: GiftPlans.set_perfected_priority(data, List.delete(priority, id), pool ++ [id])
     end)}
  end

  @impl true
  def handle_event("toggle_perfected_gift", %{"gift" => name}, socket) do
    {:noreply,
     update_plan(socket, fn data ->
       options = perfected_options(data)
       priority = GiftPlans.perfected_priority(data, options)
       pool = GiftPlans.perfected_unprioritized(data, options)

       if name in priority,
         do: GiftPlans.set_perfected_priority(data, List.delete(priority, name), pool ++ [name]),
         else: GiftPlans.set_perfected_priority(data, priority ++ [name], List.delete(pool, name))
     end)}
  end

  @impl true
  def handle_event("set_perfected_restart", params, socket) do
    {:noreply, update_plan(socket, &GiftPlans.set_perfected_restart(&1, params["restart"] == "true"))}
  end

  @impl true
  def handle_event("reorder_cabinet_gifts", %{"ids" => ids}, socket) do
    {:noreply, update_plan(socket, &Map.put(&1, "cabinet_gifts", ids))}
  end

  @impl true
  def handle_event("restore_view", _params, %{assigns: %{pack_edit: %{}}} = socket), do: {:noreply, socket}

  @impl true
  def handle_event("restore_view", params, %{assigns: %{editing_id: id}} = socket) when id != nil do
    tab = if params["tab"] == "loadout", do: :loadout, else: :shop
    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_event("restore_view", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_help", _, socket), do: {:noreply, update(socket, :show_help, &(!&1))}

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    {:noreply, socket |> assign(:active_tab, String.to_existing_atom(tab)) |> assign(:gift_popup, nil)}
  end

  @impl true
  def handle_event("filter_gifts", %{"value" => value}, socket) do
    {:noreply, assign(socket, :gift_filter, value)}
  end

  @impl true
  def handle_event("set_gift_tier_filter", %{"value" => tier}, socket) do
    {:noreply, assign(socket, :gift_tier_filter, toggle(socket.assigns.gift_tier_filter, String.to_integer(tier)))}
  end

  @impl true
  def handle_event("set_gift_affinity_filter", %{"value" => affinity}, socket) do
    {:noreply, assign(socket, :gift_affinity_filter, toggle(socket.assigns.gift_affinity_filter, affinity))}
  end

  @impl true
  def handle_event("set_gift_mode_filter", %{"value" => mode}, socket) when mode in @gift_modes do
    {:noreply, assign(socket, :gift_mode_filter, toggle(socket.assigns.gift_mode_filter, mode))}
  end

  @impl true
  def handle_event("toggle_gift_fixed_filter", _params, socket) do
    {:noreply, assign(socket, :gift_fixed_filter, not socket.assigns.gift_fixed_filter)}
  end

  @impl true
  def handle_event("toggle_gift_no_pack_filter", _params, socket) do
    {:noreply, assign(socket, :gift_no_pack_filter, not socket.assigns.gift_no_pack_filter)}
  end

  def handle_event("set_gift_pack_filter", %{"value" => pack}, socket) do
    {:noreply, assign(socket, :gift_pack_filter, pack)}
  end

  @impl true
  def handle_event("clear_gift_filters", _params, socket) do
    {:noreply, socket |> assign(:gift_pack_filter, "") |> assign(:gift_tier_filter, []) |> assign(:gift_affinity_filter, []) |> assign(:gift_mode_filter, []) |> assign(:gift_fixed_filter, false) |> assign(:gift_no_pack_filter, false)}
  end

  @impl true
  def handle_event("set_gift_sort", %{"value" => sort_by}, socket) when sort_by in @gift_sorts do
    {:noreply, assign(socket, :gift_sort, sort_by)}
  end

  @impl true
  def handle_event("restore_browser", params, socket) do
    sort_by = if params["sort"] in @gift_sorts, do: params["sort"], else: "default"
    tiers = for tier <- List.wrap(params["tiers"]), tier in @gift_tiers, do: tier
    affinities = for affinity <- List.wrap(params["affinities"]), affinity in ["none" | @affinities], do: affinity
    modes = for mode <- List.wrap(params["modes"]), mode in @gift_modes, do: mode
    pack = if is_binary(params["pack"]), do: params["pack"], else: ""

    {:noreply,
     socket
     |> assign(:gift_sort, sort_by)
     |> assign(:gift_tier_filter, tiers)
     |> assign(:gift_affinity_filter, affinities)
     |> assign(:gift_mode_filter, modes)
     |> assign(:gift_fixed_filter, params["fixed"] == true)
     |> assign(:gift_no_pack_filter, params["no_pack"] == true)
     |> assign(:gift_pack_filter, pack)}
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
  def handle_event("add_encounter_row", _, socket) do
    rows = socket.assigns.plan_data["encounter_rewards"]
    next_floor = (rows |> Enum.map(& &1["from_floor"]) |> Enum.max(fn -> 0 end)) |> Kernel.+(1) |> min(15)
    order = if rows == [], do: GiftPlans.encounter_reward_default_order(), else: List.last(rows)["order"]

    {:noreply, update_plan(socket, &Map.put(&1, "encounter_rewards", sort_schedule(rows ++ [%{"from_floor" => next_floor, "order" => order}])))}
  end

  @impl true
  def handle_event("set_encounter_floor", %{"index" => index, "from_floor" => floor}, socket) do
    floor = parse_int(floor, 1) |> max(1) |> min(15)

    {:noreply, update_plan(socket, &update_encounter_rows(&1, fn rows -> rows |> List.update_at(String.to_integer(index), fn row -> %{row | "from_floor" => floor} end) |> sort_schedule() end))}
  end

  @impl true
  def handle_event("remove_encounter_row", %{"index" => index}, socket) do
    {:noreply, update_plan(socket, &update_encounter_rows(&1, fn rows -> rows |> List.delete_at(String.to_integer(index)) |> sort_schedule() end))}
  end

  @impl true
  def handle_event("encounter_add", %{"index" => index, "key" => key}, socket) do
    if key in GiftPlans.encounter_reward_options() do
      {:noreply, update_plan(socket, &update_encounter_order(&1, index, fn order -> if key in order, do: order, else: order ++ [key] end))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("encounter_remove", %{"index" => index, "key" => key}, socket) do
    {:noreply, update_plan(socket, &update_encounter_order(&1, index, fn order -> List.delete(order, key) end))}
  end

  @impl true
  def handle_event("reorder_encounter", %{"scope" => index, "ids" => ids}, socket) do
    {:noreply, update_plan(socket, &update_encounter_order(&1, index, fn order -> if Enum.sort(ids) == Enum.sort(order), do: ids, else: order end))}
  end

  @impl true
  def handle_event("open_case_condition", %{"case_id" => id}, socket) do
    {:noreply, assign(socket, :editing_condition_case_id, id)}
  end

  @impl true
  def handle_event("close_case_condition", _params, socket) do
    {:noreply, assign(socket, :editing_condition_case_id, nil)}
  end

  @impl true
  def handle_event("cond_add", %{"path" => path, "node" => node} = params, socket) do
    child = if node == "group", do: Conditions.group(GiftPlans.default_leaf()), else: GiftPlans.default_leaf()
    socket = update_condition(socket, params, &Conditions.add(&1, path, child))
    {:noreply, assign(socket, :editing_condition_case_id, params["case_id"] || params["branch"])}
  end

  @impl true
  def handle_event("list_add_branch", %{"entry" => entry_id, "from" => from} = params, socket) do
    timeline = timeline_param(socket, entry_id, params)
    from = String.to_integer(from)
    branch_id = GiftPlans.new_id("br")
    condition = Conditions.add(nil, "", %{"op" => "refreshes", "cmp" => "gte", "value" => 3})

    socket =
      for_group(socket, entry_id, fn socket, id ->
        update_plan(socket, &GiftPlans.add_branch(&1, entry_section_id(socket, id), id, from, timeline, branch_id, condition))
      end)

    {:noreply, socket |> put_tab(entry_id, timeline, from, branch_id) |> assign(:editing_condition_case_id, branch_id)}
  end

  @impl true
  def handle_event("list_select_branch", %{"entry" => entry_id, "from" => from, "branch" => branch} = params, socket) do
    {:noreply, put_tab(socket, entry_id, timeline_param(socket, entry_id, params), String.to_integer(from), blank_to_nil(branch))}
  end

  @impl true
  def handle_event("list_remove_branch", %{"entry" => entry_id, "from" => from, "branch" => branch} = params, socket) do
    timeline = timeline_param(socket, entry_id, params)
    from = String.to_integer(from)

    socket =
      for_group(socket, entry_id, fn socket, id ->
        update_plan(socket, &GiftPlans.remove_branch(&1, entry_section_id(socket, id), id, from, timeline, branch))
      end)

    {:noreply, socket |> put_tab(entry_id, timeline, from) |> assign(:editing_condition_case_id, nil)}
  end

  @impl true
  def handle_event("list_move_branch", %{"entry" => entry_id, "from" => from, "branch" => branch, "delta" => delta} = params, socket) do
    timeline = timeline_param(socket, entry_id, params)
    from = String.to_integer(from)

    {:noreply,
     for_group(socket, entry_id, fn socket, id ->
       update_plan(socket, &GiftPlans.move_branch(&1, entry_section_id(socket, id), id, from, timeline, branch, parse_int(delta, 0)))
     end)}
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
    {:noreply, update_condition(socket, params, &Conditions.put_leaf(&1, path, GiftPlans.condition_leaf(params)))}
  end

  @impl true
  def handle_event("pack_new", _params, socket) do
    case GiftStarterPacks.create(GiftStarterPacks.default_name(), "any") do
      {:ok, ref} -> {:noreply, socket |> refresh_packs() |> open_pack(ref)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Couldn't create the starter pack: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("pack_edit", %{"ref" => ref}, socket), do: {:noreply, open_pack(socket, ref)}

  @impl true
  def handle_event("pack_close", _params, socket), do: {:noreply, close_pack(socket)}

  @impl true
  def handle_event("pack_add", %{"ref" => ref}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.add_pack(&1, target_section_id(socket), ref))}
  end

  @impl true
  def handle_event("pack_unpack", %{"pack" => pack_id, "section" => section_id}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.unpack(&1, section_id, pack_id))}
  end

  @impl true
  def handle_event("pack_remove", %{"pack" => pack_id, "section" => section_id}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.remove_pack(&1, section_id, pack_id))}
  end

  @impl true
  def handle_event("pack_reorder", %{"scope" => section_id, "ids" => ids}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.reorder_packs(&1, section_id, ids))}
  end

  @impl true
  def handle_event("pack_move", %{"scope" => to, "from" => from, "id" => pack_id, "ids" => ids}, socket) do
    root_sections = socket.assigns.plan_data |> GiftPlans.sections(socket.assigns.root_section_id) |> Enum.map(& &1["id"])

    if from in root_sections and to in root_sections,
      do: {:noreply, update_plan(socket, &GiftPlans.move_pack(&1, from, to, pack_id, ids))},
      else: {:noreply, socket}
  end

  @impl true
  def handle_event("pack_rename", %{"value" => name}, %{assigns: %{pack_edit: %{ref: ref}}} = socket) do
    {:noreply, save_pack_fields(socket, ref, %{name: name}, :name, String.trim(name))}
  end

  @impl true
  def handle_event("pack_set_notes", %{"value" => notes}, %{assigns: %{pack_edit: %{ref: ref}}} = socket) do
    {:noreply, save_pack_fields(socket, ref, %{notes: notes}, :notes, notes)}
  end

  @impl true
  def handle_event("pack_set_affinity", %{"affinity" => affinity}, %{assigns: %{pack_edit: %{ref: ref}}} = socket) do
    {:noreply, save_pack_fields(socket, ref, %{affinity: affinity}, :affinity, affinity)}
  end

  @impl true
  def handle_event("pack_delete", _params, %{assigns: %{pack_edit: %{ref: ref}}} = socket) do
    case GiftStarterPacks.delete(ref) do
      :ok -> {:noreply, socket |> close_pack() |> refresh_packs()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "This starter pack can't be deleted.")}
    end
  end

  @impl true
  def handle_event("list_add_loadout_gift", %{"gift" => name}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.add_loadout_keep(&1, socket.assigns.root_section_id, name, socket.assigns.gifts_by_name))}
  end

  @impl true
  def handle_event("list_add_gift", %{"gift" => name} = params, socket) do
    routes = fn tier -> FusionRouteTemplates.initial(tier) end
    root = socket.assigns.root_section_id

    case params["group"] && GiftPlans.group_section_id(socket.assigns.plan_data, root, params["group"]) do
      section_id when is_binary(section_id) ->
        {:noreply, update_plan(socket, &GiftPlans.add_gift_to_group(&1, section_id, params["group"], name, socket.assigns.gifts_by_name, routes))}

      _ ->
        {:noreply, update_plan(socket, &GiftPlans.add_gift(&1, add_section_id(socket, params), name, socket.assigns.gifts_by_name, routes))}
    end
  end

  @impl true
  def handle_event("list_add_tier", %{"tier" => tier}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.add_pattern(&1, target_section_id(socket), GiftPlans.tier_subject([String.to_integer(tier)])))}
  end

  @impl true
  def handle_event("list_add_affinity_any", %{"affinity" => affinity}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.add_pattern(&1, target_section_id(socket), GiftPlans.affinity_subject(affinity, [])))}
  end

  def handle_event("list_add_affinity", %{"affinity" => affinity, "tier" => tier}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.add_pattern(&1, target_section_id(socket), GiftPlans.affinity_subject(affinity, [String.to_integer(tier)])))}
  end

  @impl true
  def handle_event("list_add_action", %{"action" => action} = params, socket) do
    sinner = if params["sinner"] == "everyone", do: Teams.all_sinners(), else: params["sinner"]
    section = if action == "skill_replace", do: target_section_id(socket), else: socket.assigns.root_section_id
    {:noreply, update_plan(socket, &GiftPlans.add_action(&1, section, action, sinner))}
  end

  @impl true
  def handle_event("list_toggle_heal_sinner", %{"entry" => entry_id, "from" => from, "sinner" => sinner}, socket) do
    {:noreply,
     update_segment(socket, entry_id, from, fn segment ->
       picked = segment["sinners"] || []
       picked = if sinner in picked, do: List.delete(picked, sinner), else: picked ++ [sinner]
       Map.put(segment, "sinners", Enum.filter(Teams.all_sinners(), &(&1 in picked)))
     end)}
  end

  @impl true
  def handle_event("list_step_skill_target", %{"entry" => entry_id, "from" => from, "key" => key, "delta" => delta}, socket) when key in ~w(s1 s2) do
    delta = parse_int(delta, 0)
    {:noreply, update_segment(socket, entry_id, from, &Map.put(&1, "target", GiftPlans.step_skill_target(&1["target"], key, delta, &1["lock_s2"] != false)))}
  end

  @impl true
  def handle_event("list_toggle_skill_lock", %{"entry" => entry_id, "from" => from}, socket) do
    {:noreply, update_segment(socket, entry_id, from, &Map.merge(&1, %{"lock_s2" => &1["lock_s2"] == false, "target" => GiftPlans.skill_target(&1["target"], &1["lock_s2"] == false)}))}
  end

  @impl true
  def handle_event("list_toggle_heal_after", %{"entry" => entry_id, "from" => from}, socket) do
    {:noreply, update_segment(socket, entry_id, from, &Map.put(&1, "heal_after", &1["heal_after"] == false))}
  end

  @impl true
  def handle_event("list_set_heal_repeat", %{"entry" => entry_id, "from" => from, "repeat" => repeat}, socket) when repeat in ~w(once 2 3 until_full) do
    {:noreply, update_segment(socket, entry_id, from, &Map.put(&1, "repeat", repeat))}
  end

  @impl true
  def handle_event("list_add_refresh_case", _params, socket) do
    {:noreply, update_plan(socket, &GiftPlans.add_refresh_case(&1, socket.assigns.root_section_id, refresh_from(socket)))}
  end

  @impl true
  def handle_event("list_update_refresh_case", %{"case_id" => id, "action" => action} = params, socket) do
    {:noreply,
     update_plan(socket, &GiftPlans.update_refresh_case(&1, socket.assigns.root_section_id, id, fn refresh_case ->
       Map.merge(refresh_case, %{
         "action" => if(action in GiftPlans.refresh_actions(), do: action, else: refresh_case["action"]),
         "affinity" => blank_to_nil(params["affinity"]),
         "max" => case Integer.parse(params["max"] || "") do
           {int, _} -> max(int, 0)
           :error -> nil
         end
       })
       |> put_min_cost(params["min_cost"])
     end))}
  end

  @impl true
  def handle_event("list_remove_refresh_case", %{"case_id" => id}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.remove_refresh_case(&1, socket.assigns.root_section_id, id))}
  end

  @impl true
  def handle_event("list_reorder_refresh", %{"ids" => ids}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.reorder_refresh_cases(&1, socket.assigns.root_section_id, ids, refresh_from(socket)))}
  end

  @impl true
  def handle_event("list_refresh_add_schedule", _params, socket) do
    {:noreply, update_plan(socket, &GiftPlans.add_refresh_schedule(&1, socket.assigns.root_section_id))}
  end

  @impl true
  def handle_event("list_refresh_remove_schedule", _params, socket) do
    {:noreply, socket |> update_plan(&GiftPlans.remove_refresh_schedule(&1, socket.assigns.root_section_id)) |> put_refresh_tab(1)}
  end

  @impl true
  def handle_event("list_refresh_split", %{"floor" => floor}, socket) when floor != "" do
    floor = String.to_integer(floor)
    {:noreply, socket |> update_plan(&GiftPlans.split_refresh(&1, socket.assigns.root_section_id, floor)) |> put_refresh_tab(floor)}
  end

  @impl true
  def handle_event("list_refresh_split", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("rf_pick", %{"step" => step, "kind" => kind}, socket) do
    path = refresh_path(socket.assigns, selected_section(socket.assigns), refresh_from(socket))
    step = String.to_integer(step)
    {:noreply, put_refresh_path(socket, Enum.take(path, step) ++ [RefreshCosts.kind(kind)])}
  end

  @impl true
  def handle_event("rf_reset", _params, socket) do
    {:noreply, assign(socket, :refresh_paths, Map.delete(socket.assigns.refresh_paths, refresh_path_key(socket)))}
  end

  @impl true
  def handle_event("rf_cheapest", _params, socket) do
    assigns = socket.assigns
    path = refresh_path(assigns, selected_section(assigns), refresh_from(socket))
    {_cost, cheapest} = RefreshCosts.cheapest(path, RefreshCosts.free(assigns.plan_data["grace_picks"]))
    {:noreply, put_refresh_path(socket, cheapest)}
  end

  @impl true
  def handle_event("list_refresh_select_tab", %{"from" => from}, socket) do
    {:noreply, put_refresh_tab(socket, String.to_integer(from))}
  end

  @impl true
  def handle_event("list_refresh_move_segment", %{"from" => from, "to" => to}, socket) do
    to = String.to_integer(to)
    {:noreply, socket |> update_plan(&GiftPlans.move_refresh_segment(&1, socket.assigns.root_section_id, String.to_integer(from), to)) |> put_refresh_tab(to)}
  end

  @impl true
  def handle_event("list_refresh_remove_segment", %{"from" => from}, socket) do
    {:noreply, socket |> update_plan(&GiftPlans.remove_refresh_segment(&1, socket.assigns.root_section_id, String.to_integer(from))) |> put_refresh_tab(1)}
  end

  @impl true
  def handle_event("list_remove_entry", %{"entry" => entry_id}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.remove_entry(&1, entry_section_id(socket, entry_id), entry_id))}
  end

  @impl true
  def handle_event("list_remove_entries", %{"ids" => ids}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.remove_entries(&1, entry_section_id(socket, List.first(ids)), ids))}
  end

  @impl true
  def handle_event("list_reorder_entries", %{"scope" => "group:" <> key, "ids" => ids}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.reorder_group(&1, entry_section_id(socket, List.first(ids)), key, ids))}
  end

  def handle_event("list_reorder_entries", %{"scope" => id, "ids" => ids}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.reorder_entries(&1, id, ids))}
  end

  @impl true
  def handle_event("list_move_entry", %{"scope" => scope, "id" => entry_id, "ids" => ids} = params, socket) do
    moved = Map.get(params, "moved", [entry_id])
    root = socket.assigns.root_section_id

    {key, target} =
      case scope do
        "group:" <> key -> {key, GiftPlans.group_section_id(socket.assigns.plan_data, root, key) || target_section_id(socket)}
        id -> {nil, id}
      end

    source = entry_section_id(socket, entry_id)

    {:noreply,
     socket
     |> update_plan(&GiftPlans.transfer_entries(&1, source, target, moved))
     |> update_plan(&GiftPlans.move_entries(&1, target, moved, key, ids))}
  end

  @impl true
  def handle_event("list_copy_entries", %{"ids" => ids}, socket) do
    section = entry_section(socket, List.first(ids))

    case Enum.filter(section["entries"], &(&1["id"] in ids)) do
      [] ->
        {:noreply, socket}

      entries ->
        label = if length(entries) == 1, do: "1 entry", else: "#{length(entries)} entries"
        {:noreply, socket |> push_event("copy_json", %{text: PlanClipboard.encode_entries(entries), toast: "Copied #{label} to the clipboard."})}
    end
  end

  @impl true
  def handle_event("list_paste_entries", %{"text" => text, "after" => after_id}, socket) do
    case PlanClipboard.decode_entries(text) do
      {:ok, entries} ->
        socket = update_plan(socket, &GiftPlans.paste_entries(&1, entry_section_id(socket, after_id), entries, after_id))
        {:noreply, put_flash(socket, :info, "Pasted #{length(entries)} #{if length(entries) == 1, do: "entry", else: "entries"}.")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_event("list_update_segment", %{"entry" => entry_id, "from" => from, "segment" => params}, socket) do
    entry = socket.assigns.plan_data |> GiftPlans.find_section(entry_section_id(socket, entry_id)) |> GiftPlans.find_entry(entry_id)
    pattern? = entry != nil and GiftPlans.pattern_entry?(entry)

    {:noreply,
     update_segment(socket, entry_id, from, fn segment ->
       segment
       |> Map.put("disposition", if(params["disposition"] in GiftPlans.dispositions(), do: params["disposition"], else: segment["disposition"]))
       |> apply_goal(params["goal"], pattern?)
       |> Map.put("max", if(Map.has_key?(params, "max"), do: parse_optional_int(params["max"]), else: segment["max"]))
       |> apply_team_profiles(params["team_profile"])
     end)}
  end

  @impl true
  def handle_event("list_toggle_team_replace", %{"entry" => entry_id, "from" => from, "sinner" => sinner}, socket) do
    {:noreply, update_segment(socket, entry_id, from, &Map.update(&1, "replacements", [], fn replacements -> GiftPlans.toggle_team_replacement(replacements, sinner) end))}
  end

  @impl true
  def handle_event("list_toggle", %{"entry" => entry_id, "from" => from, "field" => "fuse"}, socket) do
    {:noreply, socket |> ensure_fusion(entry_id) |> update_segment(entry_id, from, &Map.put(&1, "fuse", &1["fuse"] != true))}
  end

  def handle_event("list_toggle", %{"entry" => entry_id, "from" => from, "field" => "buy"}, socket) do
    {:noreply,
     update_segment(socket, entry_id, from, fn segment ->
       if segment["buy"] == true and segment["disposition"] != "sell",
         do: Map.put(segment, "buy", false),
         else: Map.merge(segment, %{"buy" => true, "disposition" => if(segment["disposition"] == "sell", do: "keep", else: segment["disposition"])})
     end)}
  end

  def handle_event("list_toggle", %{"entry" => entry_id, "from" => from, "field" => "sell"}, socket) do
    {:noreply,
     update_segment(socket, entry_id, from, fn segment ->
       if segment["disposition"] == "sell",
         do: Map.put(segment, "disposition", "keep"),
         else: Map.merge(segment, %{"disposition" => "sell", "buy" => false})
     end)}
  end

  @impl true
  def handle_event("list_set_segment_mode", %{"entry" => entry_id, "from" => from, "mode" => mode} = params, socket) when mode in ~w(abandon change) do
    timeline = timeline_param(socket, entry_id, params)

    {:noreply,
     socket
     |> for_group(entry_id, fn socket, id ->
       update_segment(socket, id, from, fn segment ->
         segment = Map.put(segment, "abandoned", mode == "abandon")
         if mode == "change" and segment["disposition"] == "ignore", do: Map.put(segment, "disposition", "keep"), else: segment
       end, params)
     end)
     |> put_tab(entry_id, timeline, String.to_integer(from))}
  end

  @impl true
  def handle_event("list_set_uptie", %{"entry" => entry_id, "from" => from, "level" => level}, socket) do
    level = level |> parse_int(0) |> max(0) |> min(GiftPlans.max_uptie())
    {:noreply, update_segment(socket, entry_id, from, &Map.put(&1, "uptie", level))}
  end

  @impl true
  def handle_event("list_split", %{"entry" => entry_id, "floor" => floor} = params, socket) when floor != "" do
    floor = String.to_integer(floor)
    timeline = timeline_param(socket, entry_id, params)

    {:noreply,
     socket
     |> for_group(entry_id, fn socket, id ->
       socket
       |> update_plan(&GiftPlans.split_entry(&1, entry_section_id(socket, id), id, floor, timeline))
       |> set_scheduled(id)
     end)
     |> put_tab(entry_id, timeline, floor)}
  end

  @impl true
  def handle_event("list_split", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("list_add_schedule", %{"entry" => entry_id}, socket) do
    {:noreply, set_scheduled(socket, entry_id)}
  end

  @impl true
  def handle_event("list_remove_schedule", %{"entry" => entry_id}, socket) do
    {:noreply,
     for_group(socket, entry_id, fn socket, id ->
       socket
       |> update_segment(id, "1", fn segment ->
         segment = Map.put(segment, "abandoned", false)
         if segment["disposition"] == "ignore", do: Map.put(segment, "disposition", "keep"), else: segment
       end)
       |> update_plan(&GiftPlans.update_entry(&1, entry_section_id(socket, id), id, fn entry -> entry |> Map.put("scheduled", false) |> Map.delete("group") |> Map.delete("timelines") end))
     end)}
  end

  @impl true
  def handle_event("list_move_segment", %{"entry" => entry_id, "from" => from, "to" => to} = params, socket) do
    to = String.to_integer(to)
    timeline = timeline_param(socket, entry_id, params)

    {:noreply,
     socket
     |> for_group(entry_id, fn socket, id -> update_plan(socket, &GiftPlans.move_segment(&1, entry_section_id(socket, id), id, String.to_integer(from), to, timeline)) end)
     |> put_tab(entry_id, timeline, to)}
  end

  @impl true
  def handle_event("list_remove_segment", %{"entry" => entry_id, "from" => from} = params, socket) do
    timeline = timeline_param(socket, entry_id, params)

    {:noreply,
     socket
     |> for_group(entry_id, fn socket, id -> update_plan(socket, &GiftPlans.remove_segment(&1, entry_section_id(socket, id), id, String.to_integer(from), timeline)) end)
     |> put_tab(entry_id, timeline, 1)}
  end

  @impl true
  def handle_event("list_select_tab", %{"entry" => entry_id, "from" => from} = params, socket) do
    {:noreply, put_tab(socket, entry_id, timeline_param(socket, entry_id, params), String.to_integer(from))}
  end

  @impl true
  def handle_event("list_add_timeline", %{"entry" => entry_id, "kinds" => kinds}, socket) when is_list(kinds) do
    timeline_id = GiftPlans.new_id("tl")

    {:noreply,
     socket
     |> for_group(entry_id, fn socket, id ->
       socket
       |> update_plan(&GiftPlans.add_timeline(&1, entry_section_id(socket, id), id, timeline_id, kinds))
       |> set_scheduled(id)
     end)
     |> put_tab(entry_id, timeline_id, 1)}
  end

  @impl true
  def handle_event("list_add_timeline", %{"entry" => entry_id, "kind" => kind}, socket), do: handle_event("list_add_timeline", %{"entry" => entry_id, "kinds" => [kind]}, socket)

  @impl true
  def handle_event("list_add_timeline", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("list_toggle_timeline_kind", %{"entry" => entry_id, "timeline" => timeline_id, "kind" => kind}, socket) do
    socket = for_group(socket, entry_id, fn socket, id -> update_plan(socket, &GiftPlans.toggle_timeline_kind(&1, entry_section_id(socket, id), id, timeline_id, kind)) end)

    removed? =
      socket.assigns.plan_data
      |> GiftPlans.find_section(entry_section_id(socket, entry_id))
      |> GiftPlans.find_entry(entry_id)
      |> GiftPlans.find_timeline(timeline_id)
      |> is_nil()

    {:noreply, if(removed?, do: put_tab(socket, entry_id, nil, 1), else: socket)}
  end

  @impl true
  def handle_event("list_remove_timeline", %{"entry" => entry_id, "timeline" => timeline_id}, socket) do
    {:noreply,
     socket
     |> for_group(entry_id, fn socket, id -> update_plan(socket, &GiftPlans.remove_timeline(&1, entry_section_id(socket, id), id, timeline_id)) end)
     |> put_tab(entry_id, nil, 1)}
  end

  @impl true
  def handle_event("list_set_pursue_optional", %{"value" => value}, socket) do
    {:noreply, update_section(socket, socket.assigns.root_section_id, &Map.put(&1, "pursue_optional", value == "true"))}
  end

  @impl true
  def handle_event("list_add_goal", params, socket) do
    {:noreply, update_plan(socket, &GiftPlans.add_goal(&1, section_param(socket, params)))}
  end

  @impl true
  def handle_event("list_set_goal_min", %{"letter" => letter, "min" => min} = params, socket) do
    {:noreply, update_plan(socket, &GiftPlans.set_goal_min(&1, section_param(socket, params), letter, parse_int(min, 1)))}
  end

  @impl true
  def handle_event("list_remove_goal", %{"letter" => letter} = params, socket) do
    {:noreply, update_plan(socket, &GiftPlans.remove_goal(&1, section_param(socket, params), letter))}
  end

  @impl true
  def handle_event("list_add_stage", _params, socket) do
    {data, _stage} = GiftPlans.add_stage(socket.assigns.plan_data, socket.assigns.root_section_id)

    {:noreply,
     socket
     |> assign(:plan_data, data)
     |> persist_plan()}
  end

  @impl true
  def handle_event("list_move_stage", %{"id" => id, "dir" => dir}, socket) do
    offset = if dir == "up", do: -1, else: 1
    {:noreply, update_plan(socket, &GiftPlans.move_stage(&1, id, offset))}
  end

  @impl true
  def handle_event("start_rename_stage", %{"id" => id}, socket) do
    {:noreply, assign(socket, :renaming_stage_id, id)}
  end

  @impl true
  def handle_event("cancel_rename_stage", _params, socket) do
    {:noreply, assign(socket, :renaming_stage_id, nil)}
  end

  @impl true
  def handle_event("rename_stage", %{"id" => id, "value" => name}, socket) do
    name = String.trim(name)
    socket = assign(socket, :renaming_stage_id, nil)
    {:noreply, if(name == "", do: socket, else: update_plan(socket, &GiftPlans.rename_stage(&1, id, name)))}
  end

  @impl true
  def handle_event("list_remove_stage", %{"id" => id}, socket) do
    {:noreply, update_plan(socket, &GiftPlans.remove_stage(&1, id))}
  end

  @impl true
  def handle_event("list_open_fusion", %{"entry" => entry_id}, socket) do
    {:noreply, assign(socket, :fusion_entry_id, entry_id)}
  end

  @impl true
  def handle_event("list_close_fusion", _params, socket) do
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
  def handle_event("rt_save_template", %{"def_id" => id, "name" => name}, socket) do
    {entry, %{tier: tier}} = fusion_entry(socket, id)

    case FusionRouteTemplates.create(tier, name, entry["fusion"]["routes"] || []) do
      {:ok, _ref} ->
        {:noreply,
         socket
         |> assign(:route_templates, FusionRouteTemplates.all())
         |> put_flash(:info, "Saved \"#{String.trim(name)}\" as a tier #{tier} template.")}

      {:error, :blank_name} ->
        {:noreply, put_flash(socket, :error, "Give the template a name.")}

      {:error, :name_taken} ->
        {:noreply, put_flash(socket, :error, "A tier #{tier} template named \"#{String.trim(name)}\" already exists.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Couldn't save the tier #{tier} template.")}
    end
  end

  @impl true
  def handle_event("rt_apply_template", %{"def_id" => id, "ref" => ref}, socket) do
    case FusionRouteTemplates.get(ref) do
      %{routes: routes} -> {:noreply, update_routes(socket, id, fn _routes -> Routes.copy(routes) end)}
      nil -> {:noreply, put_flash(socket, :error, "That template no longer exists.")}
    end
  end

  @impl true
  def handle_event("rt_delete_template", %{"ref" => ref}, socket) do
    case FusionRouteTemplates.delete(ref) do
      :ok -> {:noreply, assign(socket, :route_templates, FusionRouteTemplates.all())}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Couldn't delete that template.")}
    end
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

  def graces, do: @graces
  def gift_tiers, do: @gift_tiers
  def affinities, do: @affinities
  def affinity_order, do: @affinity_order

  def searchable_gifts(gifts), do: Enum.filter(gifts, &GiftPlans.gift_searchable?/1)

  def perfected_options(plan_data), do: GiftPlans.perfected_options(plan_data["affinity"])

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
  def team_replace_profiles do
    StarlightBot.SinnerProfiles.list()
    |> Enum.filter(&(&1.hd_locator_hook not in [nil, ""] or &1.hd_base_locator_hook not in [nil, ""]))
    |> Enum.group_by(& &1.sinner)
  end

  def sinner_label(nil), do: "(none)"
  def sinner_label(sinner), do: sinner |> String.split("_") |> Enum.map_join(" ", &String.capitalize/1)

  def loadout_offers(plan_data, section) do
    if section["id"] == hd(plan_data["sections"])["id"] do
      starting = plan_data |> GiftPlans.cabinet_order() |> Enum.take(GiftPlans.cabinet_pick_count(plan_data)) |> Enum.map(&{&1, "Starting gift"})
      searched = Enum.map(plan_data["gift_search"] || [], &{&1, "Gift search"})

      (starting ++ searched)
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.reject(fn {name, _source} -> GiftPlans.has_gift?(section, name) end)
    else
      []
    end
  end

  def selected_section(assigns), do: GiftPlans.find_section(assigns.plan_data, assigns.root_section_id)

  def active_timeline(entry_tabs, entry) do
    case entry_tabs[GiftPlans.group_key(entry)] do
      tab when is_tuple(tab) and is_binary(elem(tab, 0)) -> if GiftPlans.find_timeline(entry, elem(tab, 0)), do: elem(tab, 0)
      _ -> nil
    end
  end

  def active_segment(entry_tabs, entry) do
    from = active_from(entry_tabs, entry)
    Enum.find(GiftPlans.timeline_view(entry, active_timeline(entry_tabs, entry))["floors"], &(&1["from"] == from))
  end

  def active_branch(entry_tabs, entry) do
    with {_timeline, _from, branch} when is_binary(branch) <- entry_tabs[GiftPlans.group_key(entry)],
         %{} <- GiftPlans.find_branch(active_segment(entry_tabs, entry), branch) do
      branch
    else
      _ -> nil
    end
  end

  def active_from(entry_tabs, entry) do
    froms = entry |> GiftPlans.timeline_view(active_timeline(entry_tabs, entry)) |> Map.fetch!("floors") |> Enum.map(& &1["from"])

    case entry_tabs[GiftPlans.group_key(entry)] do
      tab when is_tuple(tab) and is_integer(elem(tab, 1)) -> if elem(tab, 1) in froms, do: elem(tab, 1), else: hd(froms)
      _ -> hd(froms)
    end
  end

  def active_refresh_from(refresh_tabs, section) do
    from = refresh_tabs[section["id"]]
    if from in GiftPlans.refresh_froms(section), do: from, else: 1
  end

  def refresh_tab_label(section, from) do
    froms = GiftPlans.refresh_froms(section)

    case Enum.find(froms, &(&1 > from)) do
      nil -> "F#{from}+"
      next when next == from + 1 -> "F#{from}"
      next -> "F#{from}-#{next - 1}"
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

  def applies_label("always"), do: "Every run"
  def applies_label("all_normal"), do: "Normal F1-F5"
  def applies_label("becomes_hard"), do: "Hard starts F2-F5"
  def applies_label("all_hard"), do: "Hard from F1"
  def applies_label("extreme"), do: "Extreme planned"

  attr :entry_id, :string, required: true
  attr :strip, :any, required: true
  attr :used_kinds, :list, required: true

  def timeline_kinds(assigns) do
    assigns = assign(assigns, kinds: (assigns.strip && assigns.strip.kinds) || [])

    ~H"""
    <div popover="manual" class="dropdown-content z-30 w-max rounded-lg border border-base-300 bg-base-100 p-1.5 shadow-lg space-y-1">
      <button :for={kind <- GiftPlans.condition_run_kinds()} type="button"
              phx-click={if @strip, do: "list_toggle_timeline_kind", else: "list_add_timeline"} phx-value-entry={@entry_id}
              phx-value-timeline={@strip && @strip.id} phx-value-kind={kind}
              disabled={kind in @used_kinds and kind not in @kinds}
              title={applies_hint(kind)} class={"btn btn-xs w-full justify-start " <> if(kind in @kinds, do: "btn-primary", else: "btn-ghost")}>
        <.icon name={if kind in @kinds, do: "lucide-check", else: "lucide-minus"} class="size-3" /><%= applies_label(kind) %>
      </button>
    </div>
    """
  end

  def applies_hint("always"), do: "Will work on this stage in every run"
  def applies_hint("all_normal"), do: "Will work on this stage if F1-F5 are all normal, with no planned hard switch"
  def applies_hint("becomes_hard"), do: "Will work on this stage when the run expects a hard switch in F2-F5"
  def applies_hint("all_hard"), do: "Will work on this stage if the run starts F1 hard"
  def applies_hint("extreme"), do: "Will work on this stage if the run expects F6+"

  def applies_badge_color("all_normal"), do: "bg-sky-600 border-sky-700 text-white"
  def applies_badge_color("becomes_hard"), do: "bg-amber-600 border-amber-700 text-white"
  def applies_badge_color("all_hard"), do: "bg-orange-600 border-orange-700 text-white"
  def applies_badge_color("extreme"), do: "bg-fuchsia-600 border-fuchsia-700 text-white"
  def applies_badge_color(_applies), do: "bg-base-200 border-base-300"

  def goal_select_color("optional"), do: ""
  def goal_select_color(goal), do: elem(goal_colors(goal), 1)

  def action_repeats("heal"), do: [{"once", "Once each"}, {"until_full", "Until healed"}]
  def action_repeats("heal_all"), do: [{"once", "1 time"}, {"2", "2 times"}, {"3", "3 times"}, {"until_full", "Until all healed"}]
  def action_repeats(_action), do: []

  def goal_label("required"), do: "Required"
  def goal_label("optional"), do: "Optional"
  def goal_label("abandon"), do: "Abandon"
  def goal_label("use"), do: "Use"
  def goal_label(letter), do: "Goal #{letter}"

  def goal_hint("required", _section), do: "Required: the stage is not finished until this is owned."
  def goal_hint("optional", _section), do: "Optional: never blocks the stage. Kept, bought, fused and upgraded only when it comes along."
  def goal_hint("use", _section), do: "Use: the bot does this on the floors this tab covers."
  def goal_hint("abandon", _section), do: "Abandon: the bot does not pursue this and it does not count toward the stage."

  def goal_hint(letter, section) do
    min = Enum.find_value(section["goals"] || [], fn goal -> goal["letter"] == letter && goal["min"] end)
    "Goal #{letter}: the stage needs at least #{min || "N"} of the entries in this group, not all of them."
  end

  def goal_member_count(section, letter, views \\ []) do
    own = Enum.count(section["entries"] || [], &goal_member?(&1, letter))
    packed = for view <- views, item <- view.entries, not item.shadowed, goal_member?(item.entry, letter), reduce: 0, do: (count -> count + 1)
    own + packed
  end

  defp goal_member?(entry, letter), do: Enum.any?(GiftPlans.all_floors(entry), &(&1["goal"] == letter and &1["disposition"] == "keep"))

  def pack_gifts(pack, gifts_by_name) do
    pack.data["sections"]
    |> hd()
    |> Map.fetch!("entries")
    |> Enum.flat_map(&List.wrap(gifts_by_name[GiftPlans.subject_gift(&1)]))
    |> Enum.take(3)
  end

  def pack_delete_confirm(%{name: name, uses: 0}), do: "Delete the starter pack #{name}? No plans use it."
  def pack_delete_confirm(%{name: name, uses: 1}), do: "Delete the starter pack #{name}? 1 plan uses it and will lose its entries."
  def pack_delete_confirm(%{name: name, uses: uses}), do: "Delete the starter pack #{name}? #{uses} plans use it and will lose its entries."

  def pack_rows(view) do
    for item <- view.entries,
        timeline <- [nil | Enum.map(GiftPlans.timelines(item.entry), & &1["id"])],
        from <- Enum.map(GiftPlans.timeline_view(item.entry, timeline)["floors"], & &1["from"]),
        do: {item, timeline, from}
  end

  def pack_row_label(entry, timeline, from) do
    kinds = timeline && GiftPlans.find_timeline(entry, timeline)["kinds"]
    scope = if kinds, do: " · " <> Enum.map_join(kinds, ", ", &applies_label/1), else: ""
    segment_label(GiftPlans.timeline_view(entry, timeline), from) <> scope
  end

  def uptie_title(nil, _level), do: nil
  def uptie_title(_gift, 0), do: "No uptie"

  def uptie_title(gift, level) do
    case GiftPlans.uptie_cost(gift.tier, 0, level) do
      nil -> "Uptie to +#{level}"
      cost -> "Uptie to +#{level} (#{cost} from +0, estimate)"
    end
  end

  def recipe_parts(section, gift, gifts_by_id) do
    names = for name <- GiftPlans.recipe_names(gift, gifts_by_id), do: {name, GiftPlans.has_gift?(section, name)}
    slots = GiftPlans.fragment_slots(gift)
    fragments = Enum.count(section["entries"] || [], &(GiftPlans.subject_gift(&1) in GiftPlans.sin_fragments()))
    if slots > 0, do: names ++ [{"#{slots} Sin Fragments", fragments >= slots}], else: names
  end

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

  def filtered_gifts(gifts, filter, tier_filter, affinity_filter, mode_filter, fixed_filter, no_pack_filter, pack_filter, theme_packs_by_gift_id, gifts_by_id, sort_by) do
    gifts
    |> Enum.filter(&matches_text_filter?(&1, filter))
    |> Enum.filter(&(tier_filter == [] or &1.tier in tier_filter))
    |> Enum.filter(&(affinity_filter == [] or &1.affinity in affinity_filter))
    |> Enum.filter(&(mode_filter == [] or gift_mode(&1) in mode_filter))
    |> Enum.filter(&(not fixed_filter or GiftPlans.fixed_recipe?(&1)))
    |> Enum.filter(&(not no_pack_filter or GiftPlans.theme_pack_agnostic?(&1, gifts_by_id, theme_packs_by_gift_id)))
    |> Enum.filter(&matches_pack_filter?(&1, pack_filter, gifts_by_id, theme_packs_by_gift_id))
    |> sort_gifts(sort_by)
  end

  def gift_modes, do: @gift_modes

  def gift_mode_label("normal"), do: "Normal"
  def gift_mode_label("hard"), do: "Hard"
  def gift_mode_label("extreme"), do: "Extreme"

  defp gift_mode(%{extreme_only: true}), do: "extreme"
  defp gift_mode(%{hard_only: true}), do: "hard"
  defp gift_mode(_gift), do: "normal"

  def pack_only_filter, do: "__pack_only__"

  defp matches_pack_filter?(_gift, "", _gifts_by_id, _packs_by_gift_id), do: true
  defp matches_pack_filter?(gift, "__pack_only__", gifts_by_id, packs_by_gift_id), do: not GiftPlans.theme_pack_agnostic?(gift, gifts_by_id, packs_by_gift_id)
  defp matches_pack_filter?(gift, pack, _gifts_by_id, packs_by_gift_id), do: pack in Map.get(packs_by_gift_id, gift.id, [])

  def pack_filter_label(""), do: "Any"
  def pack_filter_label("__pack_only__"), do: "Theme pack only"
  def pack_filter_label(name), do: name

  def theme_pack_names(theme_packs_by_gift_id), do: theme_packs_by_gift_id |> Map.values() |> List.flatten() |> Enum.uniq() |> Enum.sort()

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

  def uptie_level_available?(gift, 1), do: String.trim(gift.uptie2 || "") != ""
  def uptie_level_available?(gift, 2), do: String.trim(gift.uptie3 || "") != ""

  def uptie_view_available?(gift, "base", gifts_by_id), do: not is_nil(clean_gift_text(gift.description, gifts_by_id))
  def uptie_view_available?(gift, "uptie2", gifts_by_id), do: not is_nil(clean_gift_text(gift.uptie2, gifts_by_id))
  def uptie_view_available?(gift, "uptie3", gifts_by_id), do: not is_nil(clean_gift_text(gift.uptie3, gifts_by_id))

  def gift_detail_text(gift, "base", gifts_by_id),
    do: clean_gift_text(gift.description, gifts_by_id) || "No description available."

  def gift_detail_text(gift, "uptie2", gifts_by_id),
    do: clean_gift_text(gift.uptie2, gifts_by_id) || "No + uptie change."

  def gift_detail_text(gift, "uptie3", gifts_by_id),
    do: clean_gift_text(gift.uptie3, gifts_by_id) || "No ++ uptie change."

  def fusion_ingredients(gift, gifts_by_id, packs_by_gift_id) do
    if GiftPlans.fixed_recipe?(gift) do
      slots = GiftPlans.fragment_slots(gift)
      fragments = if slots > 0, do: [%{name: "Sin Fragment x#{slots}", image_path: nil, packs: []}], else: []

      ingredients =
        for id <- GiftPlans.recipe_ids(gift), ingredient = gifts_by_id[id] do
          %{name: ingredient.name, image_path: ingredient.image_path, packs: packs_by_gift_id[id] || []}
        end

      ingredients ++ fragments
    end
  end

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

  defp reset_editor(socket) do
    socket
    |> assign(:editing_id, nil)
    |> assign(:name, "")
    |> assign(:plan_data, GiftPlans.blank())
    |> assign(:active_tab, :shop)
    |> assign(:root_section_id, nil)
    |> assign(:entry_tabs, %{})
    |> assign(:refresh_tabs, %{})
    |> assign(:renaming_stage_id, nil)
    |> assign(:refresh_paths, %{})
    |> assign(:fusion_entry_id, nil)
    |> assign(:editing_condition_case_id, nil)
    |> assign(:pack_edit, nil)
    |> assign(:pack_locked, false)
    |> reset_browser()
  end

  defp reset_search(socket), do: assign(socket, :gift_filter, "")

  defp reset_browser(socket) do
    socket
    |> reset_search()
    |> assign(:gift_tier_filter, [])
    |> assign(:gift_affinity_filter, [])
    |> assign(:gift_mode_filter, [])
    |> assign(:gift_fixed_filter, false)
    |> assign(:gift_no_pack_filter, false)
    |> assign(:gift_pack_filter, "")
    |> assign(:gift_sort, "default")
  end

  defp load_plan(socket, id, template_id \\ nil) do
    case Plans.for_team(%{gift_plan_id: id, gift_template_id: template_id}, :gift_plans) do
      nil ->
        put_flash(socket, :error, "Plan not found.")

      plan ->
        data = GiftPlans.normalize(plan.data)

        socket
        |> assign(:editing_id, id)
        |> assign(:template_id, plan.template_id)
        |> assign(:name, plan.name)
        |> assign(:plan_data, data)
        |> assign(:active_tab, :shop)
            |> assign(:root_section_id, first_id(data["sections"]))
                |> assign(:entry_tabs, %{})
        |> assign(:refresh_tabs, %{})
        |> assign(:renaming_stage_id, nil)
        |> assign(:refresh_paths, %{})
    |> assign(:refresh_paths, %{})
        |> assign(:fusion_entry_id, nil)
            |> reset_search()
        |> PlanHistory.reset()
    end
  end

  defp persist_plan(%{assigns: %{pack_edit: %{editable: true} = edit}} = socket) do
    socket = PlanHistory.record(socket)

    case GiftStarterPacks.save(edit.ref, %{data: socket.assigns.plan_data}) do
      {:ok, _ref} -> socket
      {:error, reason} -> put_flash(socket, :error, "Save failed: #{inspect(reason)}")
    end
  end

  defp persist_plan(%{assigns: %{pack_edit: %{}}} = socket), do: socket

  defp persist_plan(%{assigns: %{template_id: template_id}} = socket) when is_integer(template_id) do
    if PlanTemplates.writable?() do
      socket |> PlanHistory.record() |> save_template(:gift_plans, socket.assigns.plan_data)
    else
      socket
    end
  end

  defp persist_plan(socket) do
    socket = PlanHistory.record(socket)
    attrs = %{id: socket.assigns.editing_id, name: socket.assigns.name, data: socket.assigns.plan_data}

    case Plans.save(:gift_plans, attrs) do
      {:ok, _id} -> broadcast_count(socket, :gift_plans, socket.assigns.plan_data)
      {:error, reason} -> put_flash(socket, :error, "Save failed: #{inspect(reason)}")
    end
  end

  defp refresh_packs(socket), do: assign(socket, :starter_packs, GiftStarterPacks.list())

  defp open_pack(socket, ref) do
    case GiftStarterPacks.get(ref) do
      nil ->
        socket |> refresh_packs() |> put_flash(:error, "Starter pack not found.")

      pack ->
        parent = Map.take(socket.assigns, [:plan_data, :root_section_id, :active_tab])

        socket
        |> assign(:pack_edit, %{ref: ref, name: pack.name, affinity: pack.affinity, notes: pack.notes, uses: GiftStarterPacks.usage_count(ref), editable: pack.editable, source: pack.source, parent: parent})
        |> assign(:pack_locked, not pack.editable)
        |> assign(:plan_data, pack.data)
        |> assign(:root_section_id, GiftStarterPacks.section(pack)["id"])
        |> assign(:active_tab, :shop)
        |> assign(:entry_tabs, %{})
        |> assign(:refresh_tabs, %{})
        |> assign(:renaming_stage_id, nil)
        |> assign(:refresh_paths, %{})
        |> assign(:fusion_entry_id, nil)
        |> assign(:editing_condition_case_id, nil)
        |> assign(:gift_popup, nil)
        |> reset_search()
        |> PlanHistory.reset()
    end
  end

  defp close_pack(%{assigns: %{pack_edit: %{parent: parent}}} = socket) do
    socket
    |> assign(:pack_edit, nil)
    |> assign(:pack_locked, false)
    |> assign(:plan_data, parent.plan_data)
    |> assign(:root_section_id, parent.root_section_id)
    |> assign(:active_tab, parent.active_tab)
    |> assign(:entry_tabs, %{})
    |> assign(:refresh_tabs, %{})
    |> assign(:renaming_stage_id, nil)
    |> assign(:refresh_paths, %{})
    |> assign(:fusion_entry_id, nil)
    |> assign(:gift_popup, nil)
    |> reset_search()
    |> refresh_packs()
    |> PlanHistory.reset()
  end

  defp close_pack(socket), do: socket

  defp save_pack_fields(socket, ref, attrs, key, value) do
    case GiftStarterPacks.save(ref, attrs) do
      {:ok, _ref} -> socket |> update(:pack_edit, &Map.put(&1, key, value)) |> refresh_packs()
      {:error, :name_taken} -> put_flash(socket, :error, "Another starter pack already has that name.")
      {:error, :blank_name} -> put_flash(socket, :error, "A starter pack needs a name.")
      {:error, reason} -> put_flash(socket, :error, "Save failed: #{inspect(reason)}")
    end
  end

  defp reconcile_selection(socket) do
    %{plan_data: data, root_section_id: selected} = socket.assigns
    selected = if GiftPlans.find_root(data, selected), do: selected, else: first_id(data["sections"])

    socket
    |> assign(:root_section_id, selected)
    |> assign(:editing_condition_case_id, nil)
    |> assign(:fusion_entry_id, nil)
  end

  defp section_param(socket, %{"section" => id}) when is_binary(id) do
    if GiftPlans.find_section(socket.assigns.plan_data, id), do: id, else: socket.assigns.root_section_id
  end

  defp section_param(socket, _params), do: socket.assigns.root_section_id

  def target_section_id(%{assigns: assigns}), do: target_section_id(assigns)

  def target_section_id(%{plan_data: data, root_section_id: root}) do
    data |> GiftPlans.sections(root) |> List.last() |> then(&(&1 && &1["id"]))
  end

  defp add_section_id(socket, %{"section" => id}) when is_binary(id) do
    if Enum.any?(GiftPlans.sections(socket.assigns.plan_data, socket.assigns.root_section_id), &(&1["id"] == id)), do: id, else: target_section_id(socket)
  end

  defp add_section_id(socket, _params), do: target_section_id(socket)

  def target_section(assigns), do: GiftPlans.find_section(assigns.plan_data, target_section_id(assigns))

  defp entry_section_id(socket, entry_id) do
    sections = GiftPlans.sections(socket.assigns.plan_data, socket.assigns.root_section_id)
    Enum.find_value(sections, target_section_id(socket), &(GiftPlans.find_entry(&1, entry_id) && &1["id"]))
  end

  def entry_section(socket, entry_id), do: GiftPlans.find_section(socket.assigns.plan_data, entry_section_id(socket, entry_id))

  defp update_plan(socket, fun), do: socket |> assign(:plan_data, fun.(socket.assigns.plan_data)) |> persist_plan()

  defp update_condition(socket, %{"branch" => branch, "entry" => entry_id, "from" => from} = params, fun) do
    timeline = blank_to_nil(params["timeline"])
    from = String.to_integer(from)

    socket =
      for_group(socket, entry_id, fn socket, id ->
        section_id = entry_section_id(socket, id)

        update_plan(socket, fn data ->
          segment = data |> GiftPlans.find_section(section_id) |> GiftPlans.find_entry(id) |> GiftPlans.timeline_view(timeline) |> Map.fetch!("floors") |> Enum.find(&(&1["from"] == from))

          case segment && GiftPlans.find_branch(segment, branch) do
            %{"condition" => condition} ->
              case condition |> fun.() |> GiftPlans.prune_condition() do
                nil -> GiftPlans.remove_branch(data, section_id, id, from, timeline, branch)
                updated -> GiftPlans.set_branch_condition(data, section_id, id, from, timeline, branch, updated)
              end

            _ ->
              data
          end
        end)
      end)

    if branch_param(socket, entry_id), do: socket, else: put_tab(socket, entry_id, timeline, from)
  end

  defp update_condition(socket, %{"case_id" => id}, fun) do
    update_plan(socket, &GiftPlans.update_refresh_case(&1, socket.assigns.root_section_id, id, fn refresh_case ->
      Map.put(refresh_case, "condition", refresh_case["condition"] |> fun.() |> GiftPlans.prune_condition())
    end))
  end

  defp update_section(socket, id, fun), do: update_plan(socket, &GiftPlans.update_section(&1, id, fun))

  defp update_routes(socket, entry_id, fun) do
    update_plan(socket, &GiftPlans.update_entry(&1, entry_section_id(socket, entry_id), entry_id, fn entry ->
      Map.update!(entry, "fusion", fn fusion -> Map.update(fusion, "routes", fun.([]), fun) end)
    end))
  end

  defp apply_team_profiles(segment, picks) when is_map(picks) do
    replacements = Enum.reduce(picks, segment["replacements"] || [], fn {sinner, id}, acc -> GiftPlans.set_team_replacement_profile(acc, sinner, parse_optional_int(id)) end)
    Map.put(segment, "replacements", replacements)
  end

  defp apply_team_profiles(segment, _picks), do: segment

  defp apply_goal(segment, nil, _pattern?), do: segment
  defp apply_goal(segment, "abandon", _pattern?), do: Map.put(segment, "abandoned", true)
  defp apply_goal(segment, "use", _pattern?), do: Map.put(segment, "abandoned", false)

  defp apply_goal(segment, goal, pattern?) do
    segment = Map.merge(segment, %{"goal" => goal, "abandoned" => false})
    if segment["disposition"] == "ignore" and not pattern?, do: Map.put(segment, "disposition", "keep"), else: segment
  end

  defp set_scheduled(socket, entry_id) do
    update_plan(socket, &GiftPlans.update_entry(&1, entry_section_id(socket, entry_id), entry_id, fn entry -> Map.put(entry, "scheduled", true) end))
  end

  defp refresh_path_key(socket), do: {selected_section(socket.assigns)["id"], refresh_from(socket)}

  defp put_refresh_path(socket, path), do: assign(socket, :refresh_paths, Map.put(socket.assigns.refresh_paths, refresh_path_key(socket), path))

  def refresh_path(assigns, section, from) do
    cases = GiftPlans.refresh_cases(section, from)

    case Map.fetch(assigns.refresh_paths, {section["id"], from}) do
      {:ok, path} -> Enum.take(path, RefreshCosts.columns(cases))
      :error -> RefreshCosts.default_path(cases)
    end
  end

  defp refresh_from(socket), do: active_refresh_from(socket.assigns.refresh_tabs, selected_section(socket.assigns))

  defp put_refresh_tab(socket, from), do: assign(socket, :refresh_tabs, Map.put(socket.assigns.refresh_tabs, selected_section(socket.assigns)["id"], from))

  defp tab_key(socket, entry_id), do: GiftPlans.group_key(GiftPlans.find_entry(entry_section(socket, entry_id), entry_id))

  defp for_group(socket, entry_id, fun) do
    socket
    |> entry_section(entry_id)
    |> GiftPlans.group_members(entry_id)
    |> Enum.reduce(socket, &fun.(&2, &1["id"]))
  end

  defp update_segment(socket, entry_id, from, fun, params \\ %{}) do
    timeline = timeline_param(socket, entry_id, params)
    from = String.to_integer(from)
    branch = if from == active_from(socket.assigns.entry_tabs, GiftPlans.find_entry(entry_section(socket, entry_id), entry_id)), do: branch_param(socket, entry_id)
    update_plan(socket, &GiftPlans.update_segment(&1, entry_section_id(socket, entry_id), entry_id, from, fun, timeline, branch))
  end

  defp timeline_param(_socket, _entry_id, %{"timeline" => ""}), do: nil
  defp timeline_param(_socket, _entry_id, %{"timeline" => timeline}), do: timeline
  defp timeline_param(socket, entry_id, _params), do: active_timeline(socket.assigns.entry_tabs, GiftPlans.find_entry(entry_section(socket, entry_id), entry_id))

  defp put_tab(socket, entry_id, timeline, from, branch \\ nil) do
    tab = if branch, do: {timeline, from, branch}, else: {timeline, from}
    assign(socket, :entry_tabs, Map.put(socket.assigns.entry_tabs, tab_key(socket, entry_id), tab))
  end

  defp branch_param(socket, entry_id) do
    entry = GiftPlans.find_entry(entry_section(socket, entry_id), entry_id)
    active_branch(socket.assigns.entry_tabs, entry)
  end

  defp ensure_fusion(socket, entry_id) do
    case fusion_entry(socket, entry_id) do
      {%{"fusion" => nil}, %{} = gift} ->
        fusion = GiftPlans.default_fusion(gift, &FusionRouteTemplates.initial/1)
        update_plan(socket, &GiftPlans.update_entry(&1, entry_section_id(socket, entry_id), entry_id, fn entry -> Map.put(entry, "fusion", fusion) end))

      _ ->
        socket
    end
  end

  defp fusion_entry(socket, entry_id) do
    entry = socket |> entry_section(entry_id) |> GiftPlans.find_entry(entry_id)
    {entry, socket.assigns.gifts_by_name[GiftPlans.subject_gift(entry)]}
  end

  defp update_encounter_rows(data, fun), do: Map.update!(data, "encounter_rewards", fun)

  defp update_encounter_order(data, index, fun) do
    update_encounter_rows(data, fn rows -> List.update_at(rows, String.to_integer(index), fn row -> %{row | "order" => fun.(row["order"])} end) end)
  end

  defp sort_schedule(rows) do
    case Enum.sort_by(rows, & &1["from_floor"]) do
      [first | rest] -> [Map.put(first, "from_floor", 1) | rest]
      [] -> []
    end
  end

  defp first_id([%{"id" => id} | _]), do: id
  defp first_id(_), do: nil

  defp put_min_cost(refresh_case, nil), do: refresh_case

  defp put_min_cost(refresh_case, value) do
    case Integer.parse(value) do
      {int, _} -> Map.put(refresh_case, "min_cost", max(int, 0))
      :error -> Map.put(refresh_case, "min_cost", 0)
    end
  end

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

  defp toggle(list, value), do: if(value in list, do: List.delete(list, value), else: [value | list])

  defp matches_text_filter?(_gift, ""), do: true
  defp matches_text_filter?(gift, filter), do: String.contains?(String.downcase(gift.name || ""), String.downcase(filter))

  defp goal_options(plan_data, section) do
    root = GiftPlans.root_id(plan_data, section["id"])

    required =
      case GiftPlans.sections(plan_data, root) do
        sections when length(sections) > 1 -> [{"required", "Required (current stage)"} | Enum.map(sections, &{"required:" <> &1["id"], "Required: " <> GiftPlans.section_name(&1)})]
        _ -> [{"required", "Required"}]
      end

    required ++ Enum.map(GiftPlans.all_goal_letters(plan_data, root), &{&1, goal_label(&1)})
  end

  defp goal_value(%{"goal" => "required", "stage" => id}) when is_binary(id), do: "required:" <> id
  defp goal_value(node), do: node["goal"] || "required"

  def gift_leaf(assigns) do
    ~H"""
    <input type="hidden" name="not" value="false" />
    <label title="Negate this condition" class="relative cursor-pointer">
      <input type="checkbox" name="not" value="true" checked={@node["not"] == true} class="peer sr-only" />
      <span class="inline-flex items-center justify-center h-6 w-6 rounded border border-dashed border-base-content/20 text-sm text-base-content/25 select-none peer-checked:hidden">≠</span>
      <span class="hidden items-center h-6 px-1.5 rounded bg-error text-[11px] font-semibold text-error-content select-none peer-checked:inline-flex">NOT</span>
    </label>
    <StarlightBotWeb.Live.BattlePlanEditorLive.radio_group name="op" value={@node["op"]}
      options={if(Map.get(assigns, :branch?), do: [{"cost", "cost"}, {"refreshes", "refreshes"}, {"owns", "owns"}, {"goal", "goal done"}], else: [{"cost", "cost"}, {"refreshes", "refreshes"}, {"owns", "owns"}, {"stage", "on stage"}, {"goal", "goal done"}, {"run_kind", "run type"}])} />
    <%= cond do %>
      <% @node["op"] in ["cost", "refreshes"] -> %>
        <StarlightBotWeb.Live.BattlePlanEditorLive.radio_group :if={@node["op"] == "cost"} name="when" value={@node["when"] || "before"} options={[{"before", "before refresh"}, {"after", "after refresh"}]} />
        <StarlightBotWeb.Live.BattlePlanEditorLive.radio_group name="cmp" value={@node["cmp"]} options={[{"eq", "="}, {"gte", "≥"}, {"lte", "≤"}]} />
        <input type="number" name="value" min="0" value={@node["value"]} phx-debounce="400" class="input input-bordered input-xs w-24" />
      <% @node["op"] == "stage" -> %>
        <select name="stage" class="select select-bordered select-xs flex-1 min-w-0">
          <option value="">pick one</option>
          <option :for={section <- GiftPlans.sections(@plan_data, GiftPlans.root_id(@plan_data, @section["id"]))} value={section["id"]} selected={@node["stage"] == section["id"]}><%= GiftPlans.section_name(section) %></option>
          <option value="done" selected={@node["stage"] == "done"}>All stages done</option>
        </select>
      <% @node["op"] == "goal" -> %>
        <select name="goal" class="select select-bordered select-xs">
          <option :for={{value, label} <- goal_options(@plan_data, @section)} value={value} selected={goal_value(@node) == value}><%= label %></option>
        </select>
      <% @node["op"] == "run_kind" -> %>
        <select name="kind" class="select select-bordered select-xs">
          <option :for={kind <- GiftPlans.condition_run_kinds()} value={kind} selected={@node["kind"] == kind} title={applies_hint(kind)}><%= applies_label(kind) %></option>
        </select>
      <% true -> %>
        <input type="text" name="gift" value={@node["gift"]} list="gift-name-options" phx-debounce="blur"
               placeholder="Gift name" class="input input-bordered input-xs flex-1 min-w-0" />
    <% end %>
    """
  end

  attr :gifts, :list, required: true
  attr :loadout, :boolean, required: true

  def gift_rows(assigns) do
    ~H"""
    <div :for={gift <- @gifts} data-gift-row={gift.name} data-drag-gift={gift.name} class="flex items-center gap-1.5 rounded px-1 py-0.5 hover:bg-base-200">
      <div data-gift-popup={gift.name} class="relative w-7 h-7 shrink-0 rounded overflow-hidden bg-base-200 ring-1 ring-base-300 cursor-pointer">
        <img src={gift.image_path} loading="lazy" class="w-full h-full object-cover" draggable="false" />
        <img :if={gift.affinity not in [nil, "none"]} src={gift_affinity_icon(gift.affinity)} title={gift.affinity} loading="lazy" draggable="false"
             class="absolute bottom-0 right-0 w-3 h-3 object-contain drop-shadow" />
      </div>
      <span :if={gift.tier} class="text-[10px] text-base-content/50 w-4 shrink-0">T<%= gift.tier %></span>
      <span data-gift-popup={gift.name} data-gift-name class="text-[11px] truncate flex-1 min-w-0 select-none cursor-grab" title={gift.name}><%= gift.name %></span>
      <button :if={@loadout} data-gift-added phx-click="toggle_search_gift" phx-value-gift={gift.name} class="btn btn-xs btn-primary hidden" title="Remove from gift search">Added</button>
      <button :if={not @loadout} data-gift-added class="btn btn-xs btn-primary hidden" disabled>Added</button>
      <button data-gift-add phx-click={if @loadout, do: "toggle_search_gift", else: "list_add_gift"} phx-value-gift={gift.name} class="btn btn-xs btn-outline"
              title={if @loadout, do: "Add to gift search", else: if(GiftPlans.fixed_recipe?(gift), do: "Also adds its ingredients")}>Add</button>
    </div>
    <div :if={@gifts == []} class="text-xs text-base-content/40 italic p-1">No matching gifts.</div>
    """
  end

  attr :entry, :map, required: true
  attr :from, :integer, required: true
  attr :timeline, :string, default: nil
  attr :branch, :string, default: nil
  attr :editing, :string, default: nil
  attr :plan_data, :map, required: true
  attr :section, :map, required: true

  def branch_strip(assigns) do
    segment = Enum.find(GiftPlans.timeline_view(assigns.entry, assigns.timeline)["floors"], &(&1["from"] == assigns.from))
    branches = GiftPlans.branches(segment)
    editing = Enum.find(branches, &(&1["id"] == assigns.editing))
    index = editing && Enum.find_index(branches, &(&1["id"] == editing["id"]))

    values = fn branch ->
      %{"entry" => assigns.entry["id"], "from" => assigns.from, "timeline" => assigns.timeline || "", "branch" => branch["id"]}
    end

    assigns = assign(assigns, branches: branches, editing_branch: editing, editing_index: index, values: values)

    ~H"""
    <div class="flex flex-col gap-1 border-2 border-b-0 border-primary bg-primary/10 rounded-tr-lg px-1.5 py-1">
      <div class="flex items-center gap-1 flex-wrap text-[11px]">
        <.icon name="lucide-split" class="size-3.5 text-primary shrink-0" />
        <%= for {branch, index} <- Enum.with_index(@branches) do %>
          <span class="font-semibold text-base-content/60"><%= if index == 0, do: "if", else: "else if" %></span>
          <span class={"inline-flex items-center rounded border " <> if(@branch == branch["id"], do: "border-primary bg-primary text-primary-content", else: "border-primary/40 bg-base-100 hover:bg-primary/20")}>
            <button type="button" phx-click="list_select_branch" phx-value-entry={@entry["id"]} phx-value-timeline={@timeline || ""} phx-value-from={@from} phx-value-branch={branch["id"]}
                    class="max-w-64 truncate px-1.5 py-0.5"><%= GiftPlans.condition_label(branch["condition"], @plan_data) || "always" %></button>
            <button type="button" phx-click="open_case_condition" phx-value-case_id={branch["id"]} title="Edit this condition" class="px-1 py-0.5 opacity-70 hover:opacity-100">
              <.icon name="lucide-pencil" class="size-3" />
            </button>
          </span>
        <% end %>
        <span class="font-semibold text-base-content/60">else</span>
        <button type="button" phx-click="list_select_branch" phx-value-entry={@entry["id"]} phx-value-timeline={@timeline || ""} phx-value-from={@from} phx-value-branch=""
                class={"rounded border px-1.5 py-0.5 " <> if(is_nil(@branch), do: "border-primary bg-primary text-primary-content", else: "border-primary/40 bg-base-100 hover:bg-primary/20")}>otherwise</button>
        <button type="button" phx-click="list_add_branch" phx-value-entry={@entry["id"]} phx-value-timeline={@timeline || ""} phx-value-from={@from}
                title="Add another condition" class="rounded border border-dashed border-primary/60 px-1.5 py-0.5 text-primary hover:bg-primary/20">+</button>
      </div>
      <div :if={@editing_branch} phx-click-away="close_case_condition" class="flex items-start gap-1 rounded border border-base-300 bg-base-100 p-1">
        <button type="button" phx-click="close_case_condition" title="Close the condition editor" class="btn btn-ghost btn-xs h-6 min-h-6 px-1">▾</button>
        <div class="flex-1 min-w-0 flex flex-col gap-1">
          <.condition_node node={@editing_branch["condition"]} path="" values={@values.(@editing_branch)} removable={false}
                           leaf={&gift_leaf(Map.merge(&1, %{plan_data: @plan_data, section: @section, branch?: true}))} />
          <p :for={warning <- GiftPlans.condition_warnings(@editing_branch["condition"], @plan_data, @section)} class="flex items-center gap-1 text-[11px] text-warning">
            <.icon name="lucide-triangle-exclamation-point" class="size-3.5 shrink-0" /><%= warning %>
          </p>
        </div>
        <button type="button" phx-click="list_move_branch" phx-value-entry={@entry["id"]} phx-value-timeline={@timeline || ""} phx-value-from={@from} phx-value-branch={@editing_branch["id"]} phx-value-delta="-1"
                disabled={@editing_index == 0} title="Check earlier" class="btn btn-ghost btn-xs px-1"><.icon name="lucide-arrow-left" class="size-3.5" /></button>
        <button type="button" phx-click="list_move_branch" phx-value-entry={@entry["id"]} phx-value-timeline={@timeline || ""} phx-value-from={@from} phx-value-branch={@editing_branch["id"]} phx-value-delta="1"
                disabled={@editing_index == length(@branches) - 1} title="Check later" class="btn btn-ghost btn-xs px-1"><.icon name="lucide-arrow-right" class="size-3.5" /></button>
        <button type="button" phx-click="list_remove_branch" phx-value-entry={@entry["id"]} phx-value-timeline={@timeline || ""} phx-value-from={@from} phx-value-branch={@editing_branch["id"]}
                title="Delete this branch" class="btn btn-ghost btn-xs px-1 text-error"><.icon name="lucide-trash-2" class="size-3.5" /></button>
      </div>
    </div>
    """
  end

  attr :entry, :map, required: true
  attr :members, :list, required: true
  attr :from, :integer, required: true
  attr :timeline, :string, default: nil

  def schedule_tabs(assigns) do
    strips =
      for timeline_id <- [nil | Enum.map(GiftPlans.timelines(assigns.entry), & &1["id"])] do
        lead = GiftPlans.timeline_view(assigns.entry, timeline_id)
        froms = Enum.map(lead["floors"], & &1["from"])

        flags =
          Map.new(froms, fn from ->
            {from,
             Enum.map(assigns.members, fn member ->
               segment = Enum.find(GiftPlans.timeline_view(member, timeline_id)["floors"], &(&1["from"] == from))
               segment != nil and GiftPlans.abandoned?(member, segment)
             end)}
          end)

        %{
          id: timeline_id,
          entry: lead,
          kinds: timeline_id && GiftPlans.find_timeline(assigns.entry, timeline_id)["kinds"],
          froms: froms,
          abandoned_froms: for({from, list} <- flags, Enum.all?(list), do: from),
          kept_froms: for({from, list} <- flags, not Enum.any?(list), do: from)
        }
      end

    assigns = assign(assigns, strips: strips, used_kinds: GiftPlans.timeline_kinds(assigns.entry))

    ~H"""
      <div class="flex items-end gap-0.5 flex-wrap">
        <span data-sort-handle class="cursor-grab text-base-content/40 select-none px-1 pb-0.5" title="Drag this schedule and its entries">⠿</span>
        <%= for strip <- @strips do %>
          <details :if={strip.id} id={"applies-#{@entry["id"]}-#{strip.id}"} phx-hook="FloatingDropdown" data-keep-open class="dropdown self-end pb-0.5 pl-1.5">
            <summary title="Run types this timeline applies to"
                 class={"flex items-center gap-1 rounded-lg border px-1.5 py-0.5 text-[10px] font-semibold cursor-pointer list-none " <> applies_badge_color(hd(strip.kinds))}>
              <.icon name="lucide-swords" class="size-3" /><%= Enum.map_join(strip.kinds, " + ", &applies_label/1) %><.icon name="lucide-chevron-down" class="size-3" />
            </summary>
            <.timeline_kinds entry_id={@entry["id"]} strip={strip} used_kinds={@used_kinds} />
          </details>
          <div :for={from <- strip.froms}
               class={"flex items-center gap-0.5 rounded-t-lg border border-b-0 px-2 py-0.5 text-[11px] " <>
                 if(strip.id == @timeline and from == @from, do: "border-primary bg-primary text-primary-content font-semibold", else: "border-primary/40 bg-primary/25 hover:bg-primary/40")}
               style={if from in strip.abandoned_froms, do: StarlightBotWeb.Live.PackPlanEditorLive.disabled_stripes_style()}>
            <button type="button" phx-click="list_select_tab" phx-value-entry={@entry["id"]} phx-value-timeline={strip.id || ""} phx-value-from={from}><%= segment_label(strip.entry, from) %></button>
            <details id={"segment-#{@entry["id"]}-#{strip.id || "main"}-#{from}"} phx-hook="FloatingDropdown" data-keep-open class="dropdown">
              <summary class="cursor-pointer opacity-60 hover:opacity-100 list-none" title={if from == 1, do: "Tab options", else: "Change or abandon from a floor"}>
                <.icon name="lucide-chevron-down" class="size-3" />
              </summary>
              <div popover="manual" class={"dropdown-content z-30 rounded-lg border border-base-300 bg-base-100 p-1.5 shadow-lg space-y-1 " <> if(from == 1, do: "w-max", else: "w-56")}>
                <div :if={from != 1} class="join w-full">
                  <button :for={{mode, label} <- [{"change", "Change at"}, {"abandon", "Abandon at"}]} type="button" phx-click="list_set_segment_mode"
                          phx-value-entry={@entry["id"]} phx-value-timeline={strip.id || ""} phx-value-from={from} phx-value-mode={mode}
                          class={"btn btn-xs join-item flex-1 whitespace-nowrap " <> if(from in if(mode == "abandon", do: strip.abandoned_froms, else: strip.kept_froms), do: "btn-primary", else: "btn-outline")}><%= label %></button>
                </div>
                <div :if={from != 1} class="grid grid-cols-5 gap-0.5">
                  <button :for={floor <- 2..GiftPlans.max_floor()} type="button" phx-click="list_move_segment" phx-value-entry={@entry["id"]} phx-value-timeline={strip.id || ""}
                          phx-value-from={from} phx-value-to={floor} disabled={floor != from and floor in strip.froms}
                          class={"btn btn-xs " <> if(floor == from, do: "btn-primary", else: "btn-ghost")}>F<%= floor %></button>
                </div>
                <button type="button" phx-click="list_add_branch" phx-value-entry={@entry["id"]} phx-value-timeline={strip.id || ""} phx-value-from={from} data-dismiss
                        class="btn btn-xs btn-outline w-full justify-start gap-1"><.icon name="lucide-split" class="size-3.5" />+ if condition</button>
              </div>
            </details>
            <button :if={from != 1} type="button" phx-click="list_remove_segment" phx-value-entry={@entry["id"]} phx-value-timeline={strip.id || ""} phx-value-from={from}
                    class="opacity-60 hover:opacity-100" title={"Close this tab; #{segment_label(strip.entry, from)} use the earlier tab's settings"}><.icon name="lucide-x" class="size-3.5" /></button>
            <button :if={from == 1 and length(strip.froms) == 1 and is_nil(strip.id) and @used_kinds == []} type="button" phx-click="list_remove_schedule" phx-value-entry={@entry["id"]}
                    class="opacity-60 hover:opacity-100" title="Remove the schedule"><.icon name="lucide-x" class="size-3.5" /></button>
          </div>
          <button type="button" phx-click="list_split" phx-value-entry={@entry["id"]} phx-value-timeline={strip.id || ""} phx-value-floor={Enum.max(strip.froms) + 1}
                  disabled={Enum.max(strip.froms) >= GiftPlans.max_floor()} title="New tab"
                  class="rounded-t-lg border border-b-0 border-dashed border-primary/60 px-2 py-0.5 text-[11px] text-primary hover:bg-primary/20 disabled:opacity-30">+</button>
        <% end %>
        <details :if={length(@used_kinds) < length(GiftPlans.condition_run_kinds())} id={"new-timeline-#{@entry["id"]}"} phx-hook="FloatingDropdown" data-close-on-click class="dropdown">
          <summary title="New timeline for specific run types"
               class="rounded-t-lg border border-b-0 border-dashed border-primary/60 px-2 py-0.5 text-primary hover:bg-primary/20 cursor-pointer list-none">
            <.icon name="lucide-swords" class="size-3.5" />
          </summary>
          <.timeline_kinds entry_id={@entry["id"]} strip={nil} used_kinds={@used_kinds} />
        </details>
      </div>
    """
  end

  attr :section, :map, required: true
  attr :from, :integer, required: true
  attr :path, :list, required: true
  attr :plan_data, :map, required: true

  def refresh_costs(assigns) do
    cases = GiftPlans.refresh_cases(assigns.section, assigns.from)
    free = RefreshCosts.free(assigns.plan_data["grace_picks"])
    columns = RefreshCosts.columns(cases)
    {cheapest, _sequence} = RefreshCosts.cheapest(assigns.path, free)
    total = RefreshCosts.total(assigns.path, free)

    assigns =
      assign(assigns,
        columns: columns,
        free: free,
        cells: RefreshCosts.grid(assigns.path, free, columns),
        total: total,
        savings: total - cheapest,
        picked: length(assigns.path)
      )

    ~H"""
    <details :if={@columns > 0} id={"refresh-costs-#{@section["id"]}-#{@from}"} phx-hook="FloatingDropdown" data-keep-open class="dropdown">
      <summary class="badge badge-accent badge-outline h-6 gap-0 overflow-hidden px-0 cursor-pointer select-none"><span class="flex h-full items-center gap-1 bg-accent px-2 text-accent-content">Potential Cost <.icon name="lucide-chevron-down" class="size-3" /></span><span class="flex h-full items-center gap-0.5 px-2 font-semibold"><%= @total %><img src={~p"/images/icons/md_cost.png"} alt="" class="h-3.5 w-3.5 object-contain" /></span></summary>
      <div popover="manual" class="dropdown-content z-30 w-max max-w-[calc(100vw-1rem)] rounded-lg border border-base-300 bg-base-100 p-2 shadow-lg">
        <div class="flex flex-col gap-1 text-[11px]">
          <div class="flex flex-wrap items-center gap-2">
            <span class="font-semibold text-base-content/70">Visualize refresh costs</span>
            <button :if={@savings > 0} type="button" phx-click="rf_cheapest" class="btn btn-xs btn-outline" title="Reorder the same refreshes so the free ones land on the priciest slots"><span class="inline-flex items-center gap-0.5">Cheapest order saves <%= @savings %><img src={~p"/images/icons/md_cost.png"} alt="" class="h-3.5 w-3.5 object-contain" /></span></button>
            <button type="button" phx-click="rf_reset" class="btn btn-ghost btn-xs ml-auto" title="Go back to the order the cases imply">Reset</button>
          </div>
          <div class="overflow-x-auto">
            <table class="table table-xs w-auto">
              <thead>
                <tr>
                  <th class="whitespace-nowrap">Refresh count</th>
                  <th :for={cell <- @cells} class="text-center whitespace-nowrap">
                    <%= cell.position + 1 %>
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{kind, label} <- [{:normal, "Normal"}, {:keyword, "Keyword"}]}>
                  <th class="font-semibold whitespace-nowrap"><%= label %></th>
                  <td :for={cell <- @cells} class="p-0.5 text-center">
                    <% {cost, free?} = Map.fetch!(cell, kind) %>
                    <button type="button" phx-click="rf_pick" phx-value-step={cell.position} phx-value-kind={kind} disabled={cell.position > @picked}
                            class={"btn btn-xs w-full min-w-12 " <> cond do
                              cell.chosen == kind -> "btn-primary"
                              cell.position > @picked -> "btn-ghost opacity-40"
                              true -> "btn-outline"
                            end}>
                      <%= if free? do %>free<% else %><span class="inline-flex items-center gap-0.5"><%= cost %><img src={~p"/images/icons/md_cost.png"} alt="" class="h-3.5 w-3.5 object-contain" /></span><% end %>
                    </button>
                  </td>
                </tr>
                <tr>
                  <th class="font-semibold whitespace-nowrap">Total</th>
                  <td :for={cell <- @cells} class="text-center font-semibold"><span class="inline-flex items-center gap-0.5"><%= cell.total %><img src={~p"/images/icons/md_cost.png"} alt="" class="h-3.5 w-3.5 object-contain" /></span></td>
                </tr>
              </tbody>
            </table>
          </div>
          <div class="flex flex-wrap items-center gap-1">
            <span class="badge badge-sm badge-soft" title="Free normal refreshes from graces"><%= elem(@free, 0) %> normal <%= if elem(@free, 0) == 1, do: "refresh", else: "refreshes" %></span>
            <span class="badge badge-sm badge-soft" title="Free keyword refreshes from graces"><%= elem(@free, 1) %> keyword <%= if elem(@free, 1) == 1, do: "refresh", else: "refreshes" %></span>
          </div>
        </div>
      </div>
    </details>
    """
  end

  attr :section, :map, required: true
  attr :from, :integer, required: true

  def refresh_tabs(assigns) do
    assigns = assign(assigns, froms: GiftPlans.refresh_froms(assigns.section))

    ~H"""
    <div class="flex items-end gap-0.5">
      <div :for={from <- @froms}
           class={"flex items-center gap-0.5 rounded-t-lg border border-b-0 px-2 py-0.5 text-[11px] " <>
             if(from == @from, do: "border-primary bg-primary text-primary-content font-semibold", else: "border-primary/40 bg-primary/25 hover:bg-primary/40")}>
        <button type="button" phx-click="list_refresh_select_tab" phx-value-from={from}><%= refresh_tab_label(@section, from) %></button>
        <details :if={from != 1} id={"refresh-tab-#{@section["id"]}-#{from}"} phx-hook="FloatingDropdown" data-close-on-click class="dropdown">
          <summary class="cursor-pointer opacity-60 hover:opacity-100 list-none" title="Change the floor this starts on">
            <.icon name="lucide-chevron-down" class="size-3" />
          </summary>
          <div popover="manual" class="dropdown-content z-30 w-56 rounded-lg border border-base-300 bg-base-100 p-1.5 shadow-lg">
            <div class="grid grid-cols-5 gap-0.5">
              <button :for={floor <- 2..GiftPlans.max_floor()} type="button" phx-click="list_refresh_move_segment" phx-value-from={from} phx-value-to={floor}
                      disabled={floor != from and floor in @froms} class={"btn btn-xs " <> if(floor == from, do: "btn-primary", else: "btn-ghost")}>F<%= floor %></button>
            </div>
          </div>
        </details>
        <button :if={from != 1} type="button" phx-click="list_refresh_remove_segment" phx-value-from={from} class="opacity-60 hover:opacity-100"
                title={"Close this tab; #{refresh_tab_label(@section, from)} use the earlier tab's cases"}><.icon name="lucide-x" class="size-3.5" /></button>
        <button :if={from == 1 and length(@froms) == 1} type="button" phx-click="list_refresh_remove_schedule" class="opacity-60 hover:opacity-100"
                title="Remove the schedule"><.icon name="lucide-x" class="size-3.5" /></button>
      </div>
      <button type="button" phx-click="list_refresh_split" phx-value-floor={Enum.max(@froms) + 1}
              disabled={Enum.max(@froms) >= GiftPlans.max_floor()} title="New tab"
              class="rounded-t-lg border border-b-0 border-dashed border-primary/60 px-2 py-0.5 text-[11px] text-primary hover:bg-primary/20 disabled:opacity-30">+</button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :renaming_id, :string, default: nil
  attr :title, :string, required: true

  def stage_title(assigns) do
    ~H"""
    <%= if @renaming_id == @id do %>
      <input id={"stage-name-#{@id}"} type="text" value={@name} phx-blur="rename_stage" phx-value-id={@id} maxlength="40"
             phx-keydown="cancel_rename_stage" phx-key="Escape" phx-hook="FocusSelect"
             class="input input-bordered input-xs w-40 self-center font-semibold" />
    <% else %>
      <div id={"stage-title-#{@id}"} phx-hook="DblClickEvent" data-event="start_rename_stage" data-id={@id} title={@title}
           class="group flex items-center gap-1 self-center px-1">
        <h3 class="text-sm font-semibold"><%= @name %></h3>
        <button type="button" phx-click="start_rename_stage" phx-value-id={@id} title="Rename this stage"
                class="btn btn-2xs btn-ghost shrink-0 px-1 opacity-40 focus-visible:opacity-100 group-hover:opacity-100"><.icon name="lucide-pencil" class="size-3" /></button>
      </div>
    <% end %>
    """
  end

  attr :section, :map, required: true
  attr :views, :list, default: []

  def goal_chips(assigns) do
    ~H"""
    <div class={"rounded-lg border px-2 py-1 flex flex-col justify-center " <> goal_color("required")}>
      <span class="text-[11px] font-semibold">Required</span>
      <span class="text-[10px] text-base-content/50">all of <%= goal_member_count(@section, "required", @views) %></span>
    </div>
    <%= for view <- @views, goal <- view.goals do %>
      <div class={"rounded-lg border px-2 py-1 flex items-center gap-1 " <> goal_color(goal["letter"])}
           title={"Goal from the starter pack #{view.pack.name}. Only the pack's own entries count toward it; unpack the pack to edit it."}>
        <.icon name="lucide-lock" class="size-3 shrink-0 text-base-content/60" />
        <span class="text-[11px] font-semibold"><%= goal["letter"] %>:</span>
        <span class="text-[11px]">at least <%= goal["min"] %> of <%= goal_member_count(%{"entries" => []}, goal["letter"], [view]) %></span>
      </div>
    <% end %>
    <form :for={goal <- @section["goals"]} phx-change="list_set_goal_min" class={"rounded-lg border px-2 py-1 flex items-center gap-1 " <> goal_color(goal["letter"])}>
      <input type="hidden" name="letter" value={goal["letter"]} />
      <input type="hidden" name="section" value={@section["id"]} />
      <span class="text-[11px] font-semibold"><%= goal["letter"] %>:</span>
      <span class="text-[11px]">at least</span>
      <input type="number" min="1" name="min" value={goal["min"]} phx-debounce="400" class="input input-bordered input-xs w-12" />
      <span class="text-[11px]">of <%= goal_member_count(@section, goal["letter"]) %></span>
      <button type="button" phx-click="list_remove_goal" phx-value-letter={goal["letter"]} phx-value-section={@section["id"]} class="btn btn-ghost btn-2xs px-1 text-error"
              title="Remove this goal; its entries become required"><.icon name="lucide-x" class="size-3.5" /></button>
    </form>
    <button phx-click="list_add_goal" phx-value-section={@section["id"]} class="rounded-lg border border-dashed border-base-content/30 px-3 text-[11px] text-base-content/60 hover:bg-base-200">+ Goal</button>
    """
  end

  attr :section, :map, required: true
  attr :entry_tabs, :map, required: true
  attr :gifts_by_name, :map, required: true
  attr :gifts_by_id, :map, required: true
  attr :views, :list, default: []
  attr :packs_enabled, :boolean, default: true
  attr :plan_data, :map, default: nil
  attr :editing_branch, :string, default: nil

  def section_entries(assigns) do
    gifts = Enum.reject(assigns.section["entries"], &GiftPlans.top_entry?/1)
    assigns = assign(assigns, gifts: gifts)

    ~H"""
    <.starter_packs :if={@packs_enabled} section={@section} views={@views} gifts_by_name={@gifts_by_name} gifts_by_id={@gifts_by_id} />
    <.entry_list id={"section-entries-#{@section["id"]}"} shared={"list-#{@section["stage_of"] || @section["id"]}"} entries={@gifts} section={@section}
                 entry_tabs={@entry_tabs} gifts_by_name={@gifts_by_name} gifts_by_id={@gifts_by_id} plan_data={@plan_data} editing_branch={@editing_branch} />
    """
  end

  attr :section, :map, required: true
  attr :views, :list, required: true
  attr :gifts_by_name, :map, required: true
  attr :gifts_by_id, :map, required: true

  def starter_packs(assigns) do
    ~H"""
    <div id={"section-packs-#{@section["id"]}"} phx-hook="SortableList" data-sort-event="pack_reorder" data-sort-move-event="pack_move"
         data-sort-shared={"packs-#{@section["stage_of"] || @section["id"]}"} data-sort-scope={@section["id"]} class="flex flex-col gap-1 min-h-3 shrink-0">
    <div :for={view <- @views} data-sort-id={view.id} class="flex flex-col shrink-0">
      <%= if view.pack do %>
        <% pack_section = %{@section | "entries" => Enum.map(view.entries, & &1.entry), "goals" => view.goals} %>
        <div class="flex items-end gap-0.5 flex-wrap">
          <div class="flex items-center gap-1.5 rounded-t-lg border-2 border-b-0 border-primary bg-primary/10 px-2 py-0.5 text-[11px] font-semibold">
            <span data-sort-handle class="cursor-grab text-base-content/40 select-none" title="Drag to another stage or reorder. Earlier packs win when two hold the same gift.">⠿</span>
            <.icon name="lucide-package" class="size-3.5" />
            <span>Starter pack</span>
            <span class="font-normal"><%= view.pack.name %></span>
            <img :if={view.pack.affinity != "any"} src={gift_affinity_icon(view.pack.affinity)} title={view.pack.affinity} class="w-3.5 h-3.5 object-contain" />
            <span :if={view.pack.affinity == "any"} class="badge badge-ghost badge-xs">any</span>
          </div>
          <span class="ml-auto flex items-center gap-1 pb-0.5">
            <button type="button" phx-click="pack_edit" phx-value-ref={view.ref} class="btn btn-ghost btn-xs gap-1 px-1"
                    title="Open this starter pack. Changes apply to every plan that uses it."><.icon name="lucide-pencil" class="size-3.5" />Edit</button>
            <button type="button" phx-click="pack_unpack" phx-value-pack={view.id} phx-value-section={@section["id"]} class="btn btn-ghost btn-xs gap-1 px-1"
                    title="Copy every entry into this stage as normal entries and stop following the starter pack"><.icon name="lucide-package-open" class="size-3.5" />Unpack</button>
            <button type="button" phx-click="pack_remove" phx-value-pack={view.id} phx-value-section={@section["id"]} class="btn btn-ghost btn-xs px-1 text-error"
                    title="Remove this starter pack from the stage"><.icon name="lucide-x" class="size-3.5" /></button>
          </span>
        </div>
        <div class="flex flex-col gap-1 p-1 border-2 border-primary rounded-b-lg rounded-tr-lg">
          <.section_entry_row :for={{item, timeline, from} <- pack_rows(view)} entry={item.entry} section={pack_section} from={from} timeline={timeline} in_group={false}
                              readonly={true} shadowed={item.shadowed} gifts_by_name={@gifts_by_name} gifts_by_id={@gifts_by_id} />
          <div :if={view.entries == []} class="text-xs text-base-content/40 italic px-1">This starter pack has no entries yet.</div>
        </div>
      <% else %>
        <div class="flex items-center gap-2 rounded-lg border-2 border-warning bg-warning/10 px-2 py-1 text-xs">
          <.icon name="lucide-triangle-exclamation-point" class="size-4 shrink-0 text-warning" />
          <span class="flex-1">This starter pack no longer exists, so it adds nothing to the plan.</span>
          <button type="button" phx-click="pack_remove" phx-value-pack={view.id} phx-value-section={@section["id"]} class="btn btn-ghost btn-xs px-1 text-error" title="Remove it from this stage">
            <.icon name="lucide-x" class="size-3.5" />
          </button>
        </div>
      <% end %>
    </div>
    </div>
    """
  end

  attr :section, :map, required: true
  attr :entry_tabs, :map, required: true
  attr :gifts_by_name, :map, required: true
  attr :gifts_by_id, :map, required: true
  attr :plan_data, :map, default: nil
  attr :editing_branch, :string, default: nil

  def heal_entries(assigns) do
    assigns = assign(assigns, heals: Enum.filter(assigns.section["entries"], &GiftPlans.top_entry?/1))

    ~H"""
    <div :if={@heals != []} class="flex flex-col gap-1">
      <.entry_list id={"section-actions-#{@section["id"]}"} shared={"list-#{@section["id"]}-actions"} entries={@heals} section={@section}
                   entry_tabs={@entry_tabs} gifts_by_name={@gifts_by_name} gifts_by_id={@gifts_by_id} plan_data={@plan_data} editing_branch={@editing_branch} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :shared, :string, required: true
  attr :entries, :list, required: true
  attr :section, :map, required: true
  attr :entry_tabs, :map, required: true
  attr :gifts_by_name, :map, required: true
  attr :gifts_by_id, :map, required: true
  attr :plan_data, :map, default: nil
  attr :editing_branch, :string, default: nil

  defp entry_list(assigns) do
    ~H"""
    <div id={@id} phx-hook="SortableList" data-sort-event="list_reorder_entries" data-sort-move-event="list_move_entry"
         data-sort-shared={@shared} data-sort-scope={@section["id"]} data-sort-multi class="flex flex-col gap-1 min-h-6 shrink-0">
      <%= for chunk <- entry_chunks(@entries) do %>
        <%= case chunk do %>
          <% {:single, entry} -> %>
            <.section_entry_row entry={entry} section={@section} from={active_from(@entry_tabs, entry)} timeline={active_timeline(@entry_tabs, entry)} in_group={false}
                                  gifts_by_name={@gifts_by_name} gifts_by_id={@gifts_by_id} />
          <% {:group, key, [lead | _] = members} -> %>
            <div data-sort-id={"group:#{key}"} data-sort-stay class="flex flex-col">
              <.schedule_tabs entry={lead} members={members} from={active_from(@entry_tabs, lead)} timeline={active_timeline(@entry_tabs, lead)} />
              <% branched? = GiftPlans.branches(active_segment(@entry_tabs, lead)) != [] %>
              <.branch_strip :if={branched?} entry={lead} from={active_from(@entry_tabs, lead)} timeline={active_timeline(@entry_tabs, lead)} branch={active_branch(@entry_tabs, lead)}
                             editing={@editing_branch} plan_data={@plan_data} section={@section} />
              <div id={"entry-group-#{key}"} data-drop-group={key} phx-hook="SortableList" data-sort-event="list_reorder_entries" data-sort-move-event="list_move_entry"
                   data-sort-shared={@shared} data-sort-scope={"group:#{key}"} data-sort-highlight data-sort-multi
                   class={"flex flex-col gap-1 min-h-8 p-1 border-2 border-primary rounded-b-lg transition-colors " <> if(branched?, do: "", else: "rounded-tr-lg")}>
                <.section_entry_row :for={entry <- members} entry={entry} section={@section} from={active_from(@entry_tabs, entry)} timeline={active_timeline(@entry_tabs, entry)} branch={active_branch(@entry_tabs, entry)} in_group={true}
                                      gifts_by_name={@gifts_by_name} gifts_by_id={@gifts_by_id} />
              </div>
            </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  def entry_chunks(entries) do
    entries
    |> Enum.chunk_by(&if(GiftPlans.scheduled?(&1), do: {:group, GiftPlans.group_key(&1)}, else: {:single, &1["id"]}))
    |> Enum.map(fn [first | _] = run -> if GiftPlans.scheduled?(first), do: {:group, GiftPlans.group_key(first), run}, else: {:single, first} end)
  end

  attr :entry, :map, required: true
  attr :section, :map, required: true
  attr :from, :integer, required: true
  attr :in_group, :boolean, required: true
  attr :readonly, :boolean, default: false
  attr :shadowed, :boolean, default: false
  attr :timeline, :string, default: nil
  attr :branch, :string, default: nil
  attr :gifts_by_name, :map, required: true
  attr :gifts_by_id, :map, required: true

  def section_entry_row(assigns) do
    entry = GiftPlans.timeline_view(assigns.entry, assigns.timeline)
    segment = entry["floors"] |> Enum.find(&(&1["from"] == assigns.from)) |> GiftPlans.branch_view(assigns.branch)
    pattern? = GiftPlans.pattern_entry?(entry)
    action? = GiftPlans.action_entry?(entry)
    gift = assigns.gifts_by_name[GiftPlans.subject_gift(entry)]
    abandoned? = GiftPlans.abandoned?(entry, segment)
    heal? = action? and entry["subject"]["action"] != "skill_replace"
    sell? = not abandoned? and segment["disposition"] == "sell"
    keep? = not abandoned? and not sell? and not pattern?
    buy? = not abandoned? and not sell? and segment["buy"] == true
    made_from = keep? and segment["fuse"] == true and GiftPlans.fixed_fusion?(entry) and gift && recipe_parts(assigns.section, gift, assigns.gifts_by_id)

    assigns =
      assign(assigns,
        segment: segment,
        pattern?: pattern?,
        action?: action?,
        skill?: action? and entry["subject"]["action"] == "skill_replace",
        gift: gift,
        keep?: keep?,
        sell?: sell?,
        buy?: buy?,
        abandoned?: abandoned?,
        heal?: heal?,
        made_from: made_from || nil,
        goal_slot?: keep? or (action? and entry["subject"]["action"] == "skill_replace") or (abandoned? and not pattern?) or (pattern? and not action? and GiftPlans.scheduled?(assigns.entry)) or (heal? and GiftPlans.scheduled?(assigns.entry)),
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
    <form data-sort-id={not @readonly && @entry["id"]} data-sort-handle={not @readonly} phx-change={not @readonly && "list_update_segment"}
          class={"border px-1 py-1 flex items-center gap-2 flex-wrap " <> @surface <> " rounded" <> if(@readonly, do: " pointer-events-none", else: "") <> if(@shadowed, do: " opacity-60", else: "")}
          style={
            cond do
              @abandoned? or @shadowed -> StarlightBotWeb.Live.PackPlanEditorLive.disabled_stripes_style()
              @keep? and @segment["goal"] == "optional" -> "background-image: radial-gradient(color-mix(in oklab, var(--color-base-content) 16%, transparent) 0.9px, transparent 1.2px), radial-gradient(color-mix(in oklab, var(--color-base-content) 16%, transparent) 0.9px, transparent 1.2px); background-size: 8px 8px; background-position: -2px -2px, 2px 2px; background-clip: padding-box"
              true -> nil
            end
          }>
      <input type="hidden" name="entry" value={@entry["id"]} />
      <input type="hidden" name="from" value={@from} />
      <span :if={not @readonly} data-sort-handle class="cursor-grab text-base-content/40 select-none px-1">⠿</span>
      <div class="w-24 shrink-0">
        <span :if={@shadowed} class="badge badge-warning badge-sm whitespace-nowrap"
              title={if @pattern?, do: "This stage has the same entry, so the starter pack's version has no effect on the plan.", else: "This stage lists this gift itself, so the starter pack's version has no effect on the plan."}>Overridden</span>
        <span :if={@readonly and not @shadowed and @goal_slot?}
              class={"badge badge-sm border whitespace-nowrap " <> if(@abandoned? or @heal? or (@segment["goal"] || "required") == "optional", do: "", else: goal_select_color(@segment["goal"] || "required"))}>
          <%= goal_label(cond do
            @abandoned? -> "abandon"
            @heal? -> "use"
            true -> @segment["goal"] || "required"
          end) %>
        </span>
        <select :if={not @readonly and @goal_slot?} name="segment[goal]"
                title={goal_hint(cond do
                  @abandoned? -> "abandon"
                  @heal? -> "use"
                  true -> @segment["goal"] || "required"
                end, @section)}
                class={"select select-bordered select-xs w-full " <> if(@abandoned? or @heal?, do: "", else: goal_select_color(@segment["goal"] || "required"))}>
          <option :for={goal <- cond do
                    @heal? -> ["use", "abandon"]
                    @pattern? -> ["required", "abandon"]
                    true -> ["required", "optional" | GiftPlans.goal_letters(@section)] ++ ["abandon"]
                  end} value={goal}
                  selected={if @abandoned?, do: goal == "abandon", else: if(@heal?, do: goal == "use", else: (@segment["goal"] || "required") == goal)}><%= goal_label(goal) %></option>
        </select>
      </div>
      <div class="flex items-center gap-1.5 w-52 min-w-0 shrink-0">
        <div :if={@gift} class="relative w-6 h-6 shrink-0">
          <img src={@gift.image_path} data-gift-popup={@gift.name} data-gift-uptie={@keep? && @segment["uptie"]} class="w-6 h-6 rounded object-cover cursor-pointer pointer-events-auto" />
          <span :if={@gift.tier} class="absolute top-0 left-0 px-0.5 text-[9px] leading-tight font-bold bg-base-100/80 rounded-br pointer-events-none"><%= gift_tier_roman(@gift.tier) %></span>
          <img :if={@gift.affinity not in [nil, "none"]} src={gift_affinity_icon(@gift.affinity)} title={@gift.affinity} draggable="false"
               class="absolute bottom-0 right-0 w-3 h-3 object-contain drop-shadow pointer-events-none" />
        </div>
        <span :if={@pattern? and not @action?} class="badge badge-secondary badge-xs">any</span>
        <span :if={@action?} class={"badge badge-xs " <> if(@entry["subject"]["action"] == "skill_replace", do: "badge-info text-black", else: "badge-success")}>
          <%= case @entry["subject"]["action"] do
            "skill_replace" -> "skill"
            "team_replace" -> "team"
            _ -> "heal"
          end %>
        </span>
        <span data-sort-handle data-gift-popup={@gift && @gift.name} data-gift-uptie={@keep? && @segment["uptie"]} class={"text-xs font-medium truncate select-none " <> if(@gift, do: "cursor-pointer pointer-events-auto", else: "cursor-grab")} title={GiftPlans.subject_label(@entry["subject"])}><%= GiftPlans.subject_label(@entry["subject"]) %></span>
        <span :if={@action? and not @abandoned?} class="ml-auto pr-1 text-[11px] text-base-content/60 whitespace-nowrap">
          Cost <%= case GiftPlans.action_cost_range(@entry["subject"]["action"], @segment) do
            {same, same} -> same
            {low, high} -> "#{low}-#{high}"
          end %>
        </span>
      </div>
      <%= cond do %>
      <% @abandoned? -> %>
        <span :if={@action?} class="text-[11px] font-semibold text-base-content/60"><%= if @from == 1, do: "Not started", else: "Abandoned" %></span>
        <span :if={@pattern? and not @action?} class="text-[11px] font-semibold text-base-content/60">
          <%= if @from == 1, do: "Not a goal", else: "No longer a goal" %>
        </span>
        <span :if={not @pattern? and not @action?} class="text-[11px] font-semibold text-base-content/60 cursor-help"
              title="Never bought here, even if a broader entry (such as a whole affinity) would buy it">
          <%= if @from == 1, do: "Buys refused", else: "Buys refused from here" %>
        </span>
      <% @action? -> %>
        <div :if={@entry["subject"]["action"] in ["heal", "revive", "skill_replace"]} class="grid grid-cols-6 gap-0.5">
          <button :for={sinner <- Teams.all_sinners()} type="button" phx-click="list_toggle_heal_sinner"
                  phx-value-entry={@entry["id"]} phx-value-from={@from} phx-value-sinner={sinner}
                  title={sinner_label(sinner)}
                  class={"btn btn-xs h-5 min-h-0 px-0.5 min-w-0 flex-nowrap gap-0.5 text-[10px] " <> if(sinner in (@segment["sinners"] || []), do: if(@entry["subject"]["action"] == "skill_replace", do: "btn-info text-black", else: "btn-success"), else: "btn-outline")}>
            <img src={StarlightBot.SinnerProfiles.icon(sinner)} class="sinner-icon h-3.5 w-3.5 shrink-0 object-contain" /><span class="truncate"><%= sinner_label(sinner) %></span>
          </button>
        </div>
        <div :if={@entry["subject"]["action"] == "team_replace"} class="flex flex-col gap-1">
          <% replacements = @segment["replacements"] || [] %>
          <% picked = Enum.map(replacements, & &1["sinner"]) %>
          <% full? = length(replacements) >= GiftPlans.team_replace_max() %>
          <div class="grid grid-cols-6 gap-0.5">
            <button :for={sinner <- Teams.all_sinners()} type="button" phx-click="list_toggle_team_replace"
                    phx-value-entry={@entry["id"]} phx-value-from={@from} phx-value-sinner={sinner}
                    disabled={full? and sinner not in picked}
                    title={if full? and sinner not in picked, do: "A shop replaces at most #{GiftPlans.team_replace_max()} sinners", else: sinner_label(sinner)}
                    class={"btn btn-xs h-5 min-h-0 px-0.5 min-w-0 flex-nowrap gap-0.5 text-[10px] " <> if(sinner in picked, do: "btn-success", else: "btn-outline")}>
              <img src={StarlightBot.SinnerProfiles.icon(sinner)} class="sinner-icon h-3.5 w-3.5 shrink-0 object-contain" /><span class="truncate"><%= sinner_label(sinner) %></span>
            </button>
          </div>
          <% profiles = team_replace_profiles() %>
          <label :for={replacement <- replacements} class="flex items-center gap-1 text-[11px]">
            <img src={StarlightBot.SinnerProfiles.icon(replacement["sinner"])} class="sinner-icon h-3.5 w-3.5 shrink-0 object-contain" />
            <span class="w-16 truncate"><%= sinner_label(replacement["sinner"]) %></span>
            <select name={"segment[team_profile][#{replacement["sinner"]}]"} class="select select-bordered select-xs min-w-0 flex-1">
              <option value="">Pick an identity</option>
              <option :for={profile <- Map.get(profiles, replacement["sinner"], [])} value={profile.id} selected={replacement["profile"] == profile.id}><%= profile.name %></option>
            </select>
          </label>
        </div>
        <div :if={@skill?} class="flex items-center gap-2 text-[11px]">
          <% locked? = @segment["lock_s2"] != false %>
          <% target = GiftPlans.skill_target(@segment["target"], locked?) %>
          <span :for={key <- ~w(s1 s2 s3)} class="flex items-center gap-0.5">
            <%= String.upcase(key) %>
            <span :if={key == "s3"} class="w-4 text-center font-semibold"><%= target[key] %></span>
            <span :if={key != "s3"} class="join">
              <button type="button" phx-click="list_step_skill_target" phx-value-entry={@entry["id"]} phx-value-from={@from} phx-value-key={key} phx-value-delta="-1"
                      disabled={target[key] <= GiftPlans.skill_min(locked?, key)} class="btn btn-xs join-item h-5 min-h-0 px-1">-</button>
              <span class="join-item flex w-4 items-center justify-center border border-base-300 font-semibold"><%= target[key] %></span>
              <button type="button" phx-click="list_step_skill_target" phx-value-entry={@entry["id"]} phx-value-from={@from} phx-value-key={key} phx-value-delta="1"
                      disabled={target[key] >= GiftPlans.skill_max(target, key)} class="btn btn-xs join-item h-5 min-h-0 px-1">+</button>
            </span>
            <button :if={key == "s2"} type="button" phx-click="list_toggle_skill_lock" phx-value-entry={@entry["id"]} phx-value-from={@from}
                    title={"Don't let S2 drop or go past #{target["s2"]}"}
                    class={"btn btn-xs h-5 min-h-0 px-1 " <> if(@segment["lock_s2"] != false, do: "btn-info text-black", else: "btn-ghost")}>
              <.icon name={if @segment["lock_s2"] != false, do: "lucide-lock", else: "lucide-lock-open"} class="size-3.5" />
            </button>
          </span>
        </div>
        <button :if={@entry["subject"]["action"] == "revive"} type="button" phx-click="list_toggle_heal_after" phx-value-entry={@entry["id"]} phx-value-from={@from}
                title="After reviving a dead sinner, greatly heal them too"
                class={"btn btn-xs " <> if(@segment["heal_after"] != false, do: "btn-success", else: "btn-outline")}>Heal after</button>
        <div :if={action_repeats(@entry["subject"]["action"]) != []} class="join">
          <button :for={{repeat, label} <- action_repeats(@entry["subject"]["action"])} type="button" phx-click="list_set_heal_repeat"
                  phx-value-entry={@entry["id"]} phx-value-from={@from} phx-value-repeat={repeat}
                  class={"btn btn-xs join-item " <> if((@segment["repeat"] || "once") == repeat, do: "btn-success", else: "btn-outline")}><%= label %></button>
        </div>
      <% true -> %>
        <div class="min-w-16 shrink-0">
          <div :if={not @pattern? and @uptie?} class="join">
            <% current = @segment["uptie"] || 0 %>
            <button :for={{level, icon} <- Enum.zip(1..GiftPlans.max_uptie(), ~w(+ ++))} type="button" phx-click="list_set_uptie"
                    phx-value-entry={@entry["id"]} phx-value-from={@from} phx-value-level={if current == level, do: 0, else: level}
                    disabled={not @keep? or not uptie_level_available?(@gift, level)} title={uptie_title(@gift, level)}
                    class={"btn btn-xs join-item " <> if(@keep? and level <= current, do: "btn-secondary", else: "btn-outline")}>
              <%= icon %>
            </button>
          </div>
        </div>
        <div class="join">
          <button type="button" phx-click="list_toggle" phx-value-entry={@entry["id"]} phx-value-from={@from} phx-value-field="buy"
                  class={"btn btn-xs join-item " <> if(@buy?, do: "btn-secondary", else: "btn-outline")}>Buy</button>
          <button type="button" phx-click="list_toggle" phx-value-entry={@entry["id"]} phx-value-from={@from} phx-value-field="sell"
                  class={"btn btn-xs join-item " <> if(@sell?, do: "btn-error", else: "btn-outline")}>Sell</button>
        </div>
        <% shown_cost = cond do
          @sell? and @gift -> @gift.selling_cost
          @buy? and @gift && @gift.buying_cost -> @gift.buying_cost + (GiftPlans.uptie_cost(@gift.tier, 0, @segment["uptie"] || 0) || 0)
          @keep? and @gift && (@segment["uptie"] || 0) > 0 -> GiftPlans.uptie_cost(@gift.tier, 0, @segment["uptie"])
          true -> nil
        end %>
        <span class="w-12 shrink-0 flex items-center gap-0.5 text-[11px] text-base-content/60 whitespace-nowrap">
          <%= if shown_cost do %><%= shown_cost %><img src={~p"/images/icons/md_cost.png"} alt="" class="h-3.5 w-3.5 object-contain" /><% end %>
        </span>
        <div class="min-w-20 shrink-0">
          <div :if={not @pattern?} class="join">
            <button type="button" phx-click="list_toggle" phx-value-entry={@entry["id"]} phx-value-from={@from} phx-value-field="fuse"
                    disabled={not @keep? or not @fusable?}
                    title={if not @fusable?, do: "This gift can't be fused"}
                    class={"btn btn-xs join-item " <> if(@keep? and @segment["fuse"] == true and @entry["fusion"], do: "btn-secondary", else: "btn-outline")}>
              Fuse
            </button>
            <button :if={@entry["fusion"] != nil and @keep? and @segment["fuse"] == true} type="button" phx-click="list_open_fusion" phx-value-entry={@entry["id"]}
                    class="btn btn-xs btn-outline join-item" title="Fusion settings"><.icon name="lucide-settings" class="size-4" /></button>
          </div>
        </div>
        <label :if={@sell? or (@pattern? and @buy?)} class="flex items-center gap-1">
          <span class="text-[11px] text-base-content/60">Max per floor</span>
          <input type="number" min="1" name="segment[max]" value={@segment["max"]} placeholder="no cap" phx-debounce="400" class="input input-bordered input-xs w-20" />
        </label>
      <% end %>
      <span :if={@made_from} title={"Made from: " <> Enum.map_join(@made_from, ", ", &elem(&1, 0))}
            class="flex items-center gap-1 h-5 text-[11px] text-base-content/60 min-w-0 max-w-64 overflow-hidden">
        <%= for {{name, present?}, index} <- Enum.with_index(@made_from) do %>
          <span :if={index > 0} class="shrink-0">+</span>
          <% ingredient = @gifts_by_name[name] %>
          <img :if={ingredient} src={ingredient.image_path} class={"w-5 h-5 rounded object-cover shrink-0 " <> if(present?, do: "", else: "ring-2 ring-error")} />
          <span :if={!ingredient} class={"whitespace-nowrap " <> if(present?, do: "", else: "text-error font-semibold")}><%= name %></span>
        <% end %>
      </span>
      <span :if={not @readonly} class="hidden in-[.ring-primary]:flex items-center shrink-0 ml-auto">
        <button type="button" data-copy-entry title="Copy this entry or every selected entry (Ctrl+C)" class="btn btn-ghost btn-xs px-0.5 min-h-0 h-5 opacity-60 hover:opacity-100">
          <.icon name="lucide-copy" class="size-3.5 pointer-events-none" />
        </button>
        <button type="button" data-paste-entries={@entry["id"]} title="Paste copied entries below this one (Ctrl+V pastes below the last selected entry)" class="btn btn-ghost btn-xs px-0.5 min-h-0 h-5 opacity-60 hover:opacity-100">
          <.icon name="lucide-clipboard-paste" class="size-3.5 pointer-events-none" />
        </button>
      </span>
      <span :if={@readonly and GiftPlans.scheduled?(@entry)} class="badge badge-outline badge-xs ml-auto whitespace-nowrap"><%= pack_row_label(@entry, @timeline, @from) %></span>
      <button :if={not @in_group and not @readonly} type="button" phx-click="list_add_schedule" phx-value-entry={@entry["id"]} class="btn btn-ghost btn-xs ml-auto in-[.ring-primary]:ml-0">Add Schedule</button>
      <button :if={not @readonly} type="button" data-remove-entry phx-click="list_remove_entry" phx-value-entry={@entry["id"]}
              class={"btn btn-ghost btn-xs px-1 text-error " <> if(@in_group, do: "ml-auto in-[.ring-primary]:ml-0", else: "")} title="Remove from this stage (every selected entry if this one is selected, or press Delete)"><.icon name="lucide-x" class="size-3.5" /></button>
    </form>
    """
  end

  attr :gift, :map, required: true
  attr :section, :map, required: true
  attr :gifts_by_id, :map, required: true
  attr :gifts_by_name, :map, required: true

  def recipe_tree(assigns) do
    ~H"""
    <ul class="pl-4 flex flex-col gap-0.5 list-disc">
      <li :for={{name, present?} <- recipe_parts(@section, @gift, @gifts_by_id)} class="text-[11px]">
        <span class={if present?, do: "", else: "text-error font-semibold"}><%= name %></span>
        <span :if={not present?} class="text-error">(not in this stage)</span>
        <% ingredient = @gifts_by_name[name] %>
        <.recipe_tree :if={ingredient && GiftPlans.fixed_recipe?(ingredient)} gift={ingredient} section={@section} gifts_by_id={@gifts_by_id} gifts_by_name={@gifts_by_name} />
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
                    class="btn btn-ghost btn-2xs text-error"><.icon name="lucide-x" class="size-3.5" /></button>
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
end
