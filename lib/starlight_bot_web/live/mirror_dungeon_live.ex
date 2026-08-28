defmodule StarlightBotWeb.Live.MirrorDungeonLive do
  use StarlightBotWeb, :live_view
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Navigation.Navigator
  alias StarlightBot.Teams

  @countdown_secs 2

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Navigator.subscribe()

    nav = Navigator.status()
    teams = Teams.list_teams() |> Enum.reject(&(&1.hook in [nil, ""]))

    {:ok,
     socket
     |> assign(:current_screen, nav.current_screen)
     |> assign(:phase, nav.phase)
     |> assign(:log, nav.log)
     |> assign(:run_memory, nav.run_memory)
     |> assign(:teams, teams)
     |> assign(:team_id, default_team_id(teams))
     |> assign(:run_count, "1")
     |> assign(:weekly_bonus, true)
     |> assign(:pending_action, nil)
     |> assign(:countdown, nil)}
  end

  @impl true
  def handle_event("run", %{"team_id" => team_id, "run_count" => run_count} = params, socket) do
    with {team_id, ""} <- Integer.parse(team_id),
         {run_count, ""} <- Integer.parse(run_count),
         true <- run_count >= 0 do
      config = %{weekly_bonus?: Map.get(params, "weekly_bonus") == "true"}
      {:noreply, start_countdown(socket, {:run_mirror_dungeon, team_id, run_count, config})}
    else
      _ -> {:noreply, put_flash(socket, :error, "Pick a team and enter a non-negative run count.")}
    end
  end

  @impl true
  def handle_event("update_form", %{"team_id" => team_id, "run_count" => run_count} = params, socket) do
    {:noreply,
     socket
     |> assign(:team_id, parse_team_id(team_id, socket.assigns.team_id))
     |> assign(:run_count, run_count)
     |> assign(:weekly_bonus, Map.get(params, "weekly_bonus") == "true")}
  end

  @impl true
  def handle_event("resume", _, socket) do
    {:noreply, start_countdown(socket, :resume_mirror_dungeon)}
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

  def current_floor(run_memory), do: Map.get(run_memory, :floor, 1)

  def current_cost(run_memory), do: Map.get(run_memory, :cost, nil)

  def current_mode(run_memory), do: RunMemory.mode_for(Map.get(run_memory, :team), current_floor(run_memory))

  defp default_team_id([]), do: nil
  defp default_team_id([%{id: id} | _]), do: id

  defp parse_team_id(str, fallback) do
    case Integer.parse(str) do
      {id, ""} -> id
      _ -> fallback
    end
  end

  defp start_countdown(socket, action) do
    Process.send_after(self(), :countdown_tick, 1_000)

    socket
    |> assign(:pending_action, action)
    |> assign(:countdown, @countdown_secs)
  end

  defp run_pending_action({:run_mirror_dungeon, team_id, run_count, config}),
    do: Navigator.run_mirror_dungeon(team_id, run_count, config)

  defp run_pending_action(:resume_mirror_dungeon), do: Navigator.resume_mirror_dungeon()

  def pending_action_label({:run_mirror_dungeon, _team_id, run_count, config}) do
    suffix = if config.weekly_bonus?, do: " + weekly bonuses", else: ""
    "mirror dungeon: #{run_count} run(s)#{suffix}"
  end

  def pending_action_label(:resume_mirror_dungeon), do: "resume mirror dungeon"

  def screen_label(nil), do: "Not localized"
  def screen_label(:unknown), do: "Unknown"
  def screen_label(name), do: name |> to_string() |> String.replace("_", " ")

  def screen_badge_class(nil), do: "badge badge-ghost"
  def screen_badge_class(:unknown), do: "badge badge-error"
  def screen_badge_class(_), do: "badge badge-success"

  def mode_badge_class("hard"), do: "badge badge-error font-mono"
  def mode_badge_class(_), do: "badge badge-ghost font-mono"

  def phase_label(:idle), do: nil
  def phase_label(:localizing), do: "Localizing…"
  def phase_label(:running), do: "Running…"
  def phase_label(:paused), do: "Paused"

  def log_kind_class(:ok), do: "text-success"
  def log_kind_class(:error), do: "text-error"
  def log_kind_class(:info), do: "text-base-content/60"
  def log_kind_class(_), do: "text-base-content/40"
end
