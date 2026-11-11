defmodule StarlightBotWeb.Live.BattleHistoryLive do
  use StarlightBotWeb, :live_view
  alias StarlightBot.BattleDebug
  alias StarlightBot.BattleDebug.{Detect, Verify}

  @sins ~w(wrath lust sloth gluttony gloom pride envy)
  @tiers ~w(skill1 skill2 skill3)
  @sin_colors %{
    "wrath" => "#f87171",
    "lust" => "#fb923c",
    "sloth" => "#facc15",
    "gluttony" => "#a3e635",
    "gloom" => "#22d3ee",
    "pride" => "#60a5fa",
    "envy" => "#c084fc"
  }
  @sinner_palette ["#f87171", "#60a5fa", "#facc15", "#4ade80", "#c084fc", "#fb923c", "#22d3ee"]
  @fail_color "#ef4444"
  @bulk_concurrency 2
  @bulk_timeout_ms 60_000

  def sins, do: @sins
  def tiers, do: @tiers

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:entries, BattleDebug.list())
     |> assign(:view, "captures")
     |> assign(:kind_filter, "all")
     |> assign(:selected, nil)
     |> assign(:truth, nil)
     |> assign(:result, nil)
     |> assign(:bulk, %{running?: false, ref: nil, done: 0, total: 0, results: %{}})
     |> assign(:bulk_filter, "failures")}
  end

  @impl true
  def handle_event("refresh", _, socket), do: {:noreply, assign(socket, :entries, BattleDebug.list())}

  def handle_event("view", %{"view" => view}, socket) when view in ~w(captures bulk), do: {:noreply, assign(socket, :view, view)}

  def handle_event("filter", %{"kind" => kind}, socket) when kind in ~w(all chain_tray focused_enemies),
    do: {:noreply, assign(socket, :kind_filter, kind)}

  def handle_event("restore_view", %{"kind" => kind}, socket) when kind in ~w(all chain_tray focused_enemies),
    do: {:noreply, assign(socket, :kind_filter, kind)}

  def handle_event("restore_view", _params, socket), do: {:noreply, socket}

  def handle_event("bulk_filter", %{"filter" => filter}, socket) when filter in ~w(failures all),
    do: {:noreply, assign(socket, :bulk_filter, filter)}

  def handle_event("select", %{"id" => id}, socket), do: {:noreply, select(socket, id)}

  def handle_event("open", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:view, "captures") |> select(id)}
  end

  def handle_event("tray_edit", %{"slots" => slots}, socket) do
    truth = %{"slots" => slots |> Enum.sort_by(fn {i, _} -> String.to_integer(i) end) |> Enum.map(fn {_i, slot} -> parse_slot(slot) end)}
    save(socket, truth)
    {:noreply, socket |> assign(:truth, truth) |> assign(:result, nil) |> push_tray(false)}
  end

  def handle_event("enemy_rects", %{"rects" => rects}, socket) do
    truth = %{"rects" => Enum.map(rects, &Map.take(&1, ["x", "y", "w", "h"]))}
    save(socket, truth)
    {:noreply, socket |> assign(:truth, truth) |> assign(:result, nil)}
  end

  def handle_event("clear_enemies", _, socket) do
    truth = %{"rects" => []}
    save(socket, truth)
    {:noreply, socket |> assign(:truth, truth) |> assign(:result, nil) |> push_enemies(false)}
  end

  def handle_event("reset_truth", _, %{assigns: %{selected: %{"id" => id} = record}} = socket) do
    BattleDebug.reset_truth(id)
    {:noreply, socket |> assign(:truth, BattleDebug.default_truth(record)) |> assign(:result, nil) |> push_editor(false) |> refresh_entries()}
  end

  def handle_event("toggle_suite", _, %{assigns: %{selected: %{"id" => id} = record}} = socket) do
    in_suite? = not record["in_suite?"]
    BattleDebug.set_suite(id, in_suite?)
    {:noreply, socket |> refresh_entries() |> assign(:selected, Map.put(record, "in_suite?", in_suite?))}
  end

  def handle_event("delete_capture", _, %{assigns: %{selected: %{"id" => id}}} = socket) do
    BattleDebug.delete(id)
    {:noreply, socket |> refresh_entries() |> assign(:selected, nil) |> assign(:truth, nil) |> assign(:result, nil)}
  end

  def handle_event("delete_non_suite", _, socket) do
    %{deleted: deleted} = BattleDebug.delete_outside_suite()
    socket = refresh_entries(socket)
    selected = socket.assigns.selected

    socket =
      if selected && not Enum.any?(socket.assigns.entries, &(&1["id"] == selected["id"])),
        do: socket |> assign(:selected, nil) |> assign(:truth, nil) |> assign(:result, nil),
        else: socket

    {:noreply, put_flash(socket, :info, "Moved #{deleted} capture(s) outside the test suite to the trash")}
  end

  def handle_event("test", _, %{assigns: %{selected: %{"id" => id}}} = socket) do
    {:noreply, socket |> assign(:result, Verify.run(id)) |> push_editor(false)}
  end

  def handle_event("bulk_run", _, %{assigns: %{bulk: %{running?: true}}} = socket), do: {:noreply, socket}

  def handle_event("bulk_run", _, socket) do
    me = self()
    ref = make_ref()
    ids = socket.assigns.entries |> suite_entries() |> Enum.map(& &1["id"])

    Task.Supervisor.start_child(StarlightBot.TaskSupervisor, fn ->
      ids
      |> Task.async_stream(&Verify.run/1, max_concurrency: @bulk_concurrency, timeout: @bulk_timeout_ms, on_timeout: :kill_task, zip_input_on_exit: true)
      |> Enum.each(fn
        {:ok, result} -> send(me, {:bulk_result, ref, result})
        {:exit, {id, reason}} -> send(me, {:bulk_result, ref, %{id: id, kind: nil, ok?: false, diffs: [], error: inspect(reason), summary: "crashed: #{inspect(reason)}"}})
      end)

      send(me, {:bulk_done, ref})
    end)

    {:noreply, assign(socket, :bulk, %{running?: true, ref: ref, done: 0, total: length(ids), results: %{}})}
  end

  @impl true
  def handle_info({:bulk_result, ref, result}, %{assigns: %{bulk: %{ref: ref} = bulk}} = socket) do
    {:noreply, assign(socket, :bulk, %{bulk | done: bulk.done + 1, results: Map.put(bulk.results, result.id, result)})}
  end

  def handle_info({:bulk_done, ref}, %{assigns: %{bulk: %{ref: ref} = bulk}} = socket) do
    {:noreply, assign(socket, :bulk, %{bulk | running?: false})}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  def suite_entries(entries), do: Enum.filter(entries, & &1["in_suite?"])

  def visible(entries, "all"), do: entries
  def visible(entries, kind), do: Enum.filter(entries, &(&1["kind"] == kind))

  def kind_label("chain_tray"), do: "tray"
  def kind_label("focused_enemies"), do: "enemies"
  def kind_label(other), do: to_string(other)

  def summary(%{"kind" => "chain_tray", "detected" => %{"slots" => slots}} = entry), do: "tray, #{length(slots)} slot(s)#{context_text(entry)}"
  def summary(%{"kind" => "focused_enemies", "detected" => %{"enemies" => enemies}} = entry), do: "#{length(enemies)} enemies detected#{context_text(entry)}"
  def summary(entry), do: to_string(entry["kind"]) <> context_text(entry)

  defp context_text(entry), do: ", floor #{entry["floor"]} turn #{entry["battle_turn"]}"

  def bulk_stats(%{results: results, total: total}) do
    values = Map.values(results)
    failed = Enum.reject(values, & &1.ok?)

    %{
      total: total,
      tested: length(values),
      passed: Enum.count(values, & &1.ok?),
      failed: length(failed),
      problems: failed |> Enum.map(&Verify.failure_count/1) |> Enum.sum()
    }
  end

  def bulk_rows(entries, bulk, filter) do
    entries
    |> Enum.map(&{&1, Map.get(bulk.results, &1["id"])})
    |> Enum.filter(fn {_entry, result} -> filter == "all" or (result != nil and not result.ok?) end)
  end

  def cell_class(nil), do: "bg-base-300"
  def cell_class(%{ok?: true}), do: "bg-success"
  def cell_class(%{error: error}) when is_binary(error), do: "bg-warning"
  def cell_class(_result), do: "bg-error"

  def field_label("top_sin"), do: "top sin"
  def field_label("top_tier"), do: "top tier"
  def field_label("bottom_sin"), do: "bottom sin"
  def field_label("bottom_tier"), do: "bottom tier"
  def field_label("sinner_start"), do: "sinner start"
  def field_label("slot_count"), do: "slot count"

  def tier_label("skill1"), do: "S1"
  def tier_label("skill2"), do: "S2"
  def tier_label("skill3"), do: "S3"

  def value_text(true), do: "yes"
  def value_text(false), do: "no"
  def value_text(value), do: to_string(value)

  defp select(socket, id) do
    case BattleDebug.get(id) do
      nil ->
        socket

      record ->
        record = refresh_geometry(record)

        socket
        |> assign(:selected, record)
        |> assign(:truth, BattleDebug.truth(id, record))
        |> assign(:result, nil)
        |> push_editor(true)
    end
  end

  defp refresh_geometry(%{"kind" => "chain_tray", "id" => id} = record) do
    with {:ok, frame} <- BattleDebug.load_frame(id),
         {:ok, detected} <- Detect.run("chain_tray", frame) do
      put_in(record, ["detected", "geometry"], detected.geometry |> Jason.encode!() |> Jason.decode!())
    else
      _ -> record
    end
  end

  defp refresh_geometry(record), do: record

  defp save(%{assigns: %{selected: %{"id" => id}}} = socket, truth) do
    BattleDebug.save_truth(id, truth)
    refresh_entries(socket)
  end

  defp refresh_entries(socket), do: assign(socket, :entries, BattleDebug.list())

  defp parse_slot(slot) do
    %{
      "sinner_start" => slot["sinner_start"] == "true",
      "top" => %{"sin" => pick(slot["top_sin"], @sins), "tier" => pick(slot["top_tier"], @tiers)},
      "bottom" => %{"sin" => pick(slot["bottom_sin"], @sins), "tier" => pick(slot["bottom_tier"], @tiers)}
    }
  end

  defp pick(value, allowed), do: if(value in allowed, do: value, else: hd(allowed))

  defp push_editor(%{assigns: %{selected: %{"kind" => "chain_tray"}}} = socket, with_image?), do: push_tray(socket, with_image?)
  defp push_editor(%{assigns: %{selected: %{"kind" => "focused_enemies"}}} = socket, with_image?), do: push_enemies(socket, with_image?)
  defp push_editor(socket, _with_image?), do: socket

  defp push_tray(%{assigns: %{selected: record, truth: truth, result: result}} = socket, with_image?) do
    push_event(socket, "load_battle_history_frame", %{data: image_data(record, with_image?), overlays: tray_overlays(record, truth, result)})
  end

  defp push_enemies(%{assigns: %{selected: record, truth: truth, result: result}} = socket, with_image?) do
    diff = result && Map.take(result, [:matched, :missed, :extra])
    push_event(socket, "load_enemy_editor", %{data: image_data(record, with_image?), rects: truth["rects"], diff: diff})
  end

  defp image_data(_record, false), do: nil

  defp image_data(%{"id" => id}, true) do
    with {:ok, frame} <- BattleDebug.load_frame(id),
         jpeg when is_binary(jpeg) <- Evision.imencode(".jpg", frame.mat) do
      Base.encode64(jpeg)
    else
      _ -> nil
    end
  end

  defp tray_overlays(%{"detected" => %{"geometry" => geometry}}, %{"slots" => slots}, result) do
    diffs = (result && result.diffs) || []
    starts = slots |> Enum.scan(0, fn slot, n -> if slot["sinner_start"], do: n + 1, else: n end)

    slots
    |> Enum.with_index()
    |> Enum.zip(starts)
    |> Enum.flat_map(fn {{slot, i}, sinner_number} ->
      top = Enum.at(geometry["top"], i)
      bottom = Enum.at(geometry["bottom"], i)
      bin = Enum.at(geometry["bins"], i)
      cell_overlays(slot, i, top, bottom) ++ sinner_overlay(slot, bin, sinner_number)
    end)
    |> Kernel.++(diff_overlays(diffs, geometry))
  end

  defp tray_overlays(_record, _truth, _result), do: []

  defp cell_overlays(slot, i, top, bottom) do
    [
      cell_overlay(top, slot["top"], i, top["y"] - 22),
      cell_overlay(bottom, slot["bottom"], i, bottom["y"] + bottom["h"] + 12)
    ]
  end

  defp cell_overlay(rect, %{"sin" => sin, "tier" => tier}, i, text_y) do
    color = Map.fetch!(@sin_colors, sin)
    rect_overlay(rect, color, false) |> Map.merge(%{text: "#{i} #{tier_label(tier)} #{sin}", text_x: rect["x"] + 4, text_y: text_y, outline: true, font_px: 11})
  end

  defp rect_overlay(rect, color, dashed?), do: %{type: "rect", x: rect["x"], y: rect["y"], w: rect["w"], h: rect["h"], color: color, dashed: dashed?}

  defp sinner_overlay(%{"sinner_start" => true}, bin, sinner_number) do
    color = Enum.at(@sinner_palette, rem(sinner_number, length(@sinner_palette)))
    [%{type: "line", x1: bin["x0"], y1: 760, x2: bin["x0"], y2: 1000, color: color, text: "sinner #{sinner_number}", text_x: bin["x0"] + 4, text_y: 775, outline: true}]
  end

  defp sinner_overlay(_slot, _bin, _sinner_number), do: []

  defp diff_overlays(diffs, geometry) do
    Enum.flat_map(diffs, fn
      %{slot: nil} ->
        []

      %{slot: slot, field: "sinner_start", expected: expected} ->
        bin = Enum.at(geometry["bins"], slot)
        [%{type: "line", x1: bin["x0"] + 8, y1: 770, x2: bin["x0"] + 8, y2: 1000, color: @fail_color, text: "sinner start expected #{value_text(expected)}", text_x: bin["x0"] + 12, text_y: 990, outline: true, font_px: 11}]

      %{slot: slot, field: field, expected: expected, actual: actual} ->
        rect = geometry |> Map.fetch!(String.split(field, "_") |> hd()) |> Enum.at(slot)
        above? = String.starts_with?(field, "top")
        [Map.merge(rect_overlay(rect, @fail_color, false), %{text: "exp #{expected} got #{actual}", text_x: rect["x"] + 4, text_y: if(above?, do: rect["y"] - 38, else: rect["y"] + rect["h"] + 28), outline: true, font_px: 11})]
    end)
  end
end
