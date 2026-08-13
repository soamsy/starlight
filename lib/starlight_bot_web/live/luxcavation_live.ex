defmodule StarlightBotWeb.Live.LuxcavationLive do
  use StarlightBotWeb, :live_view
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
     |> assign(:teams, teams)
     |> assign(:team_id, default_team_id(teams))
     |> assign(:exp_count, "0")
     |> assign(:thread_count, "0")
     |> assign(:collect_xp, false)
     |> assign(:pending_action, nil)
     |> assign(:countdown, nil)}
  end

  @impl true
  def handle_event("run", %{"team_id" => team_id, "exp_count" => exp_count, "thread_count" => thread_count} = params, socket) do
    with {team_id, ""} <- Integer.parse(team_id),
         {exp_count, ""} <- Integer.parse(exp_count),
         {thread_count, ""} <- Integer.parse(thread_count),
         true <- exp_count >= 0 and thread_count >= 0 do
      collect_xp? = Map.get(params, "collect_xp") == "true"
      {:noreply, start_countdown(socket, {:run_luxcavation, team_id, exp_count, thread_count, collect_xp?})}
    else
      _ -> {:noreply, put_flash(socket, :error, "Pick a team and enter non-negative run counts.")}
    end
  end

  @impl true
  def handle_event(
        "update_form",
        %{"team_id" => team_id, "exp_count" => exp_count, "thread_count" => thread_count} = params,
        socket
      ) do
    {:noreply,
     socket
     |> assign(:team_id, parse_team_id(team_id, socket.assigns.team_id))
     |> assign(:exp_count, exp_count)
     |> assign(:thread_count, thread_count)
     |> assign(:collect_xp, Map.get(params, "collect_xp") == "true")}
  end

  @impl true
  def handle_event("resume", _, socket) do
    {:noreply, start_countdown(socket, :resume_luxcavation)}
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
     |> assign(:log, nav.log)}
  end

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

  defp run_pending_action({:run_luxcavation, team_id, exp_count, thread_count, collect_xp?}),
    do: Navigator.run_luxcavation(team_id, exp_count, thread_count, collect_xp?)

  defp run_pending_action(:resume_luxcavation), do: Navigator.resume_luxcavation()

  def pending_action_label({:run_luxcavation, _team_id, exp_count, thread_count, collect_xp?}) do
    suffix = if collect_xp?, do: " + battle pass xp", else: ""
    "luxcavation: #{exp_count} exp, #{thread_count} thread#{suffix}"
  end

  def pending_action_label(:resume_luxcavation), do: "resume luxcavation"

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
