defmodule StarlightBotWeb.Live.TeamEditorLive do
  use StarlightBotWeb, :live_view

  alias StarlightBot.{EgoGifts, Hooks, PlanCounts, Plans, RestCycle, SinnerProfiles, StarlightBudget, TeamBudget, Teams, ThemePacks}
  alias StarlightBotWeb.Components.TeamNav
  alias StarlightBot.PackPlans.Odds
  alias StarlightBotWeb.Live.{BattlePlanEditorLive, GiftPlanEditorLive, PackPlanEditorLive}

  @panes %{"packs" => PackPlanEditorLive, "gifts" => GiftPlanEditorLive, "battle" => BattlePlanEditorLive}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> attach_hook(:starlight_net, :after_render, &publish_net/1)
     |> assign(:gift_plans, Plans.list(:gift_plans))
     |> assign(:gifts_by_name, Map.new(EgoGifts.list_gifts(), &{&1.name, &1}))
     |> assign(:pack_plans, Plans.list(:pack_plans))
     |> assign(:theme_packs, ThemePacks.list_theme_packs())
     |> assign(:editing_id, nil)
     |> assign(:selected_ids, blank_selected_ids())
     |> assign(:budget_inputs, blank_budget_inputs(nil))
     |> assign(:info_pane, nil)
     |> assign(:gift_view, %{tab: nil, milestone: nil})
     |> assign(:pane, "battle")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    team_id = parse_id(params["team"])

    socket =
      socket
      |> assign(:pane, if(Map.has_key?(@panes, params["pane"]) or params["pane"] in ["profiles", "stats"], do: params["pane"], else: socket.assigns.pane))
      |> assign(:gift_view, %{tab: params["tab"], milestone: params["milestone"]})

    cond do
      team_id && team_id != socket.assigns.editing_id -> {:noreply, load_team(socket, team_id)}
      is_nil(team_id) -> {:noreply, restore_team(socket)}
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
      team -> socket |> assign(:selected_ids, TeamBudget.selected_ids(team)) |> assign(:budget_inputs, blank_budget_inputs(team, socket.assigns.budget_inputs.cycle_runs))
    end
  end

  @impl true
  def handle_event("show_info", %{"pane" => pane}, socket) when pane in ~w(encounter search rest exploration grace gift_search) do
    pane = String.to_existing_atom(pane)
    {:noreply, update(socket, :info_pane, &if(&1 == pane, do: nil, else: pane))}
  end

  @impl true
  def handle_event("budget_change", params, socket) do
    inputs = socket.assigns.budget_inputs

    runs = (parse_id(params["cycle_runs"]) || RestCycle.estimate_runs()) |> max(1) |> min(RestCycle.estimate_runs())
    {:noreply, assign(socket, :budget_inputs, %{inputs | cycle: RestCycle.estimate(inputs.assigned_ids, runs), cycle_runs: runs})}
  end

  @impl true
  def handle_info(:team_plans_changed, socket) do
    socket =
      socket
      |> assign(:gift_plans, Plans.list(:gift_plans))
      |> assign(:pack_plans, Plans.list(:pack_plans))

    case socket.assigns.editing_id && Teams.get_team(socket.assigns.editing_id) do
      nil -> {:noreply, socket}
      team -> {:noreply, assign(socket, :selected_ids, TeamBudget.selected_ids(team))}
    end
  end

  @impl true
  def handle_info({:plan_count, team_id, table, _count}, %{assigns: %{editing_id: team_id}} = socket) do
    {:noreply, if(table in [:gift_plans, :pack_plans], do: refresh_budget_sources(socket), else: socket)}
  end

  @impl true
  def handle_info({:plan_count, _team_id, _table, _count}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:gift_view, team_id, tab, milestone}, %{assigns: %{editing_id: team_id}} = socket) do
    view = %{tab: tab, milestone: milestone}

    if view == socket.assigns.gift_view do
      {:noreply, socket}
    else
      query = [team: team_id, pane: socket.assigns.pane] ++ for({key, value} <- [tab: tab, milestone: milestone], value, do: {key, value})
      {:noreply, socket |> assign(:gift_view, view) |> push_patch(to: ~p"/teams?#{query}", replace: true)}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Private ---

  def log_kind_class(:ok), do: "text-success"
  def log_kind_class(:error), do: "text-error"
  def log_kind_class(:info), do: "text-base-content/60"
  def log_kind_class(_), do: "text-base-content/40"

  defp load_team(socket, id) do
    case Teams.get_team(id) do
      nil ->
        put_flash(socket, :error, "Team not found.")

      team ->
        socket
        |> assign(:editing_id, team.id)
        |> assign(:selected_ids, TeamBudget.selected_ids(team))
        |> assign(:budget_inputs, blank_budget_inputs(team, socket.assigns.budget_inputs.cycle_runs))
    end
  end

  def pane_view(pane), do: Map.fetch!(@panes, pane)

  defp restore_team(socket) do
    case socket.assigns.team_nav.team_id do
      nil -> reset_editor(socket)
      id -> push_patch(socket, to: ~p"/teams?team=#{id}&pane=#{socket.assigns.pane}")
    end
  end

  defp reset_editor(socket) do
    socket
    |> assign(:editing_id, nil)
    |> assign(:selected_ids, blank_selected_ids())
  end

  defp blank_selected_ids do
    %{"gift_plan" => nil, "battle_plan" => nil, "pack_plan" => nil, "gift_override" => nil, "pack_override" => nil}
  end

  defp blank_budget_inputs(team, runs \\ RestCycle.estimate_runs()) do
    assigned = TeamBudget.assigned(team)

    %{
      free: StarlightBudget.max_free_sinners() - map_size(assigned),
      assigned: Map.keys(assigned),
      assigned_ids: assigned,
      cycle_runs: runs,
      cycle: RestCycle.estimate(assigned, runs),
      profile_icons: profile_icons(assigned)
    }
  end

  defp profile_icons(assigned) when map_size(assigned) == 0, do: %{}

  defp profile_icons(assigned) do
    profiles_by_id = Map.new(SinnerProfiles.list(), &{&1.id, &1})
    thumbs = Hooks.hook_thumbnails("locator")
    Map.new(assigned, fn {sinner, ids} -> {sinner, TeamNav.profile_icons(ids, profiles_by_id, thumbs)} end)
  end

  def rest_total(inputs), do: inputs.free * inputs.cycle.free_charge + round(inputs.cycle.average)

  def starlight_budget(gift_plans, pack_plans, theme_packs, selected_ids, inputs) do
    TeamBudget.build(gift_plans, pack_plans, theme_packs, selected_ids, rest_total(inputs))
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

  defp parse_id(nil), do: nil
  defp parse_id(""), do: nil

  defp parse_id(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end
end
