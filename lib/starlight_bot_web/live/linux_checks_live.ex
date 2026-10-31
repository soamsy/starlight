defmodule StarlightBotWeb.Live.LinuxChecksLive do
  use StarlightBotWeb, :live_view
  alias StarlightBot.{LinuxCheck, LogStore}
  alias StarlightBotWeb.Live.LogLive

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:checks, LinuxCheck.checks())
     |> assign(:results, %{})
     |> assign(:running, nil)
     |> assign(:busy, nil)
     |> assign(:next_id, 0)
     |> assign(:count, 0)
     |> stream_configure(:entries, dom_id: &"lc-#{&1.id}")
     |> stream(:entries, [])}
  end

  @impl true
  def handle_event("run", %{"id" => id}, %{assigns: %{busy: nil}} = socket) do
    check = Enum.find(socket.assigns.checks, &(Atom.to_string(&1.id) == id))
    {:noreply, if(check, do: start(socket, [check.id]), else: socket)}
  end

  def handle_event("run_passive", _params, %{assigns: %{busy: nil}} = socket),
    do: {:noreply, start(socket, LinuxCheck.passive_ids())}

  def handle_event("run_active", _params, %{assigns: %{busy: nil}} = socket),
    do: {:noreply, start(socket, LinuxCheck.active_ids())}

  def handle_event("clear", _params, socket) do
    {:noreply, socket |> assign(:count, 0) |> assign(:results, %{}) |> stream(:entries, [], reset: true)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:lc_log, kind, text}, socket), do: {:noreply, add_entry(socket, kind, text)}

  def handle_info({:lc_running, id}, socket), do: {:noreply, assign(socket, :running, id)}

  def handle_info({:lc_result, id, status}, socket),
    do: {:noreply, socket |> update(:results, &Map.put(&1, id, status)) |> assign(:running, nil)}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{assigns: %{busy: ref}} = socket) do
    socket = if reason == :normal, do: socket, else: add_entry(socket, :error, "checks crashed: #{inspect(reason)}")
    {:noreply, socket |> assign(:busy, nil) |> assign(:running, nil)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp start(socket, ids) do
    lv = self()

    log = fn kind, text ->
      send(lv, {:lc_log, kind, text})
      LogStore.append(kind, "linux-check: " <> text)
      :ok
    end

    {:ok, pid} =
      Task.Supervisor.start_child(StarlightBot.TaskSupervisor, fn ->
        for id <- ids do
          send(lv, {:lc_running, id})
          log.(:step, "running #{id}")
          send(lv, {:lc_result, id, LinuxCheck.run(id, log)})
        end
      end)

    assign(socket, :busy, Process.monitor(pid))
  end

  defp add_entry(socket, kind, text) do
    entry = %{id: socket.assigns.next_id, at: LogStore.now(), kind: kind, text: text}

    socket
    |> update(:next_id, &(&1 + 1))
    |> update(:count, &(&1 + 1))
    |> stream_insert(:entries, entry)
  end

  def groups(checks), do: checks |> Enum.chunk_by(& &1.group) |> Enum.map(&{hd(&1).group, &1})

  def status_class(:ok), do: "bg-success"
  def status_class(:warn), do: "bg-warning"
  def status_class(:error), do: "bg-error"
  def status_class(_), do: "bg-base-content/20"

  defdelegate line_class(kind), to: LogLive
  defdelegate short_time(at), to: LogLive
end
