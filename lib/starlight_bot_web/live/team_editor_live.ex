defmodule StarlightBotWeb.Live.TeamEditorLive do
  use StarlightBotWeb, :live_view

  alias StarlightBot.{BattlePlans, EgoGifts, GiftPlans, Hooks, PlanCounts, Plans, SinnerProfiles, StarlightBudget, Teams, ThemePacks}
  alias StarlightBotWeb.Live.{BattlePlanEditorLive, GiftPlanEditorLive, PackPlanEditorLive}
  alias StarlightBot.Navigation.Navigator
  import StarlightBotWeb.Components.PlanPicker, only: [pane_icon: 1, pane_tabs: 1]

  @panes %{"packs" => PackPlanEditorLive, "gifts" => GiftPlanEditorLive, "battle" => BattlePlanEditorLive}

  attr :groups, :list, required: true
  attr :used, :list, required: true
  attr :event, :string, required: true
  attr :index, :integer, default: nil
  attr :label, :string, required: true
  attr :icon, :string, default: nil
  attr :class, :string, default: ""

  def hook_picker(assigns) do
    ~H"""
    <div id={"hook-picker-#{@event}-#{@index}"} phx-hook="HookPicker" class="dropdown w-full">
      <div tabindex="0" role="button" class={"btn btn-sm w-full justify-start font-normal " <> @class}><img :if={@icon} src={@icon} class="size-4 object-contain" /><%= @label %></div>
      <div tabindex="0" class="dropdown-content z-30 mt-1 w-[32rem] rounded-lg border border-base-300 bg-base-100 p-2 shadow-lg">
        <div class="columns-3 gap-3">
          <%= for {group, hooks} <- @groups, hooks = Enum.reject(hooks, &(&1 in @used)), hooks != [] do %>
            <div class="break-inside-avoid mb-2">
              <div class="px-1 pb-0.5 text-[10px] font-semibold uppercase tracking-wide text-base-content/50"><%= group %></div>
              <button :for={h <- hooks} type="button" phx-click={@event} phx-value-hook={h} phx-value-index={@index}
                      onclick="document.activeElement.blur()"
                      class="btn btn-ghost btn-xs w-full justify-start font-mono">
                <img :if={Teams.hook_icon(h)} src={Teams.hook_icon(h)} class="size-4 object-contain" /><%= Teams.hook_label(h) %>
              </button>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Navigator.subscribe()
    if connected?(socket), do: PlanCounts.subscribe()
    nav = Navigator.status()

    {:ok,
     socket
     |> assign(:teams, Teams.list_teams())
     |> assign_profiles()
     |> assign(:gift_plans, Plans.list(:gift_plans))
     |> assign(:gifts_by_name, Map.new(EgoGifts.list_gifts(), &{&1.name, &1}))
     |> assign(:pack_plans, Plans.list(:pack_plans))
     |> assign(:team_hooks, Teams.team_hooks())
     |> assign(:theme_packs, ThemePacks.list_theme_packs())
     |> assign(:form, blank_form())
     |> assign(:editing_id, nil)
     |> assign(:tab_counts, %{})
     |> assign(:hooks, [])
     |> assign(:expanded?, false)
     |> assign(:editing_hooks?, false)
     |> assign(:selected_ids, blank_selected_ids())
     |> assign(:budget_inputs, blank_budget_inputs(nil))
     |> assign(:phase, nav.phase)
     |> assign(:run_kind, nav.run_kind)
     |> assign(:pane, "battle")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    team_id = parse_id(params["team"])

    socket =
      socket
      |> assign_profiles()
      |> assign(:pane, if(Map.has_key?(@panes, params["pane"]) or params["pane"] in ["profiles", "stats"], do: params["pane"], else: socket.assigns.pane))

    cond do
      team_id && team_id != socket.assigns.editing_id -> {:noreply, socket |> load_team(team_id) |> assign(:expanded?, true)}
      is_nil(team_id) -> {:noreply, reset_editor(socket)}
      true -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("restore_nav", params, socket) do
    team_ids = Enum.map(socket.assigns.teams, & &1.id)
    stored_id = parse_id(params["team"])
    pane = if Map.has_key?(@panes, params["pane"]), do: params["pane"], else: socket.assigns.pane

    case if(stored_id in team_ids, do: stored_id, else: List.first(team_ids)) do
      nil -> {:noreply, socket}
      id -> {:noreply, push_patch(socket, to: ~p"/teams?team=#{id}&pane=#{pane}")}
    end
  end

  @impl true
  def handle_event("prepare_lineups", _, socket) do
    Navigator.prepare_lineups()
    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_run", _, socket) do
    Navigator.cancel()
    {:noreply, socket}
  end

  @impl true
  def handle_event("new_team", _, socket) do
    case Teams.create_default_team() do
      {:ok, id} ->
        {:noreply,
         socket
         |> assign(:teams, Teams.list_teams())
         |> push_patch(to: ~p"/teams?team=#{id}&pane=#{plan_pane(socket.assigns.pane)}")
         |> put_flash(:info, "Team created.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("duplicate_team", %{"id" => id}, socket) do
    case Teams.duplicate_team(String.to_integer(id)) do
      {:ok, new_id} ->
        {:noreply,
         socket
         |> assign(:teams, Teams.list_teams())
         |> push_patch(to: ~p"/teams?team=#{new_id}&pane=#{plan_pane(socket.assigns.pane)}")
         |> put_flash(:info, "Team duplicated.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Duplicate failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("click_team", %{"id" => id}, socket) do
    case String.to_integer(id) do
      id when id == socket.assigns.editing_id -> {:noreply, update(socket, :expanded?, &(not &1))}
      id -> {:noreply, push_patch(socket, to: ~p"/teams?team=#{id}&pane=#{plan_pane(socket.assigns.pane)}")}
    end
  end

  @impl true
  def handle_event("validate_team", %{"team" => params}, socket) do
    socket = assign(socket, :form, build_form(params))
    name = String.trim(params["name"] || "")

    if name == "" do
      {:noreply, socket}
    else
      case Teams.save_team(team_attrs(socket, name)) do
        {:ok, _id} -> {:noreply, assign(socket, :teams, Teams.list_teams())}
        {:error, reason} -> {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
      end
    end
  end

  @impl true
  def handle_event("toggle_edit_hooks", _params, socket) do
    {:noreply, update(socket, :editing_hooks?, &(not &1))}
  end

  @impl true
  def handle_event("close_edit_hooks", _params, socket) do
    {:noreply, assign(socket, :editing_hooks?, false)}
  end

  @impl true
  def handle_event("toggle_team_hook", %{"hook" => hook}, socket) do
    hooks = socket.assigns.hooks
    hooks = if hook in hooks, do: List.delete(hooks, hook), else: hooks ++ [hook]
    {:noreply, socket |> assign(:hooks, hooks) |> persist_team()}
  end

  @impl true
  def handle_event("replace_team_hook", %{"index" => index, "hook" => hook}, socket) do
    index = String.to_integer(index)

    if hook == "" or hook in socket.assigns.hooks do
      {:noreply, socket}
    else
      {:noreply, socket |> assign(:hooks, List.replace_at(socket.assigns.hooks, index, hook)) |> persist_team()}
    end
  end

  @impl true
  def handle_event("remove_team_hook",%{"index" => index}, socket) do
    {:noreply, socket |> assign(:hooks, List.delete_at(socket.assigns.hooks, String.to_integer(index))) |> persist_team()}
  end

  @impl true
  def handle_event("reorder_team_hooks", %{"ids" => ids}, socket) do
    hooks = socket.assigns.hooks
    order = Enum.map(ids, &String.to_integer/1)

    if Enum.sort(order) == Enum.to_list(0..(length(hooks) - 1)//1) do
      {:noreply, socket |> assign(:hooks, Enum.map(order, &Enum.at(hooks, &1))) |> persist_team()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("reorder_teams", %{"ids" => ids}, socket) do
    Teams.reorder_teams(Enum.map(ids, &String.to_integer/1))
    {:noreply, assign(socket, :teams, Teams.list_teams())}
  end

  @impl true
  def handle_event("delete_team", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Teams.delete_team(id) do
      {:ok, _} ->
        socket = if socket.assigns.editing_id == id, do: push_patch(socket, to: ~p"/teams"), else: socket

        {:noreply,
         socket
         |> assign(:teams, Teams.list_teams())
         |> put_flash(:info, "Team deleted.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("budget_change", params, socket) do
    inputs = %{
      pack_searches: parse_id(params["pack_searches"]),
      sinner_bonus: parse_id(params["sinner_bonus"]) || 0,
      railway_packs: parse_id(params["railway_packs"]),
      reward_cards: parse_id(params["reward_cards"]) || 0
    }

    {:noreply, assign(socket, :budget_inputs, inputs)}
  end

  @impl true
  def handle_info(:team_plans_changed, socket) do
    socket =
      socket
      |> assign(:teams, Teams.list_teams())
      |> assign(:gift_plans, Plans.list(:gift_plans))
      |> assign(:pack_plans, Plans.list(:pack_plans))

    case socket.assigns.editing_id && Teams.get_team(socket.assigns.editing_id) do
      nil -> {:noreply, socket}
      team -> {:noreply, assign(socket, :selected_ids, selected_ids(team))}
    end
  end

  @impl true
  def handle_info({:plan_count, team_id, table, count}, %{assigns: %{editing_id: team_id}} = socket), do: {:noreply, update(socket, :tab_counts, &Map.put(&1, table, count))}

  @impl true
  def handle_info({:plan_count, _team_id, _table, _count}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:nav_state, nav}, socket) do
    {:noreply, socket |> assign(:phase, nav.phase) |> assign(:run_kind, nav.run_kind)}
  end

  # --- Private ---

  def running_label(:luxcavation), do: "Luxcavation is running"
  def running_label(:mirror_dungeon), do: "Mirror Dungeon is running"
  def running_label(:enkephalin), do: "Enkephalin charge is running"
  def running_label(_), do: "Another run is in progress"

  def log_kind_class(:ok), do: "text-success"
  def log_kind_class(:error), do: "text-error"
  def log_kind_class(:info), do: "text-base-content/60"
  def log_kind_class(_), do: "text-base-content/40"

  defp team_attrs(socket, name) do
    sel = socket.assigns.selected_ids

    %{
      id: socket.assigns.editing_id,
      name: name,
      hooks: socket.assigns.hooks,
      gift_plan_id: sel["gift_plan"],
      battle_plan_id: sel["battle_plan"],
      pack_plan_id: sel["pack_plan"]
    }
  end

  defp persist_team(%{assigns: %{editing_id: nil}} = socket), do: socket

  defp persist_team(socket) do
    attrs = team_attrs(socket, socket.assigns.form[:name].value)

    case Teams.save_team(attrs) do
      {:ok, _id} -> assign(socket, :teams, Teams.list_teams())
      {:error, reason} -> put_flash(socket, :error, "Save failed: #{inspect(reason)}")
    end
  end

  defp load_team(socket, id) do
    case Teams.get_team(id) do
      nil ->
        put_flash(socket, :error, "Team not found.")

      team ->
        socket
        |> assign(:form, build_form(%{"name" => team.name}))
        |> assign(:editing_id, team.id)
        |> assign(:tab_counts, PlanCounts.for_team(team.id))
        |> assign(:hooks, team.hooks)
        |> assign(:editing_hooks?, false)
        |> assign(:selected_ids, selected_ids(team))
        |> assign(:budget_inputs, blank_budget_inputs(team.battle_plan_id))
    end
  end

  defp selected_ids(team) do
    %{
      "gift_plan" => team.gift_plan_id,
      "battle_plan" => team.battle_plan_id,
      "pack_plan" => team.pack_plan_id
    }
  end

  def pane_view(pane), do: Map.fetch!(@panes, pane)

  defp plan_pane("profiles"), do: "battle"
  defp plan_pane(pane), do: pane

  defp assign_profiles(socket) do
    socket
    |> assign(:profiles_by_id, Map.new(SinnerProfiles.list(), &{&1.id, &1}))
    |> assign(:locator_thumbs, Hooks.hook_thumbnails("locator"))
  end

  def profile_icons(profile_ids, profiles_by_id, locator_thumbs) do
    for id <- profile_ids, profile = profiles_by_id[id] do
      src =
        case profile do
          %{locator_hook: hook} when is_binary(hook) ->
            case locator_thumbs do
              %{^hook => version} -> ~p"/hooks/#{hook}/thumb.png?#{[v: version]}"
              _ -> SinnerProfiles.icon(profile.sinner)
            end

          _ ->
            SinnerProfiles.icon(profile.sinner)
        end

      %{name: profile.name, src: src}
    end
  end

  def profiles_toggle_path(nil, "profiles"), do: ~p"/teams?pane=battle"
  def profiles_toggle_path(nil, _pane), do: ~p"/teams?pane=profiles"
  def profiles_toggle_path(team_id, "profiles"), do: ~p"/teams?team=#{team_id}&pane=battle"
  def profiles_toggle_path(team_id, _pane), do: ~p"/teams?team=#{team_id}&pane=profiles"

  defp reset_editor(socket) do
    socket
    |> assign(:form, blank_form())
    |> assign(:editing_id, nil)
    |> assign(:hooks, [])
    |> assign(:expanded?, false)
    |> assign(:editing_hooks?, false)
    |> assign(:selected_ids, blank_selected_ids())
  end

  defp blank_selected_ids do
    %{"gift_plan" => nil, "battle_plan" => nil, "pack_plan" => nil}
  end

  defp blank_budget_inputs(battle_plan_id) do
    %{pack_searches: 1, sinner_bonus: StarlightBudget.default_sinner_bonus(first_lineup_size(battle_plan_id)), railway_packs: nil, reward_cards: 0}
  end

  defp first_lineup_size(nil), do: 0

  defp first_lineup_size(battle_plan_id) do
    case Plans.get(:battle_plans, battle_plan_id) do
      %{data: data} -> length((data |> BattlePlans.lineups() |> List.first() || %{})["sinners"] || [])
      nil -> 0
    end
  end

  def starlight_budget(gift_plans, pack_plans, theme_packs, selected_ids, inputs) do
    gift_data = plan_data_for(gift_plans, selected_ids["gift_plan"])
    plan_data = plan_data_for(pack_plans, selected_ids["pack_plan"])
    floors = StarlightBudget.floor_rewards(plan_data["mode_schedule"] || [])
    floor_total = floors |> Enum.map(& &1.starlight) |> Enum.sum()
    max_pack_searches = StarlightBudget.max_pack_searches(plan_data)
    pack_searches = min(inputs.pack_searches || max_pack_searches, max_pack_searches)
    max_railway_packs = length(StarlightBudget.railway_floors(plan_data, theme_packs, ~w(hunt fine)))
    planned_railway_packs = length(StarlightBudget.railway_floors(plan_data, theme_packs, ~w(hunt)))
    railway_packs = min(inputs.railway_packs || planned_railway_packs, max_railway_packs)
    gift_searches = length(gift_data["gift_search"] || [])

    income = %{
      base: StarlightBudget.base(),
      sinner_bonus: inputs.sinner_bonus,
      exploration: StarlightBudget.exploration_gain(floor_total, railway_packs, inputs.sinner_bonus),
      cards: StarlightBudget.cards_gain(inputs.reward_cards)
    }

    costs = %{
      grace: if(gift_data == %{}, do: 0, else: GiftPlanEditorLive.grace_total_cost(GiftPlans.normalize(gift_data))),
      gift_search: GiftPlans.gift_search_starlight_cost(gift_searches),
      pack_search: StarlightBudget.pack_search_cost(pack_searches)
    }

    %{
      income: income,
      costs: costs,
      floors: floors,
      floor_total: floor_total,
      railway_packs: railway_packs,
      max_railway_packs: max_railway_packs,
      rest_multiplier: StarlightBudget.rest_multiplier_milli(inputs.sinner_bonus) / 1000,
      reward_cards: inputs.reward_cards,
      gift_searches: gift_searches,
      gift_search_names: gift_data["gift_search"] || [],
      pack_searches: pack_searches,
      max_pack_searches: max_pack_searches,
      has_gift_plan?: gift_data != %{},
      has_pack_plan?: plan_data != %{},
      net: Enum.sum(Map.values(income)) - Enum.sum(Map.values(costs))
    }
  end

  defp plan_data_for(plans, id), do: Enum.find_value(plans, %{}, &(&1.id == id && &1.data)) || %{}

  def floor_breakdown(floors), do: Enum.map_join(floors, ", ", &"F#{&1.floor} #{&1.mode} #{&1.starlight}")

  defp blank_form, do: build_form(%{})

  defp build_form(params) do
    types = %{name: :string}

    changeset =
      {%{}, types}
      |> Ecto.Changeset.cast(params, Map.keys(types))
      |> Ecto.Changeset.validate_required([:name])

    to_form(changeset, as: :team)
  end

  defp parse_id(nil), do: nil
  defp parse_id(""), do: nil

  defp parse_id(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp missing_label(:hook), do: "team selector"
  defp missing_label(:gift_plan), do: "gift plan"
  defp missing_label(:battle_plan), do: "battle plan"
  defp missing_label(:lineup), do: "lineup (set it up in the battle plan)"
  defp missing_label(:pack_plan), do: "pack plan"
end
