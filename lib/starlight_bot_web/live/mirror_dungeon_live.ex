defmodule StarlightBotWeb.Live.MirrorDungeonLive do
  use StarlightBotWeb, :live_view
  import StarlightBotWeb.Components.HookSelect, only: [hook_select: 1]
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Navigation.{Navigator, RunSplits, ScreenTimes}
  alias StarlightBot.{AppSettings, EgoGifts, GiftPlans, Plans, RunHistory, RunnerForms, Teams}
  alias StarlightBot.PackPlans.Resolver
  alias StarlightBotWeb.Live.{GiftPlanEditorLive, LuxcavationLive}

  @countdown_secs 2
  @clock_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Navigator.subscribe()
      RunHistory.subscribe()
      RunnerForms.subscribe()
      Process.send_after(self(), :clock_tick, @clock_tick_ms)
    end

    nav = Navigator.status()
    teams = Teams.list_teams() |> Enum.reject(&(&1.hooks == []))

    {:ok,
     socket
     |> assign(:current_screen, nav.current_screen)
     |> assign(:phase, nav.phase)
     |> assign(:pause_requested, nav.pause_requested)
     |> assign(:other_running?, nav.run_kind == :luxcavation)
     |> assign(:run_memory, nav.run_memory)
     |> assign(:gifts_by_name, Map.new(EgoGifts.list_gifts(), &{&1.name, &1}))
     |> assign_milestones()
     |> assign_clock(times_clock(nav, :mirror_dungeon))
     |> assign(:run_splits, times_splits(nav, :mirror_dungeon))
     |> assign(:screen_times, nav.screen_times)
     |> assign(:show_screen_times, false)
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
     |> restore_form(RunnerForms.get("mirror_dungeon"))}
  end

  @impl true
  def handle_event("localize", _, socket) do
    Navigator.localize()
    {:noreply, socket}
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
  def handle_event("update_form", %{"run_count" => run_count} = params, socket) do
    socket =
      if cycle_locked?(socket.assigns.phase, socket.assigns.other_running?) do
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
      when event in ~w(add_team remove_cycle_team set_cycle_start reorder_teams set_pick_option remove_reserve_team single_run) and
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
    {:noreply, start_countdown(socket, :resume_mirror_dungeon)}
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
    {:noreply,
     socket
     |> assign(:current_screen, nav.current_screen)
     |> assign(:phase, nav.phase)
     |> assign(:pause_requested, nav.pause_requested)
     |> assign(:other_running?, nav.run_kind == :luxcavation)
     |> assign(:run_memory, nav.run_memory)
     |> assign_milestones()
     |> assign_clock(times_clock(nav, :mirror_dungeon))
     |> assign(:run_splits, times_splits(nav, :mirror_dungeon))
     |> assign(:screen_times, nav.screen_times)}
  end

  @impl true
  def handle_info({:runner_form, "mirror_dungeon"}, socket) do
    params = RunnerForms.get("mirror_dungeon") || %{}
    {:noreply, assign(socket, :start_index, RunnerForms.parse_start_index(params["start_index"], socket.assigns.picks))}
  end

  @impl true
  def handle_info({:runner_form, _runner}, socket), do: {:noreply, socket}

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

  defp assign_clock(socket, run_clock) do
    now = now_ms()
    socket |> assign(:run_clock, run_clock && Map.put(run_clock, :received_ms, now)) |> assign(:now_ms, now)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  def times_clock(%{run_times_kind: kind, run_clock: clock}, kind), do: clock
  def times_clock(_nav, _kind), do: nil

  def times_splits(%{run_times_kind: kind, run_splits: splits}, kind), do: splits
  def times_splits(_nav, _kind), do: []

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

  def cycle_locked?(phase, other_running?), do: phase != :idle and not other_running?

  def run_progress(run_memory), do: Map.get(run_memory, :run_progress)

  attr :runs, :list, required: true
  attr :live_last?, :boolean, required: true
  attr :kind, :atom, default: :mirror_dungeon

  def run_times(assigns) do
    ~H"""
    <%= if @runs == [] do %>
      <div class="text-xs text-base-content/30">No runs timed yet</div>
    <% else %>
      <%= for {run, index} <- Enum.with_index(@runs, 1) do %>
        <div class={"flex flex-col gap-0.5 rounded-lg p-1.5 " <> if(@live_last? and index == length(@runs), do: "bg-primary/10", else: "bg-base-100/50")}>
          <div class="flex items-center justify-between text-xs font-semibold">
            <span class="flex items-center gap-1 min-w-0">
              <%= run_label(@kind, run.run) %>
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
      <div class="flex items-center justify-between text-xs font-semibold border-t border-base-300 pt-1">
        <span>Total</span>
        <span class="font-mono"><%= format_elapsed(@runs |> Enum.map(& &1.ms) |> Enum.sum()) %></span>
      </div>
    <% end %>
    """
  end

  defp run_label(:luxcavation, _run), do: "Luxcavation"
  defp run_label(_kind, run), do: "Run #{run}"

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

  def run_times(splits, run_clock, now_ms, run_memory),
    do:
      RunSplits.summary(
        splits,
        elapsed_ms(run_clock, now_ms) || 0,
        Map.get(run_memory || %{}, :failed_runs, []),
        Map.get(run_memory || %{}, :picked_packs, %{})
      )

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

  def search_badge(assigns) do
    ~H"""
    <span title={search_override_label(@search)} class="badge badge-sm badge-secondary px-1">
      <svg viewBox="0 0 16 16" class="size-4" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round">
        <circle cx="6.5" cy="6.5" r="4.5" />
        <path d="M10 10 14.5 14.5" />
        <path :if={@search == "all"} d="M4.5 6.5h4M6.5 4.5v4" />
        <path :if={@search == "none"} d="M2 2 11 11" stroke-width="2" />
      </svg>
    </span>
    """
  end

  def mode_override_label("default"), do: "Default"
  def mode_override_label("extreme"), do: "Extreme"
  def mode_override_label("hard_" <> floor), do: "F#{floor} Hard"

  attr :pick, :map, required: true
  attr :index, :integer, required: true
  attr :list, :string, required: true
  attr :teams, :list, required: true
  attr :locked, :boolean, required: true
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
              disabled={@locked}
              title={if @locked, do: "Locked while a run is active", else: "Start the cycle with this team"}
              class={"btn btn-ghost btn-xs px-1 " <> if(@index == @start_index, do: "text-primary", else: "text-base-content/30")}>
        <%= if @index == @start_index, do: "★", else: "☆" %>
      </button>
      <span :if={not @reserve? and @cycle_size > 1} class="text-xs text-base-content/50 w-5 text-right"><%= @index + 1 %>.</span>
      <select name={"#{@prefix}_ids[]"} class="select select-sm select-bordered flex-1 min-w-0" disabled={@teams == [] or @locked}>
        <%= for team <- @teams do %>
          <option value={team.id} selected={team.id == @pick.id}><%= team.name %></option>
        <% end %>
      </select>
      <.hook_select name={"#{@prefix}_hooks[]"} hooks={team_hooks(@teams, @pick.id)} selected={@pick.hook} disabled={@teams == [] or @locked} />
      <input type="hidden" name={"#{@prefix}_modes[]"} value={@pick.mode} />
      <input type="hidden" name={"#{@prefix}_searches[]"} value={@pick.search} />
      <span :if={@pick.mode != "default"} title={mode_override_label(@pick.mode)} class="badge badge-sm badge-primary font-mono"><%= mode_badge_label(@pick.mode) %></span>
      <.search_badge :if={@pick.search != "default"} search={@pick.search} />
      <div class="relative" phx-click-away={Phoenix.LiveView.JS.hide(to: "##{@list}-options-#{@index}")}>
        <button type="button" phx-click={Phoenix.LiveView.JS.toggle(to: "##{@list}-options-#{@index}", display: "flex")} disabled={@locked}
                title={"Pack plan: " <> mode_override_label(@pick.mode) <> ", " <> search_override_label(@pick.search)}
                class={"btn btn-ghost btn-sm px-2 text-xl " <> if(@pick.mode == "default" and @pick.search == "default", do: "text-base-content/70", else: "text-primary")}>⚙</button>
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
              class="btn btn-ghost btn-xs text-error">✕</button>
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

  defp start_countdown(socket, action) do
    Process.send_after(self(), :countdown_tick, 1_000)

    socket
    |> assign(:pending_action, action)
    |> assign(:countdown, @countdown_secs)
  end

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
