defmodule StarlightBotWeb.Live.LuxcavationLive do
  use StarlightBotWeb, :live_view
  import StarlightBotWeb.Components.HookSelect, only: [hook_select: 1]
  alias StarlightBot.Navigation.Navigator
  alias StarlightBotWeb.Live.MirrorDungeonLive
  alias StarlightBot.{LuxSchedule, RunnerForms, Teams}

  @countdown_secs 2
  @day_tick_ms 60_000
  @clock_tick_ms 1_000
  @exp_enkephalin_cost 3
  @thread_enkephalin_cost 2

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Navigator.subscribe()
      RunnerForms.subscribe()
      Process.send_after(self(), :day_tick, @day_tick_ms)
      Process.send_after(self(), :clock_tick, @clock_tick_ms)
    end

    nav = Navigator.status()
    teams = Teams.list_teams() |> Enum.reject(&(&1.hooks == []))

    {:ok,
     socket
     |> assign(:current_screen, nav.current_screen)
     |> assign(:phase, nav.phase)
     |> assign(:pause_requested, nav.pause_requested)
     |> assign(:other_running?, nav.run_kind == :mirror_dungeon)
     |> assign_clock(MirrorDungeonLive.times_clock(nav, :luxcavation))
     |> assign(:run_splits, MirrorDungeonLive.times_splits(nav, :luxcavation))
     |> assign(:teams, teams)
     |> assign(:today, LuxSchedule.today())
     |> assign(:exp_pin, nil)
     |> assign(:thread_pin, nil)
     |> assign(:exp_picks, List.duplicate(nil, LuxSchedule.exp_slot_count()))
     |> assign(:thread_picks, List.duplicate(nil, LuxSchedule.thread_slot_count()))
     |> assign(:exp_waves, "1")
     |> assign(:thread_waves, "3")
     |> assign(:collect_xp, true)
     |> assign(:collect_enkephalin, true)
     |> assign(:md_next, RunnerForms.mirror_dungeon_action())
     |> assign(:then_md, false)
     |> assign(:pending_action, nil)
     |> assign(:countdown, nil)
     |> restore_form(RunnerForms.get("luxcavation"))}
  end

  @impl true
  def handle_event("localize", _, socket) do
    Navigator.localize()
    {:noreply, socket}
  end

  @impl true
  def handle_event("run", params, socket) do
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
        {:noreply,
         put_flash(
           socket,
           :error,
           "Pick a team for today's slots, and keep waves non-negative."
         )}
    end
  end

  @impl true
  def handle_event(
        "update_form",
        %{
          "exp_waves" => exp_waves,
          "thread_waves" => thread_waves
        } = params,
        socket
      ) do
    {:noreply,
     socket
     |> assign_picks(params)
     |> assign(:then_md, params["then"] == "mirror_dungeon")
     |> assign(:exp_waves, exp_waves)
     |> assign(:thread_waves, thread_waves)
     |> assign(:collect_xp, Map.get(params, "collect_xp") == "true")
     |> assign(:collect_enkephalin, Map.get(params, "collect_enkephalin") == "true")
     |> save_form()}
  end

  @impl true
  def handle_event("toggle_pin", %{"kind" => kind}, socket) do
    key = pin_key(kind)
    pin = if socket.assigns[key] == nil, do: active_slot(kind, nil, socket.assigns.today)
    {:noreply, socket |> assign(key, pin) |> save_form()}
  end

  @impl true
  def handle_event("set_pin", %{"kind" => kind, "index" => index}, socket) do
    count = if kind == "exp", do: LuxSchedule.exp_slot_count(), else: LuxSchedule.thread_slot_count()
    {:noreply, socket |> assign(pin_key(kind), RunnerForms.parse_pin(index, count)) |> save_form()}
  end

  @impl true
  def handle_event("reorder_exp", %{"ids" => ids}, socket), do: {:noreply, reorder(socket, :exp_picks, ids)}

  @impl true
  def handle_event("reorder_thread", %{"ids" => ids}, socket), do: {:noreply, reorder(socket, :thread_picks, ids)}

  @impl true
  def handle_event("resume", _, socket) do
    {:noreply, start_countdown(socket, :resume_luxcavation)}
  end

  @impl true
  def handle_event("pause", _, socket) do
    Navigator.pause()
    {:noreply, socket}
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
  def handle_info(:day_tick, socket) do
    Process.send_after(self(), :day_tick, @day_tick_ms)
    {:noreply, assign(socket, :today, LuxSchedule.today())}
  end

  @impl true
  def handle_info({:nav_state, nav}, socket) do
    {:noreply,
     socket
     |> assign(:current_screen, nav.current_screen)
     |> assign(:phase, nav.phase)
     |> assign(:pause_requested, nav.pause_requested)
     |> assign(:other_running?, nav.run_kind == :mirror_dungeon)
     |> assign_clock(MirrorDungeonLive.times_clock(nav, :luxcavation))
     |> assign(:run_splits, MirrorDungeonLive.times_splits(nav, :luxcavation))}
  end

  @impl true
  def handle_info({:runner_form, "mirror_dungeon"}, socket), do: {:noreply, assign(socket, :md_next, RunnerForms.mirror_dungeon_action())}
  def handle_info({:runner_form, _runner}, socket), do: {:noreply, socket}

  def handle_info(:clock_tick, socket) do
    Process.send_after(self(), :clock_tick, @clock_tick_ms)

    case socket.assigns.run_clock do
      %{running?: true} -> {:noreply, assign(socket, :now_ms, System.monotonic_time(:millisecond))}
      _ -> {:noreply, socket}
    end
  end

  defp assign_clock(socket, run_clock) do
    now = System.monotonic_time(:millisecond)
    socket |> assign(:run_clock, run_clock && Map.put(run_clock, :received_ms, now)) |> assign(:now_ms, now)
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
      socket |> assign(key, Enum.map(order, &Enum.at(picks, &1))) |> save_form()
    else
      socket
    end
  end

  defp restore_form(socket, nil), do: socket

  defp restore_form(socket, params) do
    socket
    |> assign_picks(params)
    |> assign(:then_md, params["then"] == "mirror_dungeon")
    |> assign(:exp_pin, RunnerForms.parse_pin(params["exp_pin"], LuxSchedule.exp_slot_count()))
    |> assign(:thread_pin, RunnerForms.parse_pin(params["thread_pin"], LuxSchedule.thread_slot_count()))
    |> assign(:exp_waves, Map.get(params, "exp_waves", socket.assigns.exp_waves))
    |> assign(:thread_waves, Map.get(params, "thread_waves", socket.assigns.thread_waves))
    |> assign(:collect_xp, Map.get(params, "collect_xp") == "true")
    |> assign(:collect_enkephalin, Map.get(params, "collect_enkephalin") == "true")
  end

  defp save_form(socket) do
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
      "collect_xp" => to_string(a.collect_xp),
      "collect_enkephalin" => to_string(a.collect_enkephalin)
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

  def pending_action_label(
        {:run_luxcavation, _team_id, exp_waves, thread_waves, collect_xp?, collect_enkephalin?, enkephalin_convert_count}
      ) do
    enkephalin_prefix = if collect_enkephalin?, do: "enkephalin (#{enkephalin_convert_count}x lunacy) + ", else: ""
    xp_suffix = if collect_xp?, do: " + battle pass xp", else: ""

    "luxcavation: #{enkephalin_prefix}#{exp_waves} exp wave(s), #{thread_waves} thread wave(s)#{xp_suffix}"
  end

  def pending_action_label({:then, lux, md}), do: pending_action_label(lux) <> ", then " <> MirrorDungeonLive.pending_action_label(md)
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
  attr :pinned?, :boolean, required: true
  slot :icon, required: true

  def pick_list(assigns) do
    ~H"""
    <div class="relative flex items-stretch gap-1">
      <div class="absolute inset-x-0 h-8 rounded bg-primary/10 ring-1 ring-primary pointer-events-none"
           style={"top: #{@current * 2.25}rem"}></div>
      <div class="relative flex flex-col gap-1 shrink-0">
        <div :for={{label, index} <- Enum.with_index(@labels)} class="h-8 flex items-center gap-1 pl-1">
          <button :if={@pinned?} type="button" phx-click="set_pin" phx-value-kind={@kind} phx-value-index={index}
                  title="Always use this slot's team"
                  class={"w-4 text-center " <> if(index == @current, do: "text-primary", else: "text-base-content/30 hover:text-primary")}>
            {if index == @current, do: "★", else: "☆"}
          </button>
          <span :if={not @pinned?} class={"w-4 text-center " <> if(index == @current, do: "text-primary", else: "text-transparent")}>★</span>
          <span class="text-xs text-base-content/60 w-14">{label}</span>
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

  def pin_title(nil), do: "Locked: follows the daily schedule. Unlock to choose the team yourself."
  def pin_title(_pin), do: "Unlocked: always uses the starred slot, whatever the day. Click to follow the daily schedule again."

  def type_icon(type), do: "/images/affinity/#{type}.webp"

  def sin_icon(sin), do: "/images/sin/#{sin}.webp"

  def team_hooks(teams, team_id), do: Enum.find_value(teams, [], &(&1.id == team_id && &1.hooks))

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

  def phase_label(:idle), do: nil
  def phase_label(:localizing), do: "Localizing…"
  def phase_label(:running), do: "Running…"
  def phase_label(:paused), do: "Paused"

end
