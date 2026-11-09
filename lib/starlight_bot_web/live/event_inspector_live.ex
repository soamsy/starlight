defmodule StarlightBotWeb.Live.EventInspectorLive do
  use StarlightBotWeb, :live_view
  alias StarlightBot.{Ctx, LogStore}
  alias StarlightBot.Navigation.{Catalog, Runner}
  alias StarlightBot.Vision.{Capture, Matcher}

  @tmp_jpeg "/tmp/_starlight_event_inspector.jpg"
  @countdown_secs 2

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:status, :idle)
     |> assign(:countdown, nil)
     |> assign(:frame_b64, nil)}
  end

  @impl true
  def handle_event("run", _, %{assigns: %{status: status}} = socket)
      when status in [:counting_down, :running] do
    {:noreply, socket}
  end

  @impl true
  def handle_event("run", _, socket) do
    Process.send_after(self(), :countdown_tick, 1_000)

    {:noreply,
     socket
     |> assign(:status, :counting_down)
     |> assign(:countdown, @countdown_secs)}
  end

  @impl true
  def handle_info(:countdown_tick, %{assigns: %{countdown: 1}} = socket) do
    start_event_run()
    {:noreply, socket |> assign(:status, :running) |> assign(:countdown, nil)}
  end

  @impl true
  def handle_info(:countdown_tick, socket) do
    Process.send_after(self(), :countdown_tick, 1_000)
    {:noreply, assign(socket, :countdown, socket.assigns.countdown - 1)}
  end

  @impl true
  def handle_info({:event_frame, b64}, socket) do
    {:noreply, assign(socket, :frame_b64, b64)}
  end

  @impl true
  def handle_info({:event_result, result}, socket) do
    {kind, text} =
      case result do
        {:ok, _} -> {:ok, "done — event screen closed"}
        {:error, reason} -> {:error, "failed: #{inspect(reason)}"}
      end

    LogStore.append(kind, "event inspector: #{text}")
    {:noreply, assign(socket, :status, :done)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp start_event_run do
    me = self()

    Task.Supervisor.start_child(StarlightBot.TaskSupervisor, fn ->
      ctx = Ctx.new()

      case Capture.grab_frame() do
        {:ok, frame} ->
          send(me, {:event_frame, encode_jpeg(frame.mat)})
          run_if_at_event(frame, ctx, me)

        {:error, reason} ->
          LogStore.append(:error, "event inspector: screenshot failed: #{inspect(reason)}")
          send(me, {:event_result, {:error, reason}})
      end
    end)
  end

  defp run_if_at_event(frame, ctx, me) do
    if Matcher.check(frame, :event) do
      Ctx.log(ctx, :info, "at event screen — running")
      send(me, {:event_result, run_transition(ctx)})
    else
      Ctx.log(ctx, :error, "not at an event screen")
      send(me, {:event_result, {:error, :not_at_event}})
    end
  end

  defp run_transition(ctx) do
    case Catalog.find_transition(:event, :event_over) do
      nil -> {:error, :no_transition}
      transition -> Runner.run_steps(transition.steps, ctx)
    end
  end

  defp encode_jpeg(mat) do
    Evision.imwrite(@tmp_jpeg, mat)

    case File.read(@tmp_jpeg) do
      {:ok, jpeg} -> Base.encode64(jpeg)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def status_label(:idle), do: "Idle"
  def status_label(:counting_down), do: "Alt-tab now"
  def status_label(:running), do: "Running…"
  def status_label(:done), do: "Done"

end
