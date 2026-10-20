defmodule StarlightBotWeb.Live.MirrorDungeonLive do
  use StarlightBotWeb, :live_view
  alias StarlightBot.Automation.{EnkephalinCharger, RunMemory}
  alias StarlightBot.Navigation.{Navigator, RunSplits, ScreenTimes}
  alias StarlightBot.{RunHistory, Teams}
  alias StarlightBotWeb.Live.LuxcavationLive

  @countdown_secs 2
  @clock_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Navigator.subscribe()
      RunHistory.subscribe()
      Process.send_after(self(), :clock_tick, @clock_tick_ms)
    end

    nav = Navigator.status()
    teams = Teams.list_teams() |> Enum.reject(&(&1.hook in [nil, ""]))

    {:ok,
     socket
     |> assign(:current_screen, nav.current_screen)
     |> assign(:phase, nav.phase)
     |> assign(:pause_requested, nav.pause_requested)
     |> assign(:other_running?, nav.run_kind == :luxcavation)
     |> assign(:log, nav.log)
     |> assign(:run_memory, nav.run_memory)
     |> assign_clock(nav.run_clock)
     |> assign(:run_splits, nav.run_splits)
     |> assign(:screen_times, nav.screen_times)
     |> assign(:show_screen_times, false)
     |> assign(:screen_view, "breakdown")
     |> assign(:screen_source, "live")
     |> assign(:screen_filter, %{run: nil, floor: nil})
     |> assign(:history_runs, [])
     |> assign(:history_segments, [])
     |> assign(:teams, teams)
     |> assign(:team_ids, default_team_ids(teams))
     |> assign(:start_index, 0)
     |> assign(:run_count, "1")
     |> assign(:weekly_bonus, true)
     |> assign(:collect_enkephalin, false)
     |> assign(:collect_xp, false)
     |> assign(:capture_ego_gifts, false)
     |> assign(:enkephalin_convert_count, "0")
     |> assign(:pending_action, nil)
     |> assign(:countdown, nil)}
  end

  @impl true
  def handle_event("localize", _, socket) do
    Navigator.localize()
    {:noreply, socket}
  end

  @impl true
  def handle_event("run", params, socket) do
    case run_action(params, socket.assigns.teams) do
      {:ok, action} -> {:noreply, start_countdown(socket, action)}
      :error -> {:noreply, put_flash(socket, :error, "Pick at least one team and enter a non-negative run count.")}
    end
  end

  @impl true
  def handle_event("update_form", %{"run_count" => run_count} = params, socket) do
    team_ids = parse_team_ids(params["team_ids"], socket.assigns.teams, socket.assigns.team_ids)

    {:noreply,
     socket
     |> assign(:team_ids, team_ids)
     |> assign(:start_index, parse_start_index(params["start_index"], team_ids))
     |> assign(:run_count, run_count)
     |> assign(:weekly_bonus, Map.get(params, "weekly_bonus") == "true")
     |> assign(:collect_enkephalin, Map.get(params, "collect_enkephalin") == "true")
     |> assign(:collect_xp, Map.get(params, "collect_xp") == "true")
     |> assign(:enkephalin_convert_count, Map.get(params, "enkephalin_convert_count", socket.assigns.enkephalin_convert_count))}
  end

  @impl true
  def handle_event("restore_form", params, socket) do
    team_ids = parse_team_ids(params["team_ids[]"], socket.assigns.teams, socket.assigns.team_ids)

    {:noreply,
     socket
     |> assign(:team_ids, team_ids)
     |> assign(:start_index, parse_start_index(params["start_index"], team_ids))
     |> assign(:run_count, Map.get(params, "run_count", socket.assigns.run_count))
     |> assign(:weekly_bonus, Map.get(params, "weekly_bonus") == "true")
     |> assign(:collect_enkephalin, Map.get(params, "collect_enkephalin") == "true")
     |> assign(:collect_xp, Map.get(params, "collect_xp") == "true")
     |> assign(:enkephalin_convert_count, Map.get(params, "enkephalin_convert_count", socket.assigns.enkephalin_convert_count))}
  end

  @impl true
  def handle_event("add_cycle_team", _, socket) do
    {:noreply, assign(socket, :team_ids, socket.assigns.team_ids ++ Enum.take(socket.assigns.team_ids, -1))}
  end

  @impl true
  def handle_event("remove_cycle_team", %{"index" => index}, socket) do
    %{team_ids: team_ids, start_index: start} = socket.assigns
    index = String.to_integer(index)

    if length(team_ids) > 1 do
      team_ids = List.delete_at(team_ids, index)
      start = if index < start, do: start - 1, else: min(start, length(team_ids) - 1)
      {:noreply, socket |> assign(:team_ids, team_ids) |> assign(:start_index, start)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set_cycle_start", %{"index" => index}, socket) do
    {:noreply, assign(socket, :start_index, parse_start_index(index, socket.assigns.team_ids))}
  end

  @impl true
  def handle_event("reorder_cycle", %{"ids" => ids}, socket) do
    %{team_ids: team_ids, start_index: start} = socket.assigns
    order = Enum.map(ids, &String.to_integer/1)

    if Enum.sort(order) == Enum.to_list(0..(length(team_ids) - 1)//1) do
      {:noreply,
       socket
       |> assign(:team_ids, Enum.map(order, &Enum.at(team_ids, &1)))
       |> assign(:start_index, Enum.find_index(order, &(&1 == start)))}
    else
      {:noreply, socket}
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
     |> assign(:log, nav.log)
     |> assign(:run_memory, nav.run_memory)
     |> assign_clock(nav.run_clock)
     |> assign(:run_splits, nav.run_splits)
     |> assign(:screen_times, nav.screen_times)}
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

  defp assign_clock(socket, run_clock) do
    now = now_ms()
    socket |> assign(:run_clock, run_clock && Map.put(run_clock, :received_ms, now)) |> assign(:now_ms, now)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

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

  def run_progress(run_memory), do: Map.get(run_memory, :run_progress)

  attr :runs, :list, required: true
  attr :live_last?, :boolean, required: true

  def run_times(assigns) do
    ~H"""
    <%= if @runs == [] do %>
      <div class="text-xs text-base-content/30">No runs timed yet</div>
    <% else %>
      <%= for {run, index} <- Enum.with_index(@runs, 1) do %>
        <div class={"flex flex-col gap-0.5 rounded-lg p-1.5 " <> if(@live_last? and index == length(@runs), do: "bg-primary/10", else: "bg-base-100/50")}>
          <div class="flex items-center justify-between text-xs font-semibold">
            <span class="flex items-center gap-1 min-w-0">
              Run <%= run.run %>
              <span :if={run.team} class="font-normal text-base-content/60 truncate"><%= run.team %></span>
              <span :if={run.failed?} class="badge badge-error badge-xs">failed</span>
            </span>
            <span class="font-mono"><%= format_elapsed(run.ms) %></span>
          </div>
          <div :for={floor <- run.floors} class="flex items-center justify-between gap-2 text-[11px] text-base-content/60 pl-2">
            <span class="flex items-center gap-1 min-w-0">
              <span class="shrink-0">Floor <%= floor.floor %></span>
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

  def ego_gifts(run_memory), do: Map.get(run_memory, :ego_gifts, %{})

  def current_floor(run_memory), do: Map.get(run_memory, :floor, 1)

  def current_cost(run_memory), do: Map.get(run_memory, :cost, nil)

  def current_mode(run_memory), do: Map.get(run_memory, :mode) || RunMemory.mode_for(Map.get(run_memory, :team), current_floor(run_memory))

  defp default_team_ids([]), do: []
  defp default_team_ids([%{id: id} | _]), do: [id]

  def parse_start_index(value, team_ids) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n >= 0 and n < length(team_ids) -> n
      _ -> 0
    end
  end

  def run_action(params, teams) do
    team_ids = parse_team_ids(params["team_ids"] || params["team_ids[]"], teams)
    start = parse_start_index(params["start_index"], team_ids)
    team_ids = Enum.drop(team_ids, start) ++ Enum.take(team_ids, start)

    with [_ | _] <- team_ids,
         {run_count, ""} <- Integer.parse(to_string(params["run_count"])),
         true <- run_count >= 0,
         {convert_count, ""} <- Integer.parse(to_string(params["enkephalin_convert_count"] || "0")),
         true <- convert_count in 0..EnkephalinCharger.max_convert_count() do
      config = %{
        weekly_bonus?: Map.get(params, "weekly_bonus") == "true",
        collect_enkephalin?: Map.get(params, "collect_enkephalin") == "true",
        collect_xp?: Map.get(params, "collect_xp") == "true",
        enkephalin_convert_count: convert_count
      }

      {:ok, {:run_mirror_dungeon, team_ids, run_count, config}}
    else
      _ -> :error
    end
  end

  def parse_team_ids(values, teams, fallback \\ []) do
    known = MapSet.new(teams, & &1.id)

    values
    |> List.wrap()
    |> Enum.flat_map(fn value ->
      case Integer.parse(to_string(value)) do
        {id, ""} -> if MapSet.member?(known, id), do: [id], else: []
        _ -> []
      end
    end)
    |> case do
      [] -> fallback
      ids -> ids
    end
  end

  defp start_countdown(socket, action) do
    Process.send_after(self(), :countdown_tick, 1_000)

    socket
    |> assign(:pending_action, action)
    |> assign(:countdown, @countdown_secs)
  end

  defp run_pending_action({:run_mirror_dungeon, team_ids, run_count, config}),
    do: Navigator.run_mirror_dungeon(team_ids, run_count, config)

  defp run_pending_action(:resume_mirror_dungeon), do: Navigator.resume_mirror_dungeon()

  def pending_action_label({:run_mirror_dungeon, team_ids, run_count, config}) do
    suffix = if config.weekly_bonus?, do: " + weekly bonuses", else: ""
    cycle = if length(team_ids) > 1, do: " cycling #{length(team_ids)} teams", else: ""

    enkephalin =
      if Map.get(config, :collect_enkephalin?, false),
        do: " + enkephalin before each run (#{Map.get(config, :enkephalin_convert_count, 0)}x lunacy)",
        else: ""

    xp = if Map.get(config, :collect_xp?, false), do: " + battle pass xp after all runs", else: ""

    capture = if Map.get(config, :capture_ego_gifts?, false), do: " + ego gift captures", else: ""

    "mirror dungeon: #{run_count} run(s)#{cycle}#{suffix}#{enkephalin}#{xp}#{capture}"
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
