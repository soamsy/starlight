defmodule StarlightBotWeb.Live.ShopRunnerLive do
  use StarlightBotWeb, :live_view
  alias StarlightBot.Navigation.Navigator
  alias StarlightBot.Teams

  @countdown_secs 2

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Navigator.subscribe()

    nav = Navigator.status()
    teams = Teams.list_teams() |> Enum.reject(&is_nil(&1.gift_strategy_id))

    {:ok,
     socket
     |> assign(:current_screen, nav.current_screen)
     |> assign(:phase, nav.phase)
     |> assign(:log, nav.log)
     |> assign(:run_memory, nav.run_memory)
     |> assign(:teams, teams)
     |> assign(:team_id, default_team_id(teams))
     |> assign(:pending_action, nil)
     |> assign(:countdown, nil)}
  end

  @impl true
  def handle_event("dry_run", _, socket) do
    case Enum.find(socket.assigns.teams, &(&1.id == socket.assigns.team_id)) do
      nil -> {:noreply, put_flash(socket, :error, "Pick a team first.")}
      team -> {:noreply, start_countdown(socket, {:run_shop_dry_run, team.id, team.name})}
    end
  end

  @impl true
  def handle_event("full_run", _, socket) do
    case Enum.find(socket.assigns.teams, &(&1.id == socket.assigns.team_id)) do
      nil -> {:noreply, put_flash(socket, :error, "Pick a team first.")}
      team -> {:noreply, start_countdown(socket, {:run_shop_buyer, team.id, team.name})}
    end
  end

  @impl true
  def handle_event("update_form", %{"team_id" => team_id}, socket) do
    {:noreply, assign(socket, :team_id, parse_team_id(team_id, socket.assigns.team_id))}
  end

  @impl true
  def handle_event("restore_form", params, socket) do
    {:noreply, assign(socket, :team_id, restore_team_id(params, socket.assigns.team_id))}
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
     |> assign(:log, nav.log)
     |> assign(:run_memory, nav.run_memory)}
  end

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

  defp restore_team_id(params, fallback) do
    case Map.get(params, "team_id") do
      nil -> fallback
      str -> parse_team_id(str, fallback)
    end
  end

  defp start_countdown(socket, action) do
    Process.send_after(self(), :countdown_tick, 1_000)

    socket
    |> assign(:pending_action, action)
    |> assign(:countdown, @countdown_secs)
  end

  defp run_pending_action({:run_shop_dry_run, team_id, _team_name}), do: Navigator.run_shop_dry_run(team_id)
  defp run_pending_action({:run_shop_buyer, team_id, _team_name}), do: Navigator.run_shop_buyer(team_id)

  def pending_action_label({:run_shop_dry_run, _team_id, team_name}), do: "shop dry run: #{team_name}"
  def pending_action_label({:run_shop_buyer, _team_id, team_name}), do: "shop buyer (full run): #{team_name}"

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

  def log_kind_class(:ok), do: "text-success"
  def log_kind_class(:error), do: "text-error"
  def log_kind_class(:info), do: "text-base-content/60"
  def log_kind_class(_), do: "text-base-content/40"
end
