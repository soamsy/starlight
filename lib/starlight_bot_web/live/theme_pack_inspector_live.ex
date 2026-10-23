defmodule StarlightBotWeb.Live.ThemePackInspectorLive do
  use StarlightBotWeb, :live_view

  require Logger
  alias StarlightBot.{Ctx, Hooks, ThemePacks, Vision.Capture, Vision.Matcher}
  alias StarlightBot.Automation.Scripts.ThemePackSelector

  @countdown_secs 2

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:theme_packs, ThemePacks.list_theme_packs())
     |> assign(:hook_names, Hooks.list_names("sleevesearch"))
     |> assign(:filter, "")
     |> assign(:scan_status, :idle)
     |> assign(:scan_matched_ids, nil)
     |> assign(:scan_results, [])
     |> assign(:scan_total_ms, nil)
     |> assign(:search_pack_id, nil)
     |> assign(:search_status, :idle)
     |> assign(:countdown, nil)}
  end

  @impl true
  def handle_event("filter_theme_packs", %{"value" => val}, socket) do
    {:noreply, assign(socket, :filter, val)}
  end

  @impl true
  def handle_event("set_search_hook", %{"pack_id" => pack_id, "value" => value}, socket) do
    hook_name = String.trim(value)

    cond do
      hook_name == "" ->
        ThemePacks.set_search_hook(pack_id, nil)
        {:noreply, assign(socket, :theme_packs, ThemePacks.list_theme_packs())}

      hook_name in socket.assigns.hook_names ->
        ThemePacks.set_search_hook(pack_id, hook_name)
        {:noreply, assign(socket, :theme_packs, ThemePacks.list_theme_packs())}

      true ->
        {:noreply, put_flash(socket, :error, "No hook named #{hook_name}.")}
    end
  end

  @impl true
  def handle_event("test_search", _params, %{assigns: %{search_status: status}} = socket)
      when status in [:counting_down, :running] do
    {:noreply, socket}
  end

  @impl true
  def handle_event("test_search", %{"pack_id" => pack_id}, socket) do
    Process.send_after(self(), :countdown_tick, 1_000)

    {:noreply,
     socket
     |> assign(:search_pack_id, pack_id)
     |> assign(:search_status, :counting_down)
     |> assign(:countdown, @countdown_secs)}
  end

  @impl true
  def handle_event("scan_theme_packs", _, socket) do
    viewer = self()
    theme_packs = socket.assigns.theme_packs

    Task.start(fn ->
      result =
        case Capture.grab_frame() do
          {:ok, frame} ->
            {total_us, results} = :timer.tc(fn -> scan_all(theme_packs, frame) end)
            {:ok, results, total_us / 1000.0}

          {:error, reason} ->
            {:error, reason}
        end

      send(viewer, {:scan_result, result})
    end)

    {:noreply, assign(socket, :scan_status, :scanning)}
  end

  @impl true
  def handle_event("clear_scan", _, socket) do
    {:noreply,
     socket
     |> assign(:scan_status, :idle)
     |> assign(:scan_matched_ids, nil)
     |> assign(:scan_results, [])
     |> assign(:scan_total_ms, nil)}
  end

  @impl true
  def handle_info(:countdown_tick, %{assigns: %{countdown: 1}} = socket) do
    start_search(Enum.find(socket.assigns.theme_packs, &(&1.id == socket.assigns.search_pack_id)))
    {:noreply, socket |> assign(:search_status, :running) |> assign(:countdown, nil)}
  end

  @impl true
  def handle_info(:countdown_tick, socket) do
    Process.send_after(self(), :countdown_tick, 1_000)
    {:noreply, assign(socket, :countdown, socket.assigns.countdown - 1)}
  end

  @impl true
  def handle_info({:search_result, result}, socket) do
    socket = assign(socket, :search_status, :idle)

    case result do
      {:ok, _} -> {:noreply, put_flash(socket, :info, "Theme pack search finished.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Theme pack search failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:scan_result, {:ok, results, total_ms}}, socket) do
    matched_ids = results |> Enum.filter(& &1.matched) |> MapSet.new(& &1.id)

    {:noreply,
     socket
     |> assign(:scan_status, :done)
     |> assign(:scan_matched_ids, matched_ids)
     |> assign(:scan_results, results)
     |> assign(:scan_total_ms, total_ms)
     |> put_flash(:info, "Matched #{MapSet.size(matched_ids)} theme pack(s) in #{Float.round(total_ms, 1)} ms.")}
  end

  @impl true
  def handle_info({:scan_result, {:error, :no_window}}, socket) do
    {:noreply,
     socket
     |> assign(:scan_status, :idle)
     |> put_flash(:error, "Game window not found. Start Limbus Company first.")}
  end

  @impl true
  def handle_info({:scan_result, {:error, reason}}, socket) do
    Logger.error("Theme pack scan failed: #{inspect(reason)}", module: __MODULE__)

    {:noreply,
     socket
     |> assign(:scan_status, :idle)
     |> put_flash(:error, "Scan failed: #{inspect(reason)}")}
  end

  defp start_search(pack) do
    me = self()

    Task.Supervisor.start_child(StarlightBot.TaskSupervisor, fn ->
      ctx = Ctx.new()
      send(me, {:search_result, ThemePackSelector.search_replace(pack, ctx)})
    end)
  end

  defp scan_all(theme_packs, frame) do
    packs = Enum.filter(theme_packs, & &1.hook_name)

    hook_atoms =
      packs
      |> Enum.map(&safe_to_atom(&1.hook_name))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    results_by_hook =
      frame
      |> Matcher.find_with_score_batch(hook_atoms)
      |> Map.new(fn {name, result, duration_us} -> {Atom.to_string(name), {result, duration_us}} end)

    Enum.map(packs, &build_scan_result(&1, results_by_hook))
  end

  defp build_scan_result(pack, results_by_hook) do
    {result, duration_us} = Map.get(results_by_hook, pack.hook_name, {{:error, :hook_not_found}, 0})

    {matched, score, rect} =
      case result do
        {:ok, score, {:ok, rect}} -> {true, score, rect}
        {:ok, score, :not_found} -> {false, score, nil}
        _ -> {false, 0.0, nil}
      end

    %{
      id: pack.id,
      name_en: pack.name_en,
      hook_name: pack.hook_name,
      matched: matched,
      score: score,
      rect: rect,
      duration_ms: duration_us / 1000.0
    }
  end

  defp safe_to_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    _ -> nil
  end

  def filtered_theme_packs(theme_packs, filter, scan_matched_ids, scan_results \\ []) do
    theme_packs
    |> filter_by_search(filter)
    |> filter_by_scan(scan_matched_ids)
    |> sort_by_scan(scan_matched_ids, scan_results)
  end

  defp filter_by_search(theme_packs, ""), do: theme_packs

  defp filter_by_search(theme_packs, filter) do
    f = String.downcase(filter)
    Enum.filter(theme_packs, &String.contains?(String.downcase(&1.name_en || ""), f))
  end

  defp filter_by_scan(theme_packs, nil), do: theme_packs

  defp filter_by_scan(theme_packs, matched_ids),
    do: Enum.filter(theme_packs, &MapSet.member?(matched_ids, &1.id))

  defp sort_by_scan(theme_packs, nil, _scan_results), do: theme_packs

  defp sort_by_scan(theme_packs, _matched_ids, scan_results) do
    results_by_id = Map.new(scan_results, &{&1.id, &1})
    Enum.sort_by(theme_packs, &scan_sort_key(Map.get(results_by_id, &1.id)))
  end

  defp scan_sort_key(nil), do: {1, 0, 0.0}
  defp scan_sort_key(r), do: {if(r.matched, do: 0, else: 1), scan_result_x(r), -r.score}

  def sorted_scan_results(results) do
    Enum.sort_by(results, &scan_sort_key/1)
  end

  defp scan_result_x(%{rect: {x, _, _, _}}), do: x
  defp scan_result_x(_), do: 0

  def floors_label(nil), do: "—"

  def floors_label(json) do
    case Jason.decode(json) do
      {:ok, []} -> "—"
      {:ok, [single]} -> to_string(single)
      {:ok, [first | _] = list} -> "#{first}–#{List.last(list)}"
      _ -> "—"
    end
  end

  def strip_html(nil), do: nil

  def strip_html(str) do
    str
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<[^>]*>/, "")
    |> String.trim()
  end
end
