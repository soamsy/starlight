defmodule StarlightBotWeb.Live.LogLive do
  use StarlightBotWeb, :live_view
  alias StarlightBot.LogStore
  alias StarlightBot.Navigation.MachineStatus

  @page_size 2000
  @embedded_lines 300
  @machine_refresh_ms 500

  @impl true
  def mount(_params, session, socket) do
    embedded? = Map.has_key?(session, "max_lines")

    if connected?(socket) do
      LogStore.subscribe()
      :timer.send_interval(@machine_refresh_ms, :refresh_machines)
    end

    {:ok,
     socket
     |> assign(:embedded?, embedded?)
     |> assign(:lines_dom_id, "log-lines-#{socket.id}")
     |> assign(:max_lines, Map.get(session, "max_lines", @page_size))
     |> assign(:machines, machine_rows())
     |> assign(:file_path, LogStore.file_path())
     |> assign(:memory_limit, LogStore.memory_limit())
     |> assign(:show_steps, false)
     |> assign(:errors_only, false)
     |> assign(:machine_filter, nil)
     |> assign(:machine_filter_label, nil)
     |> stream_configure(:entries, dom_id: &"log-#{&1.seq}")
     |> reload()}
  end

  @impl true
  def handle_event("load_older", _, %{assigns: %{oldest_seq: nil}} = socket), do: {:noreply, socket}

  def handle_event("load_older", _, socket) do
    older = LogStore.before(socket.assigns.oldest_seq, @page_size)
    visible = Enum.filter(older, &visible?(&1, socket.assigns))

    {:noreply,
     socket
     |> update(:shown, &(&1 + length(visible)))
     |> assign(:oldest_seq, oldest_seq(older) || socket.assigns.oldest_seq)
     |> stream(:entries, Enum.reverse(visible), at: 0)}
  end

  def handle_event("toggle_steps", _, socket), do: {:noreply, socket |> update(:show_steps, &(not &1)) |> reload()}

  def handle_event("toggle_errors", _, socket), do: {:noreply, socket |> update(:errors_only, &(not &1)) |> reload()}

  def handle_event("filter_machine", %{"pid" => pid_text}, socket) do
    case Enum.find(socket.assigns.machines, &(pid_text(&1.pid) == pid_text)) do
      nil -> {:noreply, socket}
      row -> {:noreply, socket |> assign(machine_filter: row.pid, machine_filter_label: row.label || row.current) |> reload()}
    end
  end

  def handle_event("clear_machine_filter", _, socket),
    do: {:noreply, socket |> assign(machine_filter: nil, machine_filter_label: nil) |> reload()}

  @impl true
  def handle_info(:refresh_machines, socket), do: {:noreply, assign(socket, :machines, machine_rows())}

  @impl true
  def handle_info({:log_entry, entry}, socket) do
    socket = update(socket, :oldest_seq, &(&1 || entry.seq))

    cond do
      not visible?(entry, socket.assigns) -> {:noreply, socket}
      socket.assigns.embedded? -> {:noreply, socket |> update(:shown, &min(&1 + 1, socket.assigns.max_lines)) |> stream_insert(:entries, entry, limit: -socket.assigns.max_lines)}
      true -> {:noreply, socket |> update(:shown, &(&1 + 1)) |> stream_insert(:entries, entry)}
    end
  end

  def panel(assigns) do
    assigns = assigns |> assign_new(:class, fn -> "flex-1 min-h-0" end) |> assign(:embedded_lines, @embedded_lines)

    ~H"""
    {live_render(@socket, __MODULE__, id: @id, session: %{"max_lines" => @embedded_lines}, container: {:div, class: "flex flex-col #{@class}"})}
    """
  end

  defp reload(socket) do
    entries = LogStore.recent(socket.assigns.max_lines)
    visible = Enum.filter(entries, &visible?(&1, socket.assigns))

    socket
    |> assign(:shown, length(visible))
    |> assign(:oldest_seq, oldest_seq(entries))
    |> stream(:entries, visible, reset: true)
  end

  defp visible?(entry, assigns) do
    (assigns.show_steps or entry.kind != :step) and
      (not assigns.errors_only or entry.kind == :error) and
      (assigns.machine_filter == nil or assigns.machine_filter in Map.get(entry, :lineage, []))
  end

  defp oldest_seq([]), do: nil
  defp oldest_seq([oldest | _]), do: oldest.seq

  def pid_text(pid), do: pid |> :erlang.pid_to_list() |> to_string()

  def short_time(at), do: at |> NaiveDateTime.to_time() |> Time.truncate(:millisecond) |> Time.to_string()

  def line_class(:error), do: "border-error bg-error/10 text-error"
  def line_class(:ok), do: "border-success/60 text-base-content"
  def line_class(:info), do: "border-base-content/20 text-base-content/80"
  def line_class(:step), do: "border-transparent text-base-content/40 text-[11px]"
  def line_class(_kind), do: "border-base-content/10 text-base-content/60"

  defp machine_rows do
    statuses = MachineStatus.all()
    pids = MapSet.new(statuses, & &1.pid)
    children = Enum.group_by(statuses, &(if MapSet.member?(pids, &1.parent), do: &1.parent, else: :root))
    now = System.monotonic_time(:millisecond)
    flatten(Map.get(children, :root, []), children, 0, now)
  end

  defp flatten(statuses, children, depth, now) do
    statuses
    |> Enum.sort_by(& &1.started_at)
    |> Enum.flat_map(fn status ->
      [Map.merge(status, %{depth: depth, waiting: waiting_text(status.waiting, now)}) | flatten(Map.get(children, status.pid, []), children, depth + 1, now)]
    end)
  end

  defp waiting_text(nil, _now), do: nil
  defp waiting_text({text, deadline}, now), do: "#{text} (#{Float.round(max(deadline - now, 0) / 1000, 1)}s left)"

  def machine_summary([]), do: "idle"

  def machine_summary(rows) do
    deepest = List.last(rows)
    Enum.join(Enum.reject([deepest.current, deepest.waiting, if(deepest.state == :paused, do: "paused")], &is_nil/1), " · ")
  end

  def machine_state_class(:paused), do: "badge-warning"
  def machine_state_class(:polling), do: "badge-info"
  def machine_state_class(_state), do: "badge-ghost"

  def older_available?(nil), do: false

  def older_available?(oldest_seq) do
    case LogStore.first_seq() do
      nil -> false
      first -> first < oldest_seq
    end
  end

  def trimmed?(oldest_seq), do: oldest_seq != nil and not older_available?(oldest_seq) and oldest_seq > 1

end
