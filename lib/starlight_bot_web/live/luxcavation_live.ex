defmodule StarlightBotWeb.Live.LuxcavationLive do
  use StarlightBotWeb, :live_view
  alias StarlightBot.Navigation.Navigator
  alias StarlightBot.Teams

  @countdown_secs 2
  @max_consecutive 10
  @exp_enkephalin_cost 3
  @thread_enkephalin_cost 2

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
     |> assign(:exp_consecutive, "1")
     |> assign(:exp_repeats, "1")
     |> assign(:thread_consecutive, "3")
     |> assign(:thread_repeats, "1")
     |> assign(:collect_xp, true)
     |> assign(:collect_enkephalin, true)
     |> assign(:enkephalin_convert_count, "0")
     |> assign(:pending_action, nil)
     |> assign(:countdown, nil)}
  end

  @impl true
  def handle_event(
        "run",
        %{
          "team_id" => team_id,
          "exp_consecutive" => exp_consecutive,
          "exp_repeats" => exp_repeats,
          "thread_consecutive" => thread_consecutive,
          "thread_repeats" => thread_repeats
        } = params,
        socket
      ) do
    enkephalin_convert_count_str = Map.get(params, "enkephalin_convert_count", "0")

    with {team_id, ""} <- Integer.parse(team_id),
         {exp_consecutive, ""} <- Integer.parse(exp_consecutive),
         {exp_repeats, ""} <- Integer.parse(exp_repeats),
         {thread_consecutive, ""} <- Integer.parse(thread_consecutive),
         {thread_repeats, ""} <- Integer.parse(thread_repeats),
         {enkephalin_convert_count, ""} <- Integer.parse(enkephalin_convert_count_str),
         true <- exp_consecutive in 0..@max_consecutive and thread_consecutive in 0..@max_consecutive,
         true <- exp_repeats >= 0 and thread_repeats >= 0,
         true <- enkephalin_convert_count in 0..4 do
      collect_xp? = Map.get(params, "collect_xp") == "true"
      collect_enkephalin? = Map.get(params, "collect_enkephalin") == "true"

      {:noreply,
       start_countdown(
         socket,
         {:run_luxcavation, team_id, exp_consecutive, exp_repeats, thread_consecutive, thread_repeats, collect_xp?,
          collect_enkephalin?, enkephalin_convert_count}
       )}
    else
      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Pick a team, keep consecutive battles at 0-#{@max_consecutive}, and repeats non-negative."
         )}
    end
  end

  @impl true
  def handle_event(
        "update_form",
        %{
          "team_id" => team_id,
          "exp_consecutive" => exp_consecutive,
          "exp_repeats" => exp_repeats,
          "thread_consecutive" => thread_consecutive,
          "thread_repeats" => thread_repeats
        } = params,
        socket
      ) do
    {:noreply,
     socket
     |> assign(:team_id, parse_team_id(team_id, socket.assigns.team_id))
     |> assign(:exp_consecutive, exp_consecutive)
     |> assign(:exp_repeats, exp_repeats)
     |> assign(:thread_consecutive, thread_consecutive)
     |> assign(:thread_repeats, thread_repeats)
     |> assign(:collect_xp, Map.get(params, "collect_xp") == "true")
     |> assign(:collect_enkephalin, Map.get(params, "collect_enkephalin") == "true")
     |> assign(:enkephalin_convert_count, Map.get(params, "enkephalin_convert_count", socket.assigns.enkephalin_convert_count))}
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

  defp run_pending_action(
         {:run_luxcavation, team_id, exp_consecutive, exp_repeats, thread_consecutive, thread_repeats, collect_xp?,
          collect_enkephalin?, enkephalin_convert_count}
       ),
       do:
         Navigator.run_luxcavation(
           team_id,
           exp_consecutive,
           exp_repeats,
           thread_consecutive,
           thread_repeats,
           collect_xp?,
           collect_enkephalin?,
           enkephalin_convert_count
         )

  defp run_pending_action(:resume_luxcavation), do: Navigator.resume_luxcavation()

  def pending_action_label(
        {:run_luxcavation, _team_id, exp_consecutive, exp_repeats, thread_consecutive, thread_repeats, collect_xp?,
         collect_enkephalin?, enkephalin_convert_count}
      ) do
    enkephalin_prefix = if collect_enkephalin?, do: "enkephalin (#{enkephalin_convert_count}x lunacy) + ", else: ""
    xp_suffix = if collect_xp?, do: " + battle pass xp", else: ""

    "luxcavation: #{enkephalin_prefix}#{exp_repeats}x#{exp_consecutive} exp (#{total_runs(exp_consecutive, exp_repeats)}), " <>
      "#{thread_repeats}x#{thread_consecutive} thread (#{total_runs(thread_consecutive, thread_repeats)})#{xp_suffix}"
  end

  def pending_action_label(:resume_luxcavation), do: "resume luxcavation"

  @enkephalin_cumulative_costs [0, 26, 78, 156, 260]

  def enkephalin_cumulative_cost(count) when count in 0..4, do: Enum.at(@enkephalin_cumulative_costs, count)

  def total_runs(consecutive, repeats) do
    with {consecutive, ""} <- Integer.parse(to_string(consecutive)),
         {repeats, ""} <- Integer.parse(to_string(repeats)) do
      consecutive * repeats
    else
      _ -> 0
    end
  end

  def max_consecutive, do: @max_consecutive
  def exp_enkephalin_cost, do: @exp_enkephalin_cost
  def thread_enkephalin_cost, do: @thread_enkephalin_cost

  def enkephalin_modules(run_count, per_run_cost), do: run_count * per_run_cost

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
