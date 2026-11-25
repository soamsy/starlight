defmodule StarlightBotWeb.Live.PerfLive do
  use StarlightBotWeb, :live_view

  @window_ms 120_000
  @max_markers 40
  @colors ~w(stroke-primary stroke-secondary stroke-accent stroke-warning stroke-info stroke-error)
  @swatches ~w(bg-primary bg-secondary bg-accent bg-warning bg-info bg-error)
  @width 600
  @height 120

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      StarlightBot.Perf.ensure_started()
      Phoenix.PubSub.subscribe(StarlightBot.PubSub, "perf")
    end

    {:ok, assign(socket, servers: [], clients: [], markers: [], now: now(), probes: StarlightBot.Perf.probes?()), layout: false}
  end

  @impl true
  def handle_info({:perf_server, snapshot}, socket) do
    {:noreply, assign(socket, servers: trim(socket.assigns.servers ++ [snapshot], snapshot.t), now: snapshot.t)}
  end

  def handle_info({:perf_client, events}, socket) do
    {samples, markers} = Enum.split_with(events, &(&1["type"] == "sample"))
    t = now()

    {:noreply,
     assign(socket,
       clients: trim(socket.assigns.clients ++ samples, t, "at"),
       markers: Enum.take(socket.assigns.markers ++ markers, -@max_markers),
       now: t
     )}
  end

  @impl true
  def handle_event("toggle_probes", _params, socket) do
    on? = not socket.assigns.probes
    StarlightBot.Perf.set_probes(on?)
    {:noreply, assign(socket, :probes, on?)}
  end

  def handle_event("clear", _params, socket), do: {:noreply, assign(socket, servers: [], clients: [], markers: [])}

  defp now, do: System.system_time(:millisecond)

  defp trim(list, t, key \\ :t), do: Enum.filter(list, &(Map.fetch!(&1, key) >= t - @window_ms))

  defp cpu_series(servers) do
    servers
    |> Enum.flat_map(fn snap -> Enum.map(snap.procs, &{"#{&1.label} #{&1.pid}", snap.t, &1.cpu}) end)
    |> Enum.group_by(&elem(&1, 0), fn {_k, t, v} -> {t, v} end)
    |> Enum.sort_by(fn {_k, points} -> -(points |> Enum.map(&elem(&1, 1)) |> Enum.max()) end)
    |> Enum.take(length(@colors))
    |> Enum.map(fn {label, points} -> %{label: label, points: points} end)
  end

  defp client_series(clients, fields) do
    for {key, label} <- fields do
      %{label: label, points: for(c <- clients, v = c[key], is_number(v), do: {c["at"], v})}
    end
  end

  defp thread_rows(servers) do
    case List.last(servers) do
      nil -> []
      snap -> for(p <- snap.procs, {name, cpu} <- p.threads, do: {"#{p.label} #{p.pid}", name, cpu}) |> Enum.sort_by(fn {_p, _n, cpu} -> -cpu end) |> Enum.take(12)
    end
  end

  defp polyline(points, now, ymax) do
    Enum.map_join(points, " ", fn {t, v} ->
      x = (t - (now - @window_ms)) / @window_ms * @width
      y = @height - min(v / ymax, 1) * @height
      "#{Float.round(x * 1.0, 1)},#{Float.round(y * 1.0, 1)}"
    end)
  end

  defp ymax(series, floor) do
    peak = series |> Enum.flat_map(& &1.points) |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)
    max(floor, peak * 1.1)
  end

  defp last_value([]), do: "-"
  defp last_value(points), do: points |> List.last() |> elem(1) |> Kernel.*(1.0) |> Float.round(1)

  defp ago(at, now), do: "#{max(div(now - at, 1000), 0)}s"

  attr :title, :string, required: true
  attr :unit, :string, default: ""
  attr :series, :list, required: true
  attr :now, :integer, required: true
  attr :markers, :list, default: []
  attr :floor, :integer, default: 100

  defp chart(assigns) do
    assigns =
      assigns
      |> assign(:ymax, ymax(assigns.series, assigns.floor))
      |> assign(:colors, @colors)
      |> assign(:swatches, @swatches)
      |> assign(:width, @width)
      |> assign(:height, @height)
      |> assign(:window_ms, @window_ms)

    ~H"""
    <div class="rounded-box border border-base-300 bg-base-100 p-3">
      <div class="mb-1 flex items-baseline justify-between">
        <h2 class="text-sm font-semibold">{@title}</h2>
        <span class="font-mono text-xs text-base-content/50">max {Float.round(@ymax * 1.0, 1)}{@unit}</span>
      </div>
      <svg viewBox={"0 0 #{@width} #{@height}"} preserveAspectRatio="none" class="h-28 w-full rounded bg-base-200">
        <line :for={y <- [0.25, 0.5, 0.75]} x1="0" x2={@width} y1={@height * y} y2={@height * y} class="stroke-base-content/10" vector-effect="non-scaling-stroke" />
        <line
          :for={m <- @markers}
          :if={m["at"] >= @now - @window_ms}
          x1={(m["at"] - (@now - @window_ms)) / @window_ms * @width}
          x2={(m["at"] - (@now - @window_ms)) / @window_ms * @width}
          y1="0"
          y2={@height}
          class="stroke-base-content/30"
          stroke-dasharray="3 3"
          vector-effect="non-scaling-stroke"
        />
        <polyline
          :for={{s, i} <- Enum.with_index(@series)}
          points={polyline(s.points, @now, @ymax)}
          fill="none"
          class={[Enum.at(@colors, i), "stroke-2"]}
          vector-effect="non-scaling-stroke"
        />
      </svg>
      <div class="mt-2 flex flex-wrap gap-x-4 gap-y-1 font-mono text-xs">
        <span :for={{s, i} <- Enum.with_index(@series)} class="flex items-center gap-1">
          <span class={["inline-block size-2 rounded-full", Enum.at(@swatches, i)]}></span>
          {s.label} {last_value(s.points)}{@unit}
        </span>
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:cpu, cpu_series(assigns.servers))
      |> assign(:threads, thread_rows(assigns.servers))
      |> assign(:click_markers, Enum.filter(assigns.markers, &(&1["kind"] == "click")))
      |> assign(:fps, client_series(assigns.clients, [{"fps", "fps"}]))
      |> assign(:latency, client_series(assigns.clients, [{"frameMax", "frame max"}, {"lag", "loop lag"}, {"evMax", "input event"}]))
      |> assign(:patch, client_series(assigns.clients, [{"patchMax", "patch js"}, {"paintMax", "patch to paint"}]))
      |> assign(:beam, [
        %{label: "normal", points: for(s <- assigns.servers, do: {s.t, s.sched})},
        %{label: "max", points: for(s <- assigns.servers, do: {s.t, s.sched_max})}
      ])

    ~H"""
    <div class="min-h-screen bg-base-200 p-4">
      <div class="mb-4 flex items-center gap-3">
        <h1 class="text-lg font-semibold">Client performance</h1>
        <span class="text-xs text-base-content/50">last 2 min, dashed lines are clicks</span>
        <div class="ml-auto flex gap-2">
          <button type="button" phx-click="toggle_probes" class={["btn btn-sm", @probes && "btn-primary"]}>
            <.icon name="lucide-activity" class="size-4" />
            Client probes {if @probes, do: "on", else: "off"}
          </button>
          <button type="button" phx-click="clear" class="btn btn-sm btn-ghost">
            <.icon name="lucide-trash-2" class="size-4" /> Clear
          </button>
        </div>
      </div>

      <p :if={@servers != [] and Enum.all?(@servers, &(&1.procs == []))} class="alert alert-warning mb-4 text-sm">
        No process named "starlight" found. Launch the Tauri app so its WebKit processes can be sampled.
      </p>

      <div class="grid gap-4 lg:grid-cols-2">
        <.chart title="Process CPU (100 = one core)" unit="%" series={@cpu} now={@now} markers={@click_markers} />
        <.chart title="Frame rate while interacting" series={@fps} now={@now} markers={@click_markers} floor={60} />
        <.chart title="Main thread latency" unit="ms" series={@latency} now={@now} markers={@click_markers} floor={50} />
        <.chart title="LiveView patch cost" unit="ms" series={@patch} now={@now} markers={@click_markers} floor={50} />
        <.chart title="BEAM scheduler load" unit="%" series={@beam} now={@now} markers={@click_markers} />

        <div class="rounded-box border border-base-300 bg-base-100 p-3">
          <h2 class="mb-1 text-sm font-semibold">Busiest threads now</h2>
          <table class="table table-xs font-mono">
            <tbody>
              <tr :for={{proc, name, cpu} <- @threads}>
                <td>{proc}</td>
                <td>{name}</td>
                <td class="text-right">{cpu}%</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <div class="mt-4 rounded-box border border-base-300 bg-base-100 p-3">
        <h2 class="mb-1 text-sm font-semibold">Interactions</h2>
        <table class="table table-xs font-mono">
          <tbody>
            <tr :for={m <- @markers |> Enum.reverse() |> Enum.take(15)} class={m["kind"] == "stall" && "text-warning"}>
              <td class="w-16">{ago(m["at"], @now)}</td>
              <td class="w-16">{m["kind"]}</td>
              <td>{m["label"]}</td>
              <td class="text-right">{if m["ms"] > 0, do: "#{m["ms"]}ms"}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
