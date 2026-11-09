defmodule StarlightBotWeb.Live.TeamEditorLive do
  use StarlightBotWeb, :live_view

  alias StarlightBot.{EgoGifts, Hooks, PlanCounts, Plans, SinnerProfiles, StarlightBudget, TeamBudget, TeamTemplates, Teams, ThemePacks}
  alias StarlightBot.PackPlans.Odds
  alias StarlightBotWeb.Live.{BattlePlanEditorLive, GiftPlanEditorLive, PackPlanEditorLive}
  alias StarlightBot.Navigation.Navigator
  import StarlightBotWeb.Components.PlanPicker, only: [pane_tabs: 1]

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
     |> attach_hook(:starlight_net, :after_render, &publish_net/1)
     |> assign(:teams, Teams.list_teams())
     |> assign(:team_templates, TeamTemplates.list())
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
     |> assign(:renaming_team_id, nil)
     |> assign(:editing_hooks?, false)
     |> assign(:selected_ids, blank_selected_ids())
     |> assign(:budget_inputs, blank_budget_inputs(nil))
     |> assign(:phase, nav.phase)
     |> assign(:run_kind, nav.run_kind)
     |> assign(:show_search_info, false)
     |> assign(:show_encounter_info, false)
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
      team_id && team_id != socket.assigns.editing_id -> {:noreply, load_team(socket, team_id)}
      is_nil(team_id) -> {:noreply, reset_editor(socket)}
      params["pane"] == "stats" -> {:noreply, refresh_budget_sources(socket)}
      true -> {:noreply, socket}
    end
  end

  defp refresh_budget_sources(socket) do
    socket =
      socket
      |> assign(:gift_plans, Plans.list(:gift_plans))
      |> assign(:pack_plans, Plans.list(:pack_plans))

    case Teams.get_team(socket.assigns.editing_id) do
      nil -> socket
      team -> socket |> assign(:selected_ids, TeamBudget.selected_ids(team)) |> assign(:budget_inputs, blank_budget_inputs(team))
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
  def handle_event("new_team", params, socket) do
    result =
      case params do
        %{"template" => template_id} -> Teams.create_team_from_template(String.to_integer(template_id))
        _ -> Teams.create_default_team()
      end

    case result do
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
  def handle_event("new_team_template", %{"id" => id}, socket) do
    case TeamTemplates.create_from_team(String.to_integer(id)) do
      {:ok, _} -> {:noreply, socket |> assign(:team_templates, TeamTemplates.list()) |> put_flash(:info, "Template created.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Create template failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("delete_team_template", %{"id" => id}, socket) do
    case TeamTemplates.delete(String.to_integer(id)) do
      {:ok, _} -> {:noreply, assign(socket, :team_templates, TeamTemplates.list())}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
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
  def handle_event("start_rename_team", %{"id" => id}, socket) do
    {:noreply, assign(socket, :renaming_team_id, String.to_integer(id))}
  end

  @impl true
  def handle_event("cancel_rename_team", _, socket) do
    {:noreply, assign(socket, :renaming_team_id, nil)}
  end

  @impl true
  def handle_event("rename_team", %{"value" => value}, socket) do
    id = socket.assigns.renaming_team_id
    name = String.trim(value)
    socket = assign(socket, :renaming_team_id, nil)
    team = Enum.find(socket.assigns.teams, &(&1.id == id))

    if is_nil(team) or name == "" or name == team.name do
      {:noreply, socket}
    else
      case Teams.save_team(%{team | name: name}) do
        {:ok, _id} ->
          socket = if id == socket.assigns.editing_id, do: assign(socket, :form, build_form(%{"name" => name})), else: socket
          {:noreply, assign(socket, :teams, Teams.list_teams())}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Rename failed: #{inspect(reason)}")}
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
  def handle_event("toggle_encounter_info", _, socket), do: {:noreply, update(socket, :show_encounter_info, &(!&1))}

  @impl true
  def handle_event("toggle_search_info", _, socket), do: {:noreply, update(socket, :show_search_info, &(!&1))}

  @impl true
  def handle_event("budget_change", params, socket) do
    team_id = socket.assigns.editing_id
    team = Teams.get_team(team_id)

    case params["_target"] do
      ["estimate"] ->
        estimate? = params["estimate"] == "on"
        free = if estimate?, do: StarlightBudget.default_free_sinners(TeamBudget.first_lineup_size(team)), else: socket.assigns.budget_inputs.free_sinners
        Teams.set_free_sinners(team_id, if(estimate?, do: nil, else: free))
        {:noreply, assign(socket, :budget_inputs, %{free_sinners: free, estimate?: estimate?})}

      _ ->
        free = min(parse_id(params["free_sinners"]) || 0, StarlightBudget.max_free_sinners())
        Teams.set_free_sinners(team_id, free)
        {:noreply, assign(socket, :budget_inputs, %{free_sinners: free, estimate?: false})}
    end
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
      team -> {:noreply, assign(socket, :selected_ids, TeamBudget.selected_ids(team))}
    end
  end

  @impl true
  def handle_info({:plan_count, team_id, table, count}, %{assigns: %{editing_id: team_id}} = socket) do
    socket = update(socket, :tab_counts, &Map.put(&1, table, count))
    {:noreply, if(table in [:gift_plans, :pack_plans], do: refresh_budget_sources(socket), else: socket)}
  end

  @impl true
  def handle_info({:plan_count, _team_id, _table, _count}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:nav_state, nav}, socket) do
    {:noreply, socket |> assign(:phase, nav.phase) |> assign(:run_kind, nav.run_kind)}
  end

  # --- Private ---

  def team_menu_away(editing_hooks?) do
    js = JS.hide(to: "#team-menu")
    if editing_hooks?, do: JS.push(js, "close_edit_hooks"), else: js
  end

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
        |> assign(:selected_ids, TeamBudget.selected_ids(team))
        |> assign(:budget_inputs, blank_budget_inputs(team))
    end
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
    |> assign(:editing_hooks?, false)
    |> assign(:selected_ids, blank_selected_ids())
  end

  defp blank_selected_ids do
    %{"gift_plan" => nil, "battle_plan" => nil, "pack_plan" => nil, "gift_override" => nil, "pack_override" => nil}
  end

  defp blank_budget_inputs(%{free_sinners: free_sinners}) when is_integer(free_sinners), do: %{free_sinners: free_sinners, estimate?: false}

  defp blank_budget_inputs(team) do
    %{free_sinners: TeamBudget.free_sinners(team), estimate?: true}
  end

  def starlight_budget(gift_plans, pack_plans, theme_packs, selected_ids, inputs) do
    TeamBudget.build(gift_plans, pack_plans, theme_packs, selected_ids, StarlightBudget.rest_bonus(inputs.free_sinners))
  end

  defp publish_net(%{assigns: %{editing_id: id}} = socket) when is_integer(id) do
    a = socket.assigns
    net = starlight_budget(a.gift_plans, a.pack_plans, a.theme_packs, a.selected_ids, a.budget_inputs).net

    if socket.private[:starlight_net] == {id, net} do
      socket
    else
      PlanCounts.broadcast(id, :starlight_net, net)
      put_private(socket, :starlight_net, {id, net})
    end
  end

  defp publish_net(socket), do: socket

  def search_breakdown(%{search_counts: counts}) do
    counts |> Enum.sort() |> Enum.map_join(", ", fn {count, prob} -> "#{count}: #{Odds.percent(prob)}" end)
  end

  def encounter_pct(prob), do: Odds.percent(prob)

  def encounter_decimal(value, decimals \\ 2), do: :erlang.float_to_binary(value * 1.0, decimals: decimals)

  def search_cost(count), do: StarlightBudget.pack_search_cost(count)

  def search_pct(prob), do: Odds.percent(prob)

  def railway_breakdown(by_floor), do: by_floor |> Enum.sort() |> Enum.map_join(", ", fn {floor, hits} -> "F#{floor} #{:erlang.float_to_binary(hits * 1.0, decimals: 2)}" end)

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
