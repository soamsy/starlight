defmodule StarlightBotWeb.Live.RunnerLive do
  use StarlightBotWeb, :live_view
  import StarlightBotWeb.Components.HookSelect, only: [hook_select: 1]
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Navigation.{Navigator, RunArchive, ScreenTimes}
  alias StarlightBot.{AppSettings, EgoGifts, GiftPlans, LuxSchedule, Plans, RestCycle, RunHistory, RunnerForms, StarlightBudget, TeamBudget, Teams}
  alias StarlightBot.PackPlans.Resolver
  alias StarlightBotWeb.Live.GiftPlanEditorLive

  @countdown_secs 2
  @day_tick_ms 60_000
  @clock_tick_ms 1_000
  @exp_enkephalin_cost 3
  @thread_enkephalin_cost 2

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Navigator.subscribe()
      RunHistory.subscribe()
      RunnerForms.subscribe()
      Process.send_after(self(), :clock_tick, @clock_tick_ms)
      Process.send_after(self(), :day_tick, @day_tick_ms)
    end

    nav = Navigator.status()
    teams = Teams.list_teams() |> Enum.reject(&(&1.hooks == []))

    {:ok,
     socket
     |> assign(:tab, socket.assigns[:live_action] || nav.run_kind || :mirror_dungeon)
     |> assign(:gifts_by_name, Map.new(EgoGifts.list_gifts(), &{&1.name, &1}))
     |> assign_nav(nav)
     |> assign(:show_screen_times, false)
     |> assign(:show_forecast_info, false)
     |> assign(:screen_view, "breakdown")
     |> assign(:screen_source, "live")
     |> assign(:screen_filter, %{run: nil, floor: nil})
     |> assign(:history_runs, [])
     |> assign(:history_segments, [])
     |> assign(:teams, teams)
     |> assign(:picks, default_picks(teams))
     |> assign(:start_index, 0)
     |> assign(:reserve, [])
     |> assign(:reorder_rev, 0)
     |> assign(:run_count, "1")
     |> assign(:rewards, "auto")
     |> assign(:collect_enkephalin, false)
     |> assign(:collect_xp, false)
     |> assign(:battle_debug, AppSettings.battle_debug?())
     |> assign(:pending_action, nil)
     |> assign(:countdown, nil)
     |> restore_form(RunnerForms.get("mirror_dungeon"))
     |> assign(:today, LuxSchedule.today())
     |> assign(:exp_pin, nil)
     |> assign(:thread_pin, nil)
     |> assign(:exp_picks, List.duplicate(nil, LuxSchedule.exp_slot_count()))
     |> assign(:thread_picks, List.duplicate(nil, LuxSchedule.thread_slot_count()))
     |> assign(:exp_waves, "1")
     |> assign(:thread_waves, "3")
     |> assign(:lux_collect_xp, true)
     |> assign(:lux_collect_enkephalin, true)
     |> assign(:md_next, RunnerForms.mirror_dungeon_action())
     |> assign(:then_md, false)
     |> restore_lux_form(RunnerForms.get("luxcavation"))}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: tab}} = socket) when tab in [:mirror_dungeon, :luxcavation] do
    {:noreply, socket |> assign(:tab, tab) |> assign_other_running()}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_forecast_info", _, socket), do: {:noreply, update(socket, :show_forecast_info, &(!&1))}

  @impl true
  def handle_event("localize", _, socket) do
    Navigator.localize()
    {:noreply, socket}
  end

  @impl true
  def handle_event("restore_tab", %{"tab" => tab}, socket) when tab in ~w(mirror_dungeon luxcavation) do
    {:noreply, socket |> assign(:tab, String.to_existing_atom(tab)) |> assign_other_running()}
  end

  @impl true
  def handle_event("run", %{"exp_waves" => _} = params, socket) do
    pins = %{"exp_pin" => to_string(socket.assigns.exp_pin), "thread_pin" => to_string(socket.assigns.thread_pin)}

    case RunnerForms.luxcavation_action(Map.merge(params, pins)) do
      {:ok, lux} ->
        action =
          case {params["then"], socket.assigns.md_next} do
            {"mirror_dungeon", {:run_mirror_dungeon, _, _, _} = md} -> {:then, lux, md}
            _ -> lux
          end

        {:noreply, start_countdown(socket, action)}

      :error ->
        {:noreply, put_flash(socket, :error, "Pick a team for today's slots, and keep waves non-negative.")}
    end
  end

  @impl true
  def handle_event("run", params, socket) do
    case RunnerForms.mirror_dungeon_action(params, socket.assigns.teams) do
      {:ok, action} -> {:noreply, start_countdown(socket, action)}
      :error -> {:noreply, put_flash(socket, :error, "Pick at least one team and enter a non-negative run count.")}
    end
  end

  @impl true
  def handle_event("toggle_battle_debug", _, socket) do
    enabled? = not socket.assigns.battle_debug
    AppSettings.put_battle_debug(enabled?)
    {:noreply, assign(socket, :battle_debug, enabled?)}
  end

  @impl true
  def handle_event("update_form", %{"exp_waves" => exp_waves, "thread_waves" => thread_waves} = params, socket) do
    {:noreply,
     socket
     |> assign_picks(params)
     |> assign(:then_md, params["then"] == "mirror_dungeon")
     |> assign(:exp_waves, exp_waves)
     |> assign(:thread_waves, thread_waves)
     |> assign(:lux_collect_xp, Map.get(params, "collect_xp") == "true")
     |> assign(:lux_collect_enkephalin, Map.get(params, "collect_enkephalin") == "true")
     |> save_lux_form()}
  end

  @impl true
  def handle_event("clear_pin", %{"kind" => kind}, socket) do
    {:noreply, socket |> assign(pin_key(kind), nil) |> save_lux_form()}
  end

  @impl true
  def handle_event("set_pin", %{"kind" => kind, "index" => index}, socket) do
    count = if kind == "exp", do: LuxSchedule.exp_slot_count(), else: LuxSchedule.thread_slot_count()
    {:noreply, socket |> assign(pin_key(kind), RunnerForms.parse_pin(index, count)) |> save_lux_form()}
  end

  @impl true
  def handle_event("reorder_exp", %{"ids" => ids}, socket), do: {:noreply, reorder(socket, :exp_picks, ids)}

  @impl true
  def handle_event("reorder_thread", %{"ids" => ids}, socket), do: {:noreply, reorder(socket, :thread_picks, ids)}

  @impl true
  def handle_event("update_form", %{"run_count" => run_count} = params, socket) do
    socket =
      if cycle_locked?(socket.assigns.phase, socket.assigns.other_running?, socket.assigns.run_kind) do
        socket
      else
        picks = RunnerForms.parse_team_picks(params["team_ids"], params["team_hooks"], params["team_modes"], params["team_searches"], socket.assigns.teams, socket.assigns.picks)
        reserve = RunnerForms.parse_team_picks(params["reserve_ids"], params["reserve_hooks"], params["reserve_modes"], params["reserve_searches"], socket.assigns.teams, socket.assigns.reserve)
        socket |> assign(:picks, picks) |> assign(:reserve, reserve) |> assign(:start_index, RunnerForms.parse_start_index(params["start_index"], picks))
      end

    {:noreply,
     socket
     |> assign(:run_count, run_count)
     |> assign(:rewards, Map.get(params, "rewards", socket.assigns.rewards))
     |> assign(:collect_enkephalin, Map.get(params, "collect_enkephalin") == "true")
     |> assign(:collect_xp, Map.get(params, "collect_xp") == "true")
     |> save_form()}
  end

  @impl true
  def handle_event(event, _params, socket)
      when (event in ~w(set_cycle_start single_run) or
              (event in ~w(add_team remove_cycle_team reorder_teams set_pick_option remove_reserve_team) and socket.assigns.run_kind != :mirror_dungeon)) and
             socket.assigns.phase != :idle and not socket.assigns.other_running? do
    {:noreply, socket}
  end

  @impl true
  def handle_event("set_pick_option", %{"list" => list, "index" => index, "key" => key, "option" => option}, socket) when key in ~w(mode search) and list in ~w(cycle reserve) do
    index = String.to_integer(index)
    key = String.to_existing_atom(key)
    parse = if key == :mode, do: &Resolver.parse_mode_override/1, else: &Resolver.parse_search_override/1
    field = list_field(list)

    {:noreply,
     socket
     |> assign(field, List.update_at(socket.assigns[field], index, &Map.put(&1, key, parse.(option))))
     |> save_form()}
  end

  @impl true
  def handle_event("add_team", _, socket) do
    %{reserve: reserve, picks: picks} = socket.assigns
    {:noreply, socket |> assign(:reserve, reserve ++ Enum.take(reserve ++ picks, -1)) |> save_form()}
  end

  @impl true
  def handle_event("remove_cycle_team", %{"index" => index}, socket) do
    %{picks: picks, start_index: start} = socket.assigns
    index = String.to_integer(index)

    if length(picks) > 1 do
      picks = List.delete_at(picks, index)
      start = if index < start, do: start - 1, else: min(start, length(picks) - 1)
      {:noreply, socket |> assign(:picks, picks) |> assign(:start_index, start) |> save_form()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("remove_reserve_team", %{"index" => index}, socket) do
    {:noreply, socket |> assign(:reserve, List.delete_at(socket.assigns.reserve, String.to_integer(index))) |> save_form()}
  end

  @impl true
  def handle_event("set_cycle_start", %{"index" => index}, socket) do
    {:noreply, socket |> assign(:start_index, RunnerForms.parse_start_index(index, socket.assigns.picks)) |> save_form()}
  end

  @impl true
  def handle_event("reorder_teams", %{"ids" => ids}, socket) do
    {:noreply, apply_team_layout(socket, ids)}
  end

  @impl true
  def handle_event("single_run", %{"list" => list, "index" => index, "dry" => dry}, socket) when list in ~w(cycle reserve) and dry in ~w(true false) do
    with %{} = pick <- Enum.at(socket.assigns[list_field(list)], String.to_integer(index)),
         params = socket.assigns |> form_params() |> Map.merge(single_pick_params(pick)) |> then(&if(dry == "true", do: Map.put(&1, "rewards", "none"), else: &1)),
         {:ok, {:run_mirror_dungeon, picks, run_count, config}} <- RunnerForms.mirror_dungeon_action(params, socket.assigns.teams) do
      {:noreply, start_countdown(socket, {:run_mirror_dungeon, picks, run_count, Map.put(config, :single?, true)})}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not start a single run for that team.")}
    end
  end

  @impl true
  def handle_event("resume", _, socket) do
    action = if socket.assigns.run_kind == :luxcavation, do: :resume_luxcavation, else: :resume_mirror_dungeon
    {:noreply, start_countdown(socket, action)}
  end

  @impl true
  def handle_event("cancel_pending", _, socket) do
    {:noreply, socket |> assign(:pending_action, nil) |> assign(:countdown, nil)}
  end

  @impl true
  def handle_event("toggle_screen_times", _, socket) do
    show? = not socket.assigns.show_screen_times
    socket = assign(socket, :show_screen_times, show?)
    {:noreply, if(show?, do: assign(socket, :history_runs, RunHistory.list_runs()), else: socket)}
  end

  @impl true
  def handle_event("screen_view", %{"view" => view}, socket) when view in ["breakdown", "timeline"] do
    {:noreply, assign(socket, :screen_view, view)}
  end

  @impl true
  def handle_event("screen_source", %{"source" => "live"}, socket) do
    {:noreply, socket |> assign(:screen_source, "live") |> assign(:history_segments, []) |> assign(:screen_filter, %{run: nil, floor: nil})}
  end

  @impl true
  def handle_event("screen_source", %{"source" => source}, socket) do
    case Integer.parse(source) do
      {id, ""} ->
        {:noreply,
         socket
         |> assign(:screen_source, id)
         |> assign(:history_segments, RunHistory.segments(id))
         |> assign(:screen_filter, %{run: nil, floor: nil})}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("screen_filter", params, socket) do
    {:noreply, assign(socket, :screen_filter, %{run: parse_filter(params["run"]), floor: parse_filter(params["floor"])})}
  end

  @impl true
  def handle_event("pause", _, socket) do
    Navigator.pause()
    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel", _, socket) do
    Navigator.cancel()
    {:noreply, socket}
  end

  @impl true
  def handle_info({:window_gate_run, params}, %{assigns: %{phase: :idle}} = socket), do: handle_event("run", params, socket)
  def handle_info({:window_gate_run, _params}, socket), do: {:noreply, socket}

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
    {:noreply, assign_nav(socket, nav)}
  end

  @impl true
  def handle_info(:day_tick, socket) do
    Process.send_after(self(), :day_tick, @day_tick_ms)
    {:noreply, assign(socket, :today, LuxSchedule.today())}
  end

  @impl true
  def handle_info({:runner_form, "mirror_dungeon"}, socket) do
    params = RunnerForms.get("mirror_dungeon") || %{}

    {:noreply,
     socket
     |> assign(:start_index, RunnerForms.parse_start_index(params["start_index"], socket.assigns.picks))
     |> assign(:md_next, RunnerForms.mirror_dungeon_action())}
  end

  @impl true
  def handle_info({:runner_form, _runner}, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:team_plans_changed, socket) do
    teams = Teams.list_teams() |> Enum.reject(&(&1.hooks == []))
    {:noreply, socket |> assign(:teams, teams)}
  end

  @impl true
  def handle_info(:run_history_changed, socket) do
    {:noreply, if(socket.assigns.show_screen_times, do: assign(socket, :history_runs, RunHistory.list_runs()), else: socket)}
  end

  @impl true
  def handle_info(:clock_tick, socket) do
    Process.send_after(self(), :clock_tick, @clock_tick_ms)

    case socket.assigns.run_clock do
      %{running?: true} -> {:noreply, assign(socket, :now_ms, now_ms())}
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp assign_clock(socket, run_clock) do
    now = now_ms()
    socket |> assign(:run_clock, run_clock && Map.put(run_clock, :received_ms, now)) |> assign(:now_ms, now)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp assign_nav(socket, nav) do
    socket
    |> assign(:current_screen, nav.current_screen)
    |> assign(:phase, nav.phase)
    |> assign(:pause_requested, nav.pause_requested)
    |> assign(:run_kind, nav.run_kind)
    |> assign(:run_memory, nav.run_memory)
    |> assign_milestones()
    |> assign_clock(nav.run_clock)
    |> assign(:run_splits, nav.run_splits)
    |> assign(:run_times_kind, nav.run_times_kind)
    |> assign(:run_started_at, nav.run_started_at)
    |> assign(:run_archive, nav.run_archive)
    |> assign(:screen_times, nav.screen_times)
    |> assign_other_running()
  end

  defp assign_other_running(socket) do
    %{run_kind: run_kind, tab: tab} = socket.assigns
    assign(socket, :other_running?, run_kind != nil and run_kind != tab)
  end

  def elapsed_ms(nil, _now_ms), do: nil
  def elapsed_ms(%{running?: true, elapsed_ms: ms, received_ms: at}, now_ms), do: ms + max(now_ms - at, 0)
  def elapsed_ms(%{elapsed_ms: ms}, _now_ms), do: ms

  def format_elapsed(ms) do
    total = div(ms, 1000)
    hours = div(total, 3600)
    minutes = total |> rem(3600) |> div(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    seconds = total |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    if hours > 0, do: "#{hours}:#{minutes}:#{seconds}", else: "#{minutes}:#{seconds}"
  end

  def other_running_notice(:luxcavation), do: "Luxcavation is running. Cancel it from its tab before starting this."
  def other_running_notice(:mirror_dungeon), do: "Mirror dungeon is running. Cancel it from its tab before starting this."
  def other_running_notice(:enkephalin), do: "Enkephalin charge is running. Wait for it to finish before starting this."
  def other_running_notice(:prepare_lineups), do: "Lineup preparation is running. Wait for it to finish before starting this."
  def other_running_notice(:team_survey), do: "Team hook survey is running. Wait for it to finish before starting this."
  def other_running_notice(_), do: "Another run is in progress. Wait for it to finish before starting this."

  def cycle_locked?(phase, other_running?, run_kind), do: phase != :idle and not other_running? and run_kind != :mirror_dungeon

  def live_cycle?(phase, other_running?, run_kind), do: phase != :idle and not other_running? and run_kind == :mirror_dungeon

  def running_team?(run_memory, %{id: id, hook: hook}), do: match?(%{id: ^id, hook: ^hook}, Map.get(run_memory, :team))

  def run_progress(run_memory), do: Map.get(run_memory, :run_progress)

  attr :groups, :list, required: true
  attr :live_last?, :boolean, required: true

  def run_times(assigns) do
    ~H"""
    <%= if @groups == [] do %>
      <div class="text-xs text-base-content/30">No runs in the last 24 hours</div>
    <% else %>
      <%= for {group, group_index} <- Enum.with_index(@groups, 1) do %>
        <% last_group? = group_index == length(@groups) %>
        <div class="flex flex-col gap-1">
          <%= for {run, index} <- Enum.with_index(group.runs, 1) do %>
            <div class={"flex flex-col gap-0.5 rounded-lg p-1.5 " <> if(@live_last? and last_group? and index == length(group.runs), do: "bg-primary/10", else: "bg-base-100/50")}>
              <div class="flex items-center justify-between text-xs font-semibold">
                <span class="flex items-center gap-1 min-w-0">
                  <%= run_label(group.kind, run.run) %>
                  <span :if={run.team} class="font-normal text-base-content/60 truncate"><%= run.team %></span>
                  <span :if={run.failed?} class="badge badge-error badge-xs">failed</span>
                </span>
                <span class="font-mono"><%= format_elapsed(run.ms) %></span>
              </div>
              <div :for={floor <- run.floors} class="flex items-center justify-between gap-2 text-[11px] text-base-content/60 pl-2">
                <span class="flex items-center gap-1 min-w-0">
                  <span class="shrink-0"><%= floor_label(floor.floor) %></span>
                  <span :if={floor.pack} class="text-base-content/40 truncate" title={floor.pack}><%= floor.pack %></span>
                </span>
                <span class="font-mono"><%= format_elapsed(floor.ms) %></span>
              </div>
            </div>
          <% end %>
          <div class="flex items-center justify-between text-xs text-base-content/60 border-t border-base-300 pt-1">
            <span><%= group_label(group.kind) %> subtotal</span>
            <span class="font-mono"><%= format_elapsed(group.ms) %></span>
          </div>
        </div>
      <% end %>
    <% end %>
    """
  end

  defp run_label(:luxcavation, _run), do: "Luxcavation"
  defp run_label(_kind, run), do: "Run #{run}"

  defp group_label(:luxcavation), do: "Luxcavation"
  defp group_label(_kind), do: "Mirror dungeon"

  defp floor_label(:exp), do: "EXP"
  defp floor_label(:thread), do: "Thread"
  defp floor_label(floor), do: "Floor #{floor}"

  def screen_segments("live", screen_times, _history_segments, run_clock, now_ms),
    do: ScreenTimes.segments(screen_times, elapsed_ms(run_clock, now_ms) || 0)

  def screen_segments(_run_log_id, _screen_times, history_segments, _run_clock, _now_ms), do: history_segments

  def filter_segments(segments, %{run: run, floor: floor}) do
    Enum.filter(segments, &((is_nil(run) or &1.run == run) and (is_nil(floor) or &1.floor == floor)))
  end

  defp parse_filter(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  def screen_time_label(nil), do: "No screen (localizing / unrecognized)"
  def screen_time_label(screen), do: screen_label(screen)

  def detail_label(""), do: "(no step recorded)"
  def detail_label(detail), do: detail

  def visit_label(%{screen: screen, floor: floor, ms: ms, segments: segments}) do
    steps = segments |> Enum.map(&"#{detail_label(ScreenTimes.detail(&1))} #{format_elapsed(ScreenTimes.duration_ms(&1))}") |> Enum.join("\n")
    "#{screen_time_label(screen)} · floor #{floor} · #{format_elapsed(ms)}\n#{steps}"
  end

  def screen_color(nil), do: "hsl(0 0% 60%)"
  def screen_color(screen), do: "hsl(#{:erlang.phash2(to_string(screen), 360)} 55% 55%)"

  def width_pct(_ms, 0), do: "0%"
  def width_pct(ms, total), do: "#{Float.round(ms * 100 / total, 3)}%"

  def percent(_ms, 0), do: "0%"
  def percent(ms, total), do: "#{round(ms * 100 / total)}%"

  def history_run_label(run) do
    started = run.started_at |> to_string() |> String.slice(0, 16) |> String.replace("T", " ")
    "##{run.id} · #{run.team_name || "?"} · #{started} · #{run.result} · F#{run.floors_completed} · #{format_elapsed((run.duration_seconds || 0) * 1000)}"
  end

  attr :segments, :list, required: true
  attr :view, :string, default: "breakdown"
  attr :source, :any, default: "live"
  attr :filter, :map, default: %{run: nil, floor: nil}
  attr :history_runs, :list, default: []

  def screen_times(assigns) do
    filtered = filter_segments(assigns.segments, assigns.filter)
    breakdown = ScreenTimes.breakdown(filtered)

    assigns =
      assigns
      |> assign(:breakdown, breakdown)
      |> assign(:timeline, ScreenTimes.timeline(assigns.segments))
      |> assign(:total, breakdown |> Enum.map(& &1.ms) |> Enum.sum())
      |> assign(:runs, assigns.segments |> Enum.map(& &1.run) |> Enum.uniq())
      |> assign(:floors, assigns.segments |> Enum.map(& &1.floor) |> Enum.filter(&is_integer/1) |> Enum.uniq() |> Enum.sort())

    ~H"""
    <div class="modal modal-open" phx-window-keydown="toggle_screen_times" phx-key="Escape">
      <div class="modal-box max-w-4xl">
        <div class="flex items-center justify-between gap-2 mb-2">
          <h3 class="font-semibold">Time per screen</h3>
          <div role="tablist" class="tabs tabs-boxed tabs-xs">
            <button type="button" role="tab" phx-click="screen_view" phx-value-view="breakdown" class={"tab " <> if(@view == "breakdown", do: "tab-active", else: "")}>Breakdown</button>
            <button type="button" role="tab" phx-click="screen_view" phx-value-view="timeline" class={"tab " <> if(@view == "timeline", do: "tab-active", else: "")}>Timeline</button>
          </div>
        </div>

        <form phx-change="screen_source" class="mb-2">
          <select name="source" class="select select-bordered select-xs w-full">
            <option value="live" selected={@source == "live"}>This session (live)</option>
            <option :for={run <- @history_runs} value={run.id} selected={@source == run.id}><%= history_run_label(run) %></option>
          </select>
        </form>

        <%= cond do %>
          <% @segments == [] -> %>
            <div class="text-sm text-base-content/40">No screen time recorded yet</div>
          <% @view == "breakdown" -> %>
            <form phx-change="screen_filter" class="flex gap-2 mb-2">
              <select :if={length(@runs) > 1} name="run" class="select select-bordered select-xs">
                <option value="">All runs</option>
                <option :for={run <- @runs} value={run} selected={@filter.run == run}>Run <%= run %></option>
              </select>
              <select name="floor" class="select select-bordered select-xs">
                <option value="">All floors</option>
                <option :for={floor <- @floors} value={floor} selected={@filter.floor == floor}>Floor <%= floor %></option>
              </select>
            </form>
            <div class="max-h-[60vh] overflow-y-auto">
              <div class="grid grid-cols-[1fr_4.5rem_3rem_3rem_4.5rem_4.5rem] gap-x-2 text-[11px] text-base-content/50 px-2 pb-1">
                <span>Screen</span><span class="text-right">Total</span><span class="text-right">Share</span>
                <span class="text-right">Visits</span><span class="text-right">Avg</span><span class="text-right">Longest</span>
              </div>
              <details :for={row <- @breakdown} class="group rounded hover:bg-base-200">
                <summary class="grid grid-cols-[1fr_4.5rem_3rem_3rem_4.5rem_4.5rem] gap-x-2 text-xs px-2 py-0.5 cursor-pointer list-none">
                  <span class={"flex items-center gap-1.5 " <> if(is_nil(row.screen), do: "italic text-base-content/60", else: "font-mono")}>
                    <span class="inline-block w-2 h-2 rounded-sm shrink-0" style={"background: #{screen_color(row.screen)}"}></span>
                    <%= screen_time_label(row.screen) %>
                  </span>
                  <span class="font-mono text-right"><%= format_elapsed(row.ms) %></span>
                  <span class="font-mono text-right text-base-content/50"><%= percent(row.ms, @total) %></span>
                  <span class="font-mono text-right text-base-content/50"><%= row.visits %></span>
                  <span class="font-mono text-right text-base-content/50"><%= format_elapsed(div(row.ms, row.visits)) %></span>
                  <span class="font-mono text-right text-base-content/50"><%= format_elapsed(row.longest_ms) %></span>
                </summary>
                <div :for={detail <- row.details} class="grid grid-cols-[1fr_4.5rem_3rem_3rem_4.5rem_4.5rem] gap-x-2 text-[11px] text-base-content/70 pl-6 pr-2">
                  <span class="font-mono truncate" title={detail_label(detail.detail)}><%= detail_label(detail.detail) %></span>
                  <span class="font-mono text-right"><%= format_elapsed(detail.ms) %></span>
                  <span class="font-mono text-right text-base-content/50"><%= percent(detail.ms, row.ms) %></span>
                  <span class="font-mono text-right text-base-content/50"><%= detail.count %></span>
                  <span></span><span></span>
                </div>
              </details>
            </div>
          <% true -> %>
            <div class="max-h-[60vh] overflow-y-auto flex flex-col gap-3">
              <div :for={run <- @timeline} class="flex flex-col gap-1">
                <div class="flex items-center justify-between text-xs font-semibold">
                  <span>Run <%= run.run %></span>
                  <span class="font-mono"><%= format_elapsed(run.ms) %></span>
                </div>
                <div class="flex w-full h-3 text-[9px] leading-3 text-base-content/60">
                  <div :for={floor <- run.floors} class="overflow-hidden whitespace-nowrap border-l border-base-content/30 pl-0.5" style={"width: #{width_pct(floor.ms, run.ms)}"}>F<%= floor.floor %></div>
                </div>
                <div class="flex w-full h-6 rounded overflow-hidden bg-base-200">
                  <div :for={visit <- run.visits} class="h-full" style={"width: #{width_pct(visit.ms, run.ms)}; background: #{screen_color(visit.screen)}"} title={visit_label(visit)}></div>
                </div>
                <details class="text-[11px]">
                  <summary class="cursor-pointer text-base-content/50"><%= length(run.visits) %> visits</summary>
                  <div :for={visit <- run.visits} class="grid grid-cols-[3.5rem_1fr_2.5rem_4rem] gap-x-2 px-1">
                    <span class="font-mono text-base-content/50"><%= format_elapsed(visit.start_ms - run.start_ms) %></span>
                    <span class={"flex items-center gap-1.5 truncate " <> if(is_nil(visit.screen), do: "italic text-base-content/60", else: "font-mono")} title={visit_label(visit)}>
                      <span class="inline-block w-2 h-2 rounded-sm shrink-0" style={"background: #{screen_color(visit.screen)}"}></span>
                      <%= screen_time_label(visit.screen) %>
                    </span>
                    <span class="font-mono text-base-content/50">F<%= visit.floor %></span>
                    <span class="font-mono text-right"><%= format_elapsed(visit.ms) %></span>
                  </div>
                </details>
              </div>
            </div>
        <% end %>
        <div class="modal-action mt-3">
          <button type="button" phx-click="toggle_screen_times" class="btn btn-sm">Close</button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="toggle_screen_times"></div>
    </div>
    """
  end

  def run_time_groups(assigns) do
    now = DateTime.utc_now()
    current = RunArchive.entry(%{run_times_kind: assigns.run_times_kind, run_splits: assigns.run_splits, run_started_at: assigns.run_started_at, run_memory: assigns.run_memory}, elapsed_ms(assigns.run_clock, assigns.now_ms) || 0)

    assigns.run_archive
    |> RunArchive.push(current, now)
    |> RunArchive.groups()
  end

  defp assign_milestones(socket) do
    assign(socket, :milestones, milestone_statuses(socket.assigns.run_memory, socket.assigns.gifts_by_name))
  end

  defp milestone_statuses(run_memory, gifts_by_name) do
    with %{id: team_id} = team <- Map.get(run_memory, :team),
         %{} = full <- Teams.get_team(team_id),
         %{data: %{"milestones" => _} = raw} <- Plans.for_team(full, :gift_plans),
         %{"milestones" => milestones} = data <- GiftPlans.for_run(raw, RunMemory.run_kind(team)) do
      env = %{
        plan: data,
        floor: current_floor(run_memory),
        gifts: gifts_by_name,
        inventory: ego_gifts(run_memory),
        skill_replaces: Map.get(run_memory, :skill_replaces, %{})
      }

      Enum.map(milestones, fn milestone ->
        progress = GiftPlans.progress(data, milestone["id"], env)

        gifts =
          progress
          |> GiftPlans.goal_entries()
          |> Enum.filter(&is_binary(&1.gift))
          |> Enum.uniq_by(& &1.gift)
          |> Enum.map(&%{name: &1.gift, uptie: &1.uptie, status: GiftPlans.status(progress, &1)})

        %{name: milestone["name"], reached?: GiftPlans.reached?(progress), gifts: gifts}
      end)
    else
      _ -> []
    end
  end

  attr :owned, :map, required: true
  attr :gifts_by_name, :map, required: true
  attr :show_tier, :boolean, default: false
  attr :dim, :boolean, default: false

  defp gift_tile(assigns) do
    assigns = assign(assigns, :gift, assigns.gifts_by_name[assigns.owned.name])

    ~H"""
    <div class={"relative w-9 h-9 shrink-0 rounded overflow-hidden bg-base-300 ring-1 ring-base-300 " <> if(@dim, do: "opacity-40", else: "")} title={@owned.name}>
      <img :if={@gift} src={@gift.image_path} class="w-full h-full object-cover" draggable="false" />
      <span :if={is_nil(@gift)} class="text-[8px] leading-none p-0.5 break-all"><%= @owned.name %></span>
      <span :if={@show_tier and @gift && @gift.tier} class="absolute top-0 left-0 px-0.5 text-[9px] leading-tight font-bold bg-base-100/80 rounded-br"><%= GiftPlanEditorLive.gift_tier_roman(@gift.tier) %></span>
      <img :if={@gift && @gift.affinity not in [nil, "none"]} src={GiftPlanEditorLive.gift_affinity_icon(@gift.affinity)} title={@gift.affinity} draggable="false" class="absolute bottom-0 right-0 w-3.5 h-3.5 object-contain drop-shadow" />
      <span :if={Map.get(@owned, :uptie, 0) > 0} class="absolute top-0 right-0 px-0.5 text-[11px] leading-none font-black rounded-bl bg-base-100/80" style="color: #ffb92e; text-shadow: 0 0 3px rgba(255, 160, 30, 0.9), 0 0 1px #fff3b0;"><%= uptie_marks(@owned.uptie) %></span>
      <span :if={Map.get(@owned, :count, 1) > 1} class="absolute bottom-0 left-0 px-0.5 text-[9px] leading-tight font-bold bg-base-100/80 rounded-tr">×<%= @owned.count %></span>
    </div>
    """
  end

  defp uptie_marks(level), do: String.duplicate("+", min(level, 2))

  def ego_gifts(run_memory), do: Map.get(run_memory, :ego_gifts, %{})

  def current_floor(run_memory), do: Map.get(run_memory, :floor, 1)

  def current_cost(run_memory), do: Map.get(run_memory, :cost, nil)

  def current_mode(run_memory), do: Map.get(run_memory, :mode) || RunMemory.mode_for(Map.get(run_memory, :team), current_floor(run_memory))

  defp default_picks([]), do: []
  defp default_picks([team | _]), do: [%{id: team.id, hook: Teams.pick_hook(team, nil), mode: "default", search: "default"}]

  def search_override_label("default"), do: "Default"
  def search_override_label("all"), do: "Search All"
  def search_override_label("none"), do: "Search None"

  def mode_badge_label("extreme"), do: "Ex"
  def mode_badge_label("hard_" <> floor), do: "F#{floor}"

  attr :search, :string, required: true
  attr :class, :string, default: nil

  def search_badge(assigns) do
    ~H"""
    <span title={search_override_label(@search)} class={["badge badge-sm badge-secondary px-1", @class]}>
      <.icon name={search_badge_icon(@search)} class="size-4" />
    </span>
    """
  end

  defp search_badge_icon("all"), do: "lucide-zoom-in"
  defp search_badge_icon("none"), do: "lucide-zoom-out"
  defp search_badge_icon(_), do: "lucide-search"

  def mode_override_label("default"), do: "Default"
  def mode_override_label("extreme"), do: "Extreme"
  def mode_override_label("hard_" <> floor), do: "F#{floor} Hard"

  def cycle_forecast(picks, teams) do
    key = {picks, Enum.map(teams, &{&1.id, &1.free_sinners, &1.gift_plan_id, &1.pack_plan_id})}

    case Process.get(:cycle_forecast) do
      {^key, forecast} ->
        forecast

      _ ->
        forecast = build_forecast(picks, teams)
        Process.put(:cycle_forecast, {key, forecast})
        forecast
    end
  end

  defp build_forecast(picks, teams) do
    sources = TeamBudget.sources()
    entries = for pick <- picks, team = Enum.find(teams, &(&1.id == pick.id)), do: {pick, team}

    bonuses =
      entries
      |> Enum.map(fn {pick, team} -> %{team: team.id, hook: pick.hook, free: TeamBudget.free_sinners(team)} end)
      |> RestCycle.bonuses()

    budgets =
      entries
      |> Enum.map(fn {pick, team} -> {team, pick.mode, pick.search} end)
      |> Enum.uniq_by(fn {team, mode, search} -> {team.id, mode, search} end)
      |> Map.new(fn {team, mode, search} -> {{team.id, mode, search}, TeamBudget.for_team(team, 0, [mode: mode, search: search], sources)} end)

    rows =
      for {{pick, team}, bonus} <- Enum.zip(entries, bonuses) do
        budget = Map.fetch!(budgets, {team.id, pick.mode, pick.search})
        exploration = StarlightBudget.exploration_gain(budget.floor_total, budget.railway_packs, bonus)

        lines = %{
          base: budget.income.base,
          rest: bonus,
          exploration: exploration,
          encounters: budget.income.encounters,
          grace: budget.costs.grace,
          gift_search: budget.costs.gift_search,
          pack_search: budget.costs.pack_search
        }

        %{team_id: team.id, name: team.name, hook: pick.hook, rest_bonus: bonus, net: TeamBudget.net_at(budget, bonus), lines: lines}
      end

    total = rows |> Enum.map(& &1.net) |> Enum.sum()
    %{rows: rows, total: total, average: if(rows == [], do: 0.0, else: total / length(rows))}
  end

  def signed(value), do: StarlightBudget.signed(value)

  attr :pick, :map, required: true
  attr :forecast, :map, default: nil
  attr :index, :integer, required: true
  attr :list, :string, required: true
  attr :teams, :list, required: true
  attr :locked, :boolean, required: true
  attr :live, :boolean, default: false
  attr :cycle_size, :integer, default: 1
  attr :start_index, :integer, default: 0
  attr :run_disabled, :boolean, default: false

  def pick_row(assigns) do
    assigns =
      assign(assigns,
        reserve?: assigns.list == "reserve",
        prefix: if(assigns.list == "reserve", do: "reserve", else: "team"),
        sort_id: (if assigns.list == "reserve", do: "r", else: "c") <> to_string(assigns.index),
        current?: assigns.list == "cycle" and assigns.cycle_size > 1 and assigns.index == assigns.start_index
      )

    ~H"""
    <div data-sort-id={@sort_id}
         class={"flex items-center gap-1 rounded-r px-1 " <> cond do
           @current? -> "border-l-4 border-primary bg-primary/20 ring-1 ring-primary"
           @reserve? -> "border-l-4 border-transparent"
           true -> "border-l-4 border-primary/40 bg-primary/5"
         end}>
      <span :if={not @locked} data-sort-handle class="cursor-grab text-base-content/40 px-0.5" title="Drag to move or reorder">⠿</span>
      <button :if={not @reserve? and @cycle_size > 1} type="button" phx-click="set_cycle_start" phx-value-index={@index}
              disabled={@locked or @live}
              title={if @locked or @live, do: "Locked while a run is active", else: "Start the cycle with this team"}
              class={"btn btn-ghost btn-xs px-1 " <> if(@index == @start_index, do: "text-primary", else: "text-base-content/30")}>
        <.icon name={if @index == @start_index, do: "lucide-filled-star", else: "lucide-star"} class="size-4" />
      </button>
      <span :if={not @reserve? and @cycle_size > 1} class="text-xs text-base-content/50 w-5 text-right"><%= @index + 1 %>.</span>
      <input :if={@locked} type="hidden" name={"#{@prefix}_ids[]"} value={@pick.id} />
      <input :if={@locked} type="hidden" name={"#{@prefix}_hooks[]"} value={@pick.hook} />
      <select name={"#{@prefix}_ids[]"} class="select select-sm select-bordered flex-1 min-w-0" disabled={@teams == [] or @locked}>
        <%= for team <- @teams do %>
          <option value={team.id} selected={team.id == @pick.id}><%= team.name %></option>
        <% end %>
      </select>
      <.hook_select name={"#{@prefix}_hooks[]"} hooks={team_hooks(@teams, @pick.id)} selected={@pick.hook} disabled={@teams == [] or @locked} />
      <span :if={@forecast} class="relative">
        <span title={"Expected starlight per run with #{@forecast.rest_bonus} rest bonus"}
              class={"badge badge-sm font-mono " <> if(@forecast.net >= 0, do: "badge-success", else: "badge-error")}><%= signed(@forecast.net) %></span>
        <span :if={@pick.mode != "default"} title={mode_override_label(@pick.mode)} class="badge badge-sm badge-primary font-mono absolute -top-2 -left-2 scale-75 px-1"><%= mode_badge_label(@pick.mode) %></span>
        <.search_badge :if={@pick.search != "default"} search={@pick.search} class="absolute -top-2 -right-2 scale-75" />
      </span>
      <input type="hidden" name={"#{@prefix}_modes[]"} value={@pick.mode} />
      <input type="hidden" name={"#{@prefix}_searches[]"} value={@pick.search} />
      <span :if={@pick.mode != "default" and is_nil(@forecast)} title={mode_override_label(@pick.mode)} class="badge badge-sm badge-primary font-mono"><%= mode_badge_label(@pick.mode) %></span>
      <.search_badge :if={@pick.search != "default" and is_nil(@forecast)} search={@pick.search} />
      <div class="relative" phx-click-away={Phoenix.LiveView.JS.hide(to: "##{@list}-options-#{@index}")}>
        <button type="button" phx-click={Phoenix.LiveView.JS.toggle(to: "##{@list}-options-#{@index}", display: "flex")} disabled={@locked}
                title={"Pack plan: " <> mode_override_label(@pick.mode) <> ", " <> search_override_label(@pick.search)}
                class={"btn btn-ghost btn-sm px-2 text-xl " <> if(@pick.mode == "default" and @pick.search == "default", do: "text-base-content/70", else: "text-primary")}><.icon name="lucide-settings" class="size-5" /></button>
        <div id={"#{@list}-options-#{@index}"} style="display: none" class="absolute right-0 z-20 mt-1 w-max rounded-box border border-base-300 bg-base-100 p-3 shadow flex flex-row gap-6">
          <div class="flex flex-col gap-1">
            <span class="text-xs font-semibold text-base-content/50 uppercase tracking-wide">Pack mode</span>
            <%= for mode <- Resolver.mode_overrides() do %>
              <button type="button" phx-click="set_pick_option" phx-value-list={@list} phx-value-index={@index} phx-value-key="mode" phx-value-option={mode}
                      class="flex items-center gap-2 text-sm text-left">
                <input type="radio" class="radio radio-xs radio-primary pointer-events-none" checked={mode == @pick.mode} tabindex="-1" />
                <%= mode_override_label(mode) %>
              </button>
            <% end %>
          </div>
          <div class="flex flex-col gap-1">
            <span class="text-xs font-semibold text-base-content/50 uppercase tracking-wide">Pack search</span>
            <%= for search <- Resolver.search_overrides() do %>
              <button type="button" phx-click="set_pick_option" phx-value-list={@list} phx-value-index={@index} phx-value-key="search" phx-value-option={search}
                      class="flex items-center gap-2 text-sm text-left">
                <input type="radio" class="radio radio-xs radio-primary pointer-events-none" checked={search == @pick.search} tabindex="-1" />
                <%= search_override_label(search) %>
              </button>
            <% end %>
            <button type="button" phx-click="single_run" phx-value-dry="true" phx-value-list={@list} phx-value-index={@index} disabled={@run_disabled}
                    title="One run of this team that refuses rewards"
                    class="btn btn-primary btn-xs mt-2">
              1 Dry run
            </button>
            <button type="button" phx-click="single_run" phx-value-dry="false" phx-value-list={@list} phx-value-index={@index} disabled={@run_disabled}
                    title="One run of this team using the rewards setting"
                    class="btn btn-primary btn-outline btn-xs">
              1 Rewards run
            </button>
          </div>
        </div>
      </div>
      <button :if={not @locked and (@reserve? or @cycle_size > 1)} type="button" phx-click={if @reserve?, do: "remove_reserve_team", else: "remove_cycle_team"} phx-value-index={@index}
              class="btn btn-ghost btn-xs text-error"><.icon name="lucide-x" class="size-3.5" /></button>
    </div>
    """
  end

  def team_hooks(teams, team_id), do: Enum.find_value(teams, [], &(&1.id == team_id && &1.hooks))

  def restore_form(socket, nil), do: socket

  def restore_form(socket, params) do
    picks = RunnerForms.parse_team_picks(params["team_ids"], params["team_hooks"], params["team_modes"], params["team_searches"], socket.assigns.teams, socket.assigns.picks)

    socket
    |> assign(:picks, picks)
    |> assign(:reserve, RunnerForms.parse_team_picks(params["reserve_ids"], params["reserve_hooks"], params["reserve_modes"], params["reserve_searches"], socket.assigns.teams, []))
    |> assign(:start_index, RunnerForms.parse_start_index(params["start_index"], picks))
    |> assign(:run_count, Map.get(params, "run_count", socket.assigns.run_count))
    |> assign(:rewards, restored_rewards(Map.get(params, "rewards", socket.assigns.rewards)))
    |> assign(:collect_enkephalin, Map.get(params, "collect_enkephalin") == "true")
    |> assign(:collect_xp, Map.get(params, "collect_xp") == "true")
  end

  defp restored_rewards("none"), do: "auto"
  defp restored_rewards(rewards), do: rewards

  defp save_form(socket) do
    RunnerForms.put("mirror_dungeon", form_params(socket.assigns))
    if live_cycle?(socket.assigns.phase, socket.assigns.other_running?, socket.assigns.run_kind), do: Navigator.update_cycle(socket.assigns.picks)
    socket
  end

  defp form_params(a) do
    %{
      "team_ids" => Enum.map(a.picks, &to_string(&1.id)),
      "team_hooks" => Enum.map(a.picks, & &1.hook),
      "team_modes" => Enum.map(a.picks, & &1.mode),
      "team_searches" => Enum.map(a.picks, & &1.search),
      "reserve_ids" => Enum.map(a.reserve, &to_string(&1.id)),
      "reserve_hooks" => Enum.map(a.reserve, & &1.hook),
      "reserve_modes" => Enum.map(a.reserve, & &1.mode),
      "reserve_searches" => Enum.map(a.reserve, & &1.search),
      "start_index" => to_string(a.start_index),
      "run_count" => a.run_count,
      "rewards" => a.rewards,
      "collect_enkephalin" => to_string(a.collect_enkephalin),
      "collect_xp" => to_string(a.collect_xp)
    }
  end

  defp single_pick_params(pick) do
    %{
      "team_ids" => [to_string(pick.id)],
      "team_hooks" => [pick.hook],
      "team_modes" => [pick.mode],
      "team_searches" => [pick.search],
      "start_index" => "0",
      "run_count" => "1"
    }
  end

  defp list_field("cycle"), do: :picks
  defp list_field("reserve"), do: :reserve

  defp team_slots(socket, list) do
    prefix = if list == "cycle", do: "c", else: "r"

    socket.assigns[list_field(list)]
    |> Enum.with_index()
    |> Enum.map(fn {pick, index} -> {prefix <> to_string(index), pick} end)
  end

  defp apply_team_layout(socket, ids) do
    slots = Map.new(team_slots(socket, "cycle") ++ team_slots(socket, "reserve"))
    start_id = "c" <> to_string(socket.assigns.start_index)
    {cycle_ids, reserve_ids} = Enum.split_while(ids, &(&1 != "split"))
    reserve_ids = Enum.drop(reserve_ids, 1)

    if cycle_ids != [] and Enum.count(ids, &(&1 == "split")) == 1 and Enum.sort(cycle_ids ++ reserve_ids) == Enum.sort(Map.keys(slots)) do
      socket
      |> assign(:picks, Enum.map(cycle_ids, &Map.fetch!(slots, &1)))
      |> assign(:reserve, Enum.map(reserve_ids, &Map.fetch!(slots, &1)))
      |> assign(:start_index, Enum.find_index(cycle_ids, &(&1 == start_id)) || 0)
      |> update(:reorder_rev, &(&1 + 1))
      |> save_form()
    else
      update(socket, :reorder_rev, &(&1 + 1))
    end
  end

  defp assign_picks(socket, params) do
    teams = socket.assigns.teams

    socket
    |> assign(:exp_picks, parse_picks(params["exp_team_ids"], params["exp_team_hooks"], teams, socket.assigns.exp_picks))
    |> assign(:thread_picks, parse_picks(params["thread_team_ids"], params["thread_team_hooks"], teams, socket.assigns.thread_picks))
  end

  defp parse_picks(ids, hooks, teams, fallback) do
    case RunnerForms.parse_slot_picks(ids, hooks, length(fallback)) do
      {:ok, picks} -> Enum.map(picks, &normalize_pick(&1, teams))
      :error -> fallback
    end
  end

  defp normalize_pick(nil, _teams), do: nil

  defp normalize_pick(%{id: id, hook: hook}, teams) do
    case Enum.find(teams, &(&1.id == id)) do
      nil -> nil
      team -> %{id: id, hook: Teams.pick_hook(team, hook)}
    end
  end

  defp reorder(socket, key, ids) do
    picks = Map.fetch!(socket.assigns, key)
    order = Enum.map(ids, &String.to_integer/1)

    if Enum.sort(order) == Enum.to_list(0..(length(picks) - 1)//1) do
      socket |> assign(key, Enum.map(order, &Enum.at(picks, &1))) |> save_lux_form()
    else
      socket
    end
  end

  defp restore_lux_form(socket, nil), do: socket

  defp restore_lux_form(socket, params) do
    socket
    |> assign_picks(params)
    |> assign(:then_md, params["then"] == "mirror_dungeon")
    |> assign(:exp_pin, RunnerForms.parse_pin(params["exp_pin"], LuxSchedule.exp_slot_count()))
    |> assign(:thread_pin, RunnerForms.parse_pin(params["thread_pin"], LuxSchedule.thread_slot_count()))
    |> assign(:exp_waves, Map.get(params, "exp_waves", socket.assigns.exp_waves))
    |> assign(:thread_waves, Map.get(params, "thread_waves", socket.assigns.thread_waves))
    |> assign(:lux_collect_xp, Map.get(params, "collect_xp") == "true")
    |> assign(:lux_collect_enkephalin, Map.get(params, "collect_enkephalin") == "true")
  end

  defp save_lux_form(socket) do
    a = socket.assigns

    RunnerForms.put("luxcavation", %{
      "exp_team_ids" => Enum.map(a.exp_picks, &pick_id/1),
      "exp_team_hooks" => Enum.map(a.exp_picks, &pick_hook/1),
      "thread_team_ids" => Enum.map(a.thread_picks, &pick_id/1),
      "thread_team_hooks" => Enum.map(a.thread_picks, &pick_hook/1),
      "then" => if(a.then_md, do: "mirror_dungeon", else: ""),
      "exp_pin" => to_string(a.exp_pin),
      "thread_pin" => to_string(a.thread_pin),
      "exp_waves" => a.exp_waves,
      "thread_waves" => a.thread_waves,
      "collect_xp" => to_string(a.lux_collect_xp),
      "collect_enkephalin" => to_string(a.lux_collect_enkephalin)
    })

    socket
  end

  defp start_countdown(socket, action) do
    Process.send_after(self(), :countdown_tick, 1_000)

    socket
    |> assign(:pending_action, action)
    |> assign(:countdown, @countdown_secs)
  end

  defp run_pending_action({:then, lux, md}) do
    run_pending_action(lux)
    Navigator.queue_after_run(md)
  end

  defp run_pending_action(
         {:run_luxcavation, team, exp_waves, thread_waves, collect_xp?, collect_enkephalin?, enkephalin_convert_count}
       ),
       do:
         Navigator.run_luxcavation(
           team,
           exp_waves,
           thread_waves,
           collect_xp?,
           collect_enkephalin?,
           enkephalin_convert_count
         )

  defp run_pending_action(:resume_luxcavation), do: Navigator.resume_luxcavation()

  defp run_pending_action({:run_mirror_dungeon, picks, run_count, config}),
    do: Navigator.run_mirror_dungeon(picks, run_count, config)

  defp run_pending_action(:resume_mirror_dungeon), do: Navigator.resume_mirror_dungeon()

  def pending_action_label({:run_mirror_dungeon, picks, run_count, config}) do
    suffix =
      case config.rewards do
        :none -> " (dry run, refusing rewards)"
        :claim -> ""
        :claim_weekly -> " + weekly bonuses"
        :claim_auto -> " + weekly bonuses if hard from F1"
      end
    cycle = if length(picks) > 1, do: " cycling #{length(picks)} teams", else: ""

    enkephalin =
      if Map.get(config, :collect_enkephalin?, false),
        do: " + enkephalin before each run (#{Map.get(config, :enkephalin_convert_count, 0)}x lunacy)",
        else: ""

    xp = if Map.get(config, :collect_xp?, false), do: " + battle pass xp after all runs", else: ""

    "mirror dungeon: #{run_count} run(s)#{cycle}#{suffix}#{enkephalin}#{xp}"
  end

  def pending_action_label(:resume_mirror_dungeon), do: "resume mirror dungeon"

  def pending_action_label(
        {:run_luxcavation, _team_id, exp_waves, thread_waves, collect_xp?, collect_enkephalin?, enkephalin_convert_count}
      ) do
    enkephalin_prefix = if collect_enkephalin?, do: "enkephalin (#{enkephalin_convert_count}x lunacy) + ", else: ""
    xp_suffix = if collect_xp?, do: " + battle pass xp", else: ""

    "luxcavation: #{enkephalin_prefix}#{exp_waves} exp wave(s), #{thread_waves} thread wave(s)#{xp_suffix}"
  end

  def pending_action_label({:then, lux, md}), do: pending_action_label(lux) <> ", then " <> pending_action_label(md)
  def pending_action_label(:resume_luxcavation), do: "resume luxcavation"


  defp pin_key("exp"), do: :exp_pin
  defp pin_key("thread"), do: :thread_pin

  defp pick_id(nil), do: ""
  defp pick_id(%{id: id}), do: to_string(id)

  defp pick_hook(nil), do: ""
  defp pick_hook(%{hook: hook}), do: hook || ""

  attr :id, :string, required: true
  attr :kind, :string, required: true
  attr :event, :string, required: true
  attr :picks, :list, required: true
  attr :teams, :list, required: true
  attr :labels, :list, required: true
  attr :current, :integer, required: true
  attr :auto_slot, :integer, required: true
  attr :pinned?, :boolean, required: true
  slot :icon, required: true

  def pick_list(assigns) do
    ~H"""
    <div class="relative flex items-stretch gap-1">
      <div class={["absolute inset-x-0 h-8 rounded ring-1 pointer-events-none", if(@pinned?, do: "bg-primary/10 ring-primary", else: "bg-info/10 ring-info")]}
           style={"top: #{@current * 2.25}rem"}></div>
      <div class="relative flex flex-col gap-1 shrink-0">
        <div :for={{label, index} <- Enum.with_index(@labels)} class="h-8 flex items-center gap-1 pl-1">
          <button type="button" phx-click="set_pin" phx-value-kind={@kind} phx-value-index={index}
                  title="Always use this slot's team"
                  class={"w-4 text-center " <> if(@pinned? and index == @current, do: "text-primary", else: "text-base-content/30 hover:text-primary")}>
            <.icon name={if @pinned? and index == @current, do: "lucide-filled-star", else: "lucide-star"} class="size-4" />
          </button>
          <button :if={index == @auto_slot} type="button" phx-click="clear_pin" phx-value-kind={@kind}
                  title={if(@pinned?, do: "Follow the daily schedule again", else: "Following the daily schedule")}
                  class={"btn btn-xs w-14 px-1 " <> if(@pinned?, do: "btn-ghost border border-base-content/20", else: "btn-info")}>
            {label}
          </button>
          <span :if={index != @auto_slot} class="text-xs text-base-content/60 w-14 px-1">{label}</span>
        </div>
      </div>
      <div id={@id} phx-hook="SortableList" data-sort-event={@event} class="relative flex flex-col gap-1 flex-1 min-w-0">
        <div :for={{pick, index} <- Enum.with_index(@picks)} data-sort-id={index} class="h-8 flex items-center gap-1">
          <span data-sort-handle class="cursor-grab text-base-content/40 px-0.5" title="Drag to move this team to another day">⠿</span>
          <select name={"#{@kind}_team_ids[]"} class="select select-sm select-bordered flex-1 min-w-0" disabled={@teams == []}>
            <option value="" selected={pick == nil}>None selected</option>
            <option :for={team <- @teams} value={team.id} selected={pick != nil and team.id == pick.id}>{team.name}</option>
          </select>
          <.hook_select name={"#{@kind}_team_hooks[]"} hooks={if(pick, do: team_hooks(@teams, pick.id), else: [])} selected={pick && pick.hook} disabled={@teams == []} />
        </div>
      </div>
      <div class="relative flex flex-col gap-1 shrink-0">
        <div :for={index <- 0..(length(@picks) - 1)} class="h-8 w-6 flex items-center justify-end">
          {render_slot(@icon, index)}
        </div>
      </div>
    </div>
    """
  end

  def exp_slot_label(slot), do: LuxSchedule.exp_slot_label(slot)
  def exp_slot_types(slot), do: LuxSchedule.exp_slot_types(slot)
  def thread_slot_label(slot), do: LuxSchedule.thread_slot_label(slot)
  def thread_slot_sin(slot), do: LuxSchedule.thread_slot_sin(slot)

  def active_slot("exp", nil, today), do: LuxSchedule.exp_slot(today)
  def active_slot("thread", nil, today), do: today
  def active_slot(_kind, pin, _today), do: pin

  def then_md?(then_md, md_next), do: then_md and md_next != nil

  def type_icon(type), do: "/images/affinity/#{type}.webp"

  def sin_icon(sin), do: "/images/sin/#{sin}.webp"

  @enkephalin_cumulative_costs [0, 26, 78, 156, 260]

  def enkephalin_cumulative_cost(count) when count in 0..4, do: Enum.at(@enkephalin_cumulative_costs, count)

  def total_waves(waves) do
    case Integer.parse(to_string(waves)) do
      {waves, ""} when waves >= 0 -> waves
      _ -> 0
    end
  end

  def exp_enkephalin_cost, do: @exp_enkephalin_cost
  def thread_enkephalin_cost, do: @thread_enkephalin_cost

  def module_terms(exp_waves, thread_waves) do
    [
      {"EXP", total_waves(exp_waves), @exp_enkephalin_cost},
      {"THREAD", total_waves(thread_waves), @thread_enkephalin_cost}
    ]
  end

  defdelegate modules_total(terms), to: StarlightBotWeb.Live.SchedulerLive
  defdelegate term_badge_class(label), to: StarlightBotWeb.Live.SchedulerLive

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

end
