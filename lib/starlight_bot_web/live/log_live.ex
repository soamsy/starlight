defmodule StarlightBotWeb.Live.LogLive do
  use StarlightBotWeb, :live_view
  alias StarlightBot.LogStore
  alias StarlightBot.Navigation.MachineStatus

  @machine_refresh_ms 500
  @flush_ms 100
  @first_chunk 2000
  @backlog_chunk 5000
  @backlog_ms 30

  @impl true
  def mount(_params, session, socket) do
    embedded? = Map.has_key?(session, "embedded")

    if connected?(socket) do
      LogStore.subscribe()
      :timer.send_interval(@machine_refresh_ms, :refresh_machines)
    end

    {:ok,
     socket
     |> assign(:embedded?, embedded?)
     |> assign(:lines_dom_id, "log-lines-#{socket.id}")
     |> assign(:machines, machine_rows())
     |> assign(:file_path, LogStore.file_path())
     |> assign(:log_files, LogStore.files())
     |> assign(:viewing, nil)
     |> assign(:memory_limit, LogStore.memory_limit())
     |> assign(:pending, [])
     |> assign(:flush_scheduled?, false)
     |> assign(:backlog, [])
     |> assign(:last_seq, 0)
     |> assign(:oldest_seq, nil)
     |> assign(:show_steps, false)
     |> assign(:errors_only, false)
     |> assign(:machine_filter, nil)
     |> assign(:machine_filter_label, nil)}
  end

  @impl true
  def handle_event("select_log", %{"path" => path}, socket) do
    files = LogStore.files()
    viewing = if path in files and path != socket.assigns.file_path, do: path

    {:noreply, socket |> assign(log_files: files, viewing: viewing) |> load_log()}
  end

  def handle_event("log_ready", _, socket), do: {:noreply, load_log(socket)}

  def handle_event("toggle_steps", _, socket), do: {:noreply, update(socket, :show_steps, &(not &1))}

  def handle_event("toggle_errors", _, socket), do: {:noreply, update(socket, :errors_only, &(not &1))}

  def handle_event("filter_machine", %{"pid" => pid_text}, socket) do
    case Enum.find(socket.assigns.machines, &(pid_text(&1.pid) == pid_text)) do
      nil -> {:noreply, socket}
      row -> {:noreply, socket |> assign(machine_filter: row.pid, machine_filter_label: row.label || row.current)}
    end
  end

  def handle_event("clear_machine_filter", _, socket),
    do: {:noreply, assign(socket, machine_filter: nil, machine_filter_label: nil)}

  @impl true
  def handle_info(:refresh_machines, socket), do: {:noreply, assign(socket, :machines, machine_rows())}

  def handle_info({:log_entry, _entry}, %{assigns: %{viewing: viewing}} = socket) when viewing != nil, do: {:noreply, socket}

  def handle_info({:log_entry, %{seq: seq}}, %{assigns: %{last_seq: last_seq}} = socket) when seq <= last_seq, do: {:noreply, socket}

  def handle_info({:log_entry, entry}, socket) do
    {:noreply, socket |> update(:oldest_seq, &(&1 || entry.seq)) |> update(:pending, &[entry | &1]) |> schedule_flush()}
  end

  def handle_info(:flush_entries, %{assigns: %{pending: pending}} = socket) do
    last_seq = pending |> hd() |> Map.fetch!(:seq)

    {:noreply,
     socket
     |> assign(pending: [], flush_scheduled?: false, last_seq: last_seq)
     |> push_entries("append", Enum.reverse(pending))}
  end

  def handle_info(:load_backlog, %{assigns: %{backlog: []}} = socket), do: {:noreply, socket}

  def handle_info(:load_backlog, %{assigns: %{backlog: [chunk | rest]}} = socket) do
    if rest != [], do: Process.send_after(self(), :load_backlog, @backlog_ms)
    {:noreply, socket |> assign(:backlog, rest) |> push_entries("prepend", chunk)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  def panel(assigns) do
    assigns = assign_new(assigns, :class, fn -> "flex-1 min-h-0" end)

    ~H"""
    {live_render(@socket, __MODULE__, id: @id, session: %{"embedded" => true}, container: {:div, class: "flex flex-col min-w-0 #{@class}"})}
    """
  end

  defp load_log(socket) do
    entries =
      case socket.assigns.viewing do
        nil -> LogStore.all()
        path -> LogStore.read_file(path)
      end

    {older, newest} = Enum.split(entries, max(length(entries) - @first_chunk, 0))
    backlog = older |> Enum.reverse() |> Enum.chunk_every(@backlog_chunk) |> Enum.map(&Enum.reverse/1)
    if backlog != [], do: send(self(), :load_backlog)

    socket
    |> assign(:pending, [])
    |> assign(:backlog, backlog)
    |> assign(:last_seq, last_seq(entries))
    |> assign(:oldest_seq, oldest_seq(entries))
    |> push_entries("reset", newest)
  end

  defp push_entries(socket, mode, entries) do
    push_event(socket, "log_entries", %{id: socket.assigns.lines_dom_id, mode: mode, entries: Enum.map(entries, &encode/1)})
  end

  defp encode(entry),
    do: [entry.seq, LogStore.format_time(entry.at), Atom.to_string(entry.kind), entry.text, entry |> Map.get(:lineage, []) |> Enum.map(&pid_text/1)]

  defp last_seq([]), do: 0
  defp last_seq(entries), do: List.last(entries).seq

  defp schedule_flush(%{assigns: %{flush_scheduled?: true}} = socket), do: socket

  defp schedule_flush(socket) do
    Process.send_after(self(), :flush_entries, @flush_ms)
    assign(socket, :flush_scheduled?, true)
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

  def log_label(path), do: path |> Path.basename() |> String.replace_prefix("starlight_", "") |> String.replace_suffix(".log", "")

  def trimmed?(oldest_seq), do: oldest_seq != nil and oldest_seq > 1

end
