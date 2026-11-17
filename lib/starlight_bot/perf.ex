defmodule StarlightBot.Perf do
  use GenServer

  @path Path.join(System.tmp_dir!(), "starlight_perf.log")
  @sample_ms 40
  @report_ms 1000
  @profile_every 5
  @long_log_cap 20
  @mailbox_threshold 50
  @tracked [StarlightBotWeb.Live.RunnerLive, StarlightBotWeb.Live.LogLive]
  @events [
    [:phoenix, :live_view, :mount, :stop],
    [:phoenix, :live_view, :render, :stop],
    [:phoenix, :live_view, :handle_event, :stop],
    [:phoenix, :endpoint, :stop]
  ]

  def path, do: @path

  def ensure_started do
    if Application.get_env(:starlight_bot, :dev_js_log, false) and is_nil(Process.whereis(__MODULE__)) do
      GenServer.start(__MODULE__, nil, name: __MODULE__)
    end

    :ok
  end

  def client(line), do: GenServer.cast(__MODULE__, {:client, line})

  def handle_telemetry([:phoenix, :live_view, :mount, :stop], _measure, %{socket: %{view: view}}, _config),
    do: GenServer.cast(__MODULE__, {:mount, self(), view})

  def handle_telemetry([:phoenix, :live_view, :render, :stop], %{duration: d}, %{socket: %{view: view}, changed?: changed?}, _config),
    do: GenServer.cast(__MODULE__, {:render, view, us(d), changed?})

  def handle_telemetry([:phoenix, :live_view, :handle_event, :stop], %{duration: d}, %{socket: %{view: view}, event: event}, _config),
    do: GenServer.cast(__MODULE__, {:event, {view, event}, us(d)})

  def handle_telemetry([:phoenix, :endpoint, :stop], %{duration: d}, %{conn: conn}, _config),
    do: GenServer.cast(__MODULE__, {:request, conn.request_path, us(d)})

  def handle_telemetry(_event, _measure, _meta, _config), do: :ok

  defp us(native), do: System.convert_time_unit(native, :native, :microsecond)

  @impl true
  def init(nil) do
    File.write!(@path, "")
    :erlang.system_flag(:scheduler_wall_time, true)
    :erlang.system_monitor(self(), [{:long_schedule, 30}, {:long_gc, 30}, {:large_heap, 20_000_000}])
    :telemetry.attach_many("starlight-perf", @events, &__MODULE__.handle_telemetry/4, nil)
    Process.send_after(self(), :sample, @sample_ms)
    Process.send_after(self(), :report, @report_ms)

    {:ok,
     %{
       pids: %{},
       wall: :erlang.statistics(:scheduler_wall_time_all),
       reds: %{},
       ticks: 0,
       longs: 0,
       mailbox: nil,
       renders: %{},
       renders_changed: %{},
       events: %{},
       requests: %{},
       busy: %{},
       samples: %{},
       queue_max: %{},
       leaf: %{},
       app: %{}
     }}
  end

  @impl true
  def handle_cast({:mount, pid, view}, state), do: {:noreply, put_in(state.pids[pid], view)}
  def handle_cast({:render, view, us, changed?}, state), do: {:noreply, %{state | renders: bump(state.renders, view, us), renders_changed: if(changed?, do: bump(state.renders_changed, view, us), else: state.renders_changed)}}
  def handle_cast({:event, key, us}, state), do: {:noreply, %{state | events: bump(state.events, key, us)}}
  def handle_cast({:request, path, us}, state), do: {:noreply, %{state | requests: bump(state.requests, path, us)}}

  def handle_cast({:client, line}, state) do
    write("client " <> line)
    {:noreply, state}
  end

  @impl true
  def handle_info({:monitor, pid, type, info}, state) do
    if state.longs < @long_log_cap do
      view = state.pids[pid]
      write("LONG #{type} pid=#{inspect(pid)} view=#{inspect(view)} info=#{inspect(info)} now=#{inspect(Process.info(pid, :current_function))}")
    end

    {:noreply, %{state | longs: state.longs + 1}}
  end

  def handle_info(:sample, state) do
    Process.send_after(self(), :sample, @sample_ms)
    {:noreply, sample(state)}
  end

  def handle_info(:report, state) do
    Process.send_after(self(), :report, @report_ms)
    {:noreply, report(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp sample(state) do
    Enum.reduce(state.pids, state, fn {pid, view}, acc ->
      with true <- view in @tracked,
           [{:current_stacktrace, stack}, {:message_queue_len, queue}, {:status, status}] <-
             Process.info(pid, [:current_stacktrace, :message_queue_len, :status]) do
        acc
        |> update_in([:samples, Access.key(view, 0)], &(&1 + 1))
        |> update_in([:queue_max, Access.key(view, 0)], &max(&1, queue))
        |> record_busy(view, status, stack)
        |> maybe_mailbox(pid, view, queue)
      else
        _ -> acc
      end
    end)
  end

  defp record_busy(state, _view, :waiting, _stack), do: state

  defp record_busy(state, view, _status, stack) do
    leaf = stack |> List.first() |> frame()
    app = stack |> Enum.find(fn {mod, _f, _a, _loc} -> String.starts_with?(Atom.to_string(mod), "Elixir.StarlightBot") end) |> frame()

    state
    |> update_in([:busy, Access.key(view, 0)], &(&1 + 1))
    |> update_in([:leaf, Access.key({view, leaf}, 0)], &(&1 + 1))
    |> update_in([:app, Access.key({view, app}, 0)], &(&1 + 1))
  end

  defp maybe_mailbox(%{mailbox: nil} = state, pid, view, queue) when queue > @mailbox_threshold do
    case Process.info(pid, :messages) do
      {:messages, messages} -> %{state | mailbox: {view, queue, messages |> Enum.map(&tag/1) |> Enum.frequencies()}}
      nil -> state
    end
  end

  defp maybe_mailbox(state, _pid, _view, _queue), do: state

  defp tag(message) when is_tuple(message) and tuple_size(message) > 0, do: {elem(message, 0), tuple_size(message)}
  defp tag(message) when is_atom(message), do: message
  defp tag(_message), do: :other

  defp frame(nil), do: nil
  defp frame({mod, fun, arity, loc}), do: "#{inspect(mod)}.#{fun}/#{arity}:#{loc[:line]}"

  defp report(state) do
    wall = :erlang.statistics(:scheduler_wall_time_all)
    {normal, max_normal, dirty_cpu} = utilization(state.wall, wall)
    {reds, state} = reductions(state)
    stamp = Time.utc_now() |> Time.truncate(:millisecond) |> Time.to_string()

    lines =
      [
        "#{stamp} sched normal=#{normal}% max=#{max_normal}% dirty_cpu=#{dirty_cpu}% runq=#{:erlang.statistics(:run_queue)} longs=#{state.longs}",
        "  procs " <> Enum.map_join(@tracked, " | ", &proc_summary(&1, state, reds)),
        "  renders " <> stats_line(state.renders) <> " changed " <> stats_line(state.renders_changed),
        "  events " <> stats_line(state.events),
        "  requests " <> stats_line(state.requests)
      ] ++ mailbox_line(state.mailbox)

    write(Enum.join(lines, "\n"))
    ticks = state.ticks + 1
    if rem(ticks, @profile_every) == 0, do: write_profile(state)

    reset = %{renders: %{}, renders_changed: %{}, events: %{}, requests: %{}, busy: %{}, samples: %{}, queue_max: %{}, mailbox: nil, longs: 0}
    reset = if rem(ticks, @profile_every) == 0, do: Map.merge(reset, %{leaf: %{}, app: %{}}), else: reset
    state |> Map.merge(reset) |> Map.merge(%{wall: wall, ticks: ticks})
  end

  defp utilization(before, now) do
    normal_count = :erlang.system_info(:schedulers)
    cpu_count = :erlang.system_info(:dirty_cpu_schedulers)
    old = Map.new(before, fn {id, active, total} -> {id, {active, total}} end)

    ratios =
      for {id, active, total} <- now, {oa, ot} = Map.get(old, id, {0, 0}), total > ot, do: {id, (active - oa) / (total - ot)}

    normal = for {id, r} <- ratios, id <= normal_count, do: r
    dirty = for {id, r} <- ratios, id > normal_count, id <= normal_count + cpu_count, do: r
    {pct(avg(normal)), pct(Enum.max(normal, fn -> 0 end)), pct(avg(dirty))}
  end

  defp avg([]), do: 0
  defp avg(list), do: Enum.sum(list) / length(list)
  defp pct(ratio), do: round(ratio * 100)

  defp reductions(state) do
    current =
      for {pid, view} <- state.pids, view in @tracked, {:reductions, r} <- [Process.info(pid, :reductions)], into: %{}, do: {pid, r}

    delta = for {pid, r} <- current, into: %{}, do: {pid, r - Map.get(state.reds, pid, r)}
    {delta, %{state | reds: current, pids: Map.filter(state.pids, fn {pid, _} -> Process.alive?(pid) end)}}
  end

  defp proc_summary(view, state, reds) do
    samples = Map.get(state.samples, view, 0)
    busy = Map.get(state.busy, view, 0)
    pids = for {pid, v} <- state.pids, v == view, do: pid
    red = pids |> Enum.map(&Map.get(reds, &1, 0)) |> Enum.sum()
    name = view |> Module.split() |> List.last()
    "#{name} n=#{length(pids)} busy=#{if samples == 0, do: 0, else: round(busy * 100 / samples)}% qmax=#{Map.get(state.queue_max, view, 0)} reds=#{div(red, 1000)}k"
  end

  defp stats_line(map) when map_size(map) == 0, do: "-"

  defp stats_line(map) do
    map
    |> Enum.sort_by(fn {_key, {_count, total, _max}} -> -total end)
    |> Enum.take(6)
    |> Enum.map_join(" ", fn {key, {count, total, max}} -> "#{label(key)}=#{count}x avg#{fmt(div(total, count))} max#{fmt(max)}" end)
  end

  defp label({view, event}), do: "#{view |> Module.split() |> List.last()}.#{event}"
  defp label(view) when is_atom(view), do: view |> Module.split() |> List.last()
  defp label(path), do: path

  defp fmt(us), do: "#{Float.round(us / 1000, 1)}ms"

  defp bump(map, key, us) do
    Map.update(map, key, {1, us, us}, fn {count, total, max} -> {count + 1, total + us, max(max, us)} end)
  end

  defp mailbox_line(nil), do: []
  defp mailbox_line({view, queue, tags}), do: ["  mailbox #{inspect(view)} len=#{queue} #{inspect(Enum.sort_by(tags, fn {_k, v} -> -v end) |> Enum.take(8))}"]

  defp write_profile(state) do
    top = fn map -> map |> Enum.sort_by(fn {_k, v} -> -v end) |> Enum.take(8) |> Enum.map_join("\n", fn {{view, fr}, n} -> "    #{n} #{inspect(view)} #{fr}" end) end
    write("  PROFILE busy leaf frames\n#{top.(state.leaf)}\n  PROFILE busy first app frames\n#{top.(state.app)}")
  end

  defp write(text), do: File.write(@path, text <> "\n", [:append])
end
