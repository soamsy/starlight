defmodule StarlightBotWeb.Live.ShopRunnerLive do
  use StarlightBotWeb, :live_view
  alias StarlightBot.Navigation.Navigator
  alias StarlightBot.Teams

  @countdown_secs 2

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Navigator.subscribe()

    nav = Navigator.status()
    teams = Teams.list_teams() |> Enum.reject(&is_nil(&1.gift_plan_id))

    {:ok,
     socket
     |> assign(:current_screen, nav.current_screen)
     |> assign(:phase, nav.phase)
     |> assign(:run_memory, nav.run_memory)
     |> assign(:teams, teams)
     |> assign(:team_id, default_team_id(teams))
     |> then(&assign(&1, :team_hook, resolve_team_hook(&1, nil)))
     |> assign(:floor, 1)
     |> assign(:pending_action, nil)
     |> assign(:countdown, nil)}
  end

  @impl true
  def handle_event("dry_run", _, socket) do
    case Enum.find(socket.assigns.teams, &(&1.id == socket.assigns.team_id)) do
      nil -> {:noreply, put_flash(socket, :error, "Pick a team first.")}
      team -> {:noreply, start_countdown(socket, {:run_shop_dry_run, %{id: team.id, hook: socket.assigns.team_hook}, team.name, socket.assigns.floor})}
    end
  end

  @impl true
  def handle_event("full_run", _, socket) do
    case Enum.find(socket.assigns.teams, &(&1.id == socket.assigns.team_id)) do
      nil -> {:noreply, put_flash(socket, :error, "Pick a team first.")}
      team -> {:noreply, start_countdown(socket, {:run_shop, %{id: team.id, hook: socket.assigns.team_hook}, team.name, socket.assigns.floor})}
    end
  end

  @impl true
  def handle_event("update_form", params, socket) do
    {:noreply, apply_form(socket, params)}
  end

  @impl true
  def handle_event("restore_form", params, socket) do
    {:noreply, apply_form(socket, params)}
  end

  @impl true
  def handle_event("cancel_pending", _, socket) do
    {:noreply, socket |> assign(:pending_action, nil) |> assign(:countdown, nil)}
  end

  @impl true
  def handle_event("cancel", _, socket) do
    Navigator.cancel()
    {:noreply, socket}
  end

  @impl true
  def handle_info(:countdown_tick, %{assigns: %{pending_action: nil}} = socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:countdown_tick, %{assigns: %{countdown: 1, pending_action: action}} = socket) do
    run_pending_action(action)
    {:noreply, socket |> assign(:pending_action, nil) |> assign(:countdown, nil)}
  end

  @impl true
  def handle_info(:countdown_tick, socket) do
    Process.send_after(self(), :countdown_tick, 1_000)
    {:noreply, assign(socket, :countdown, socket.assigns.countdown - 1)}
  end

  @impl true
  def handle_info({:nav_state, nav}, socket) do
    {:noreply,
     socket
     |> assign(:current_screen, nav.current_screen)
     |> assign(:phase, nav.phase)
     |> assign(:run_memory, nav.run_memory)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  def ego_gifts(run_memory), do: Map.get(run_memory, :ego_gifts, %{})

  def current_cost(run_memory), do: Map.get(run_memory, :cost, nil)

  def shop_plan(run_memory), do: Map.get(run_memory, :shop_plan, nil)

  defp default_team_id([]), do: nil
  defp default_team_id([%{id: id} | _]), do: id

  defp parse_team_id(str, fallback) do
    case Integer.parse(str) do
      {id, ""} -> id
      _ -> fallback
    end
  end

  defp apply_form(socket, params) do
    socket
    |> assign(:team_id, parse_team_id(params["team_id"] || "", socket.assigns.team_id))
    |> then(&assign(&1, :team_hook, resolve_team_hook(&1, params["team_hook"])))
    |> assign(:floor, parse_floor(params["floor"] || "", socket.assigns.floor))
  end

  defp parse_floor(str, fallback) do
    case Integer.parse(str) do
      {floor, ""} when floor >= 1 -> floor
      _ -> fallback
    end
  end

  defp resolve_team_hook(socket, hook) do
    case Enum.find(socket.assigns.teams, &(&1.id == socket.assigns.team_id)) do
      nil -> nil
      team -> Teams.pick_hook(team, hook)
    end
  end

  def team_hooks(teams, team_id), do: Enum.find_value(teams, [], &(&1.id == team_id && &1.hooks))

  defp start_countdown(socket, action) do
    Process.send_after(self(), :countdown_tick, 1_000)

    socket
    |> assign(:pending_action, action)
    |> assign(:countdown, @countdown_secs)
  end

  defp run_pending_action({:run_shop_dry_run, team, _team_name, floor}), do: Navigator.run_shop_dry_run(team, floor)
  defp run_pending_action({:run_shop, team, _team_name, floor}), do: Navigator.run_shop(team, floor)

  def pending_action_label({:run_shop_dry_run, _team_id, team_name, floor}), do: "shop dry run: #{team_name}, floor #{floor}"
  def pending_action_label({:run_shop, _team_id, team_name, floor}), do: "shop runner (full run): #{team_name}, floor #{floor}"

  def screen_label(nil), do: "Not localized"
  def screen_label(:unknown), do: "Unknown"
  def screen_label(name), do: name |> to_string() |> String.replace("_", " ")

  def screen_badge_class(nil), do: "badge badge-ghost"
  def screen_badge_class(:unknown), do: "badge badge-error"
  def screen_badge_class(_), do: "badge badge-success"

  def phase_label(:idle), do: nil
  def phase_label(:localizing), do: "Localizing…"
  def phase_label(:running), do: "Running…"
  def phase_label(:paused), do: "Paused"

  def outcome_class(outcome) when outcome in [:done, :would_run], do: "badge-success"
  def outcome_class(:partial), do: "badge-warning"
  def outcome_class(:failed), do: "badge-error"
  def outcome_class(_outcome), do: "badge-ghost"

end
