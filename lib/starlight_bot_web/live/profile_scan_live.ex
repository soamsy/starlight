defmodule StarlightBotWeb.Live.ProfileScanLive do
  use StarlightBotWeb, :live_view

  alias StarlightBot.{SinnerProfiles, Vision.Capture, Vision.ProfileScan}

  @tmp_jpeg "/tmp/_starlight_profile_scan.jpg"

  @found_color "#4ade80"
  @selected_color "#60a5fa"

  @default_params %{"min_scale" => "0.5", "max_scale" => "4", "steps" => "30", "include_base" => "true", "cutoff" => "0"}

  @impl true
  def mount(_params, _session, socket) do
    profiles = SinnerProfiles.list()
    sinners = profiles |> Enum.map(& &1.sinner) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    {:ok,
     socket
     |> assign(:status, :idle)
     |> assign(:profiles, profiles)
     |> assign(:sinners, sinners)
     |> assign(:sinner, if("yi_sang" in sinners, do: "yi_sang", else: List.first(sinners)))
     |> assign(:params, @default_params)
     |> assign(:screenshot_mat, nil)
     |> assign(:region, nil)
     |> assign(:results, [])
     |> assign(:selected, nil)
     |> assign(:elapsed_ms, nil)}
  end

  @impl true
  def handle_event("take_screenshot", _, socket) do
    case Capture.grab_frame() do
      {:ok, frame} ->
        case encode_jpeg(frame.mat) do
          {:ok, jpeg} ->
            {:noreply,
             socket
             |> assign(:status, :done)
             |> assign(:screenshot_mat, frame.mat)
             |> assign(:region, nil)
             |> assign(:results, [])
             |> assign(:selected, nil)
             |> push_event("load_gift_inspector_frame", %{data: Base.encode64(jpeg)})}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Encode failed: #{inspect(reason)}")}
        end

      {:error, :no_window} ->
        {:noreply, put_flash(socket, :error, "Game window not found. Start Limbus Company first.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Screenshot failed: #{inspect(reason)}")}
    end
  end

  def handle_event("region_selected", %{"x" => x, "y" => y, "w" => w, "h" => h}, socket) do
    {:noreply, socket |> assign(:region, {x, y, w, h}) |> assign(:selected, nil) |> scan()}
  end

  def handle_event("set_options", params, socket) do
    sinner = Map.get(params, "sinner", socket.assigns.sinner)
    form = Map.merge(@default_params, Map.take(params, Map.keys(@default_params)))
    form = if Map.has_key?(params, "steps"), do: Map.put(form, "include_base", Map.get(params, "include_base", "false")), else: form

    {:noreply, socket |> assign(:sinner, sinner) |> assign(:params, form) |> assign(:selected, nil) |> scan()}
  end

  def handle_event("select_hook", %{"hook" => hook}, socket) do
    selected = if socket.assigns.selected == hook, do: nil, else: hook
    socket = assign(socket, :selected, selected)
    {:noreply, push_event(socket, "show_gift_overlays", %{overlays: overlays(socket.assigns.results, selected, cutoff(socket.assigns.params))})}
  end

  defp scan(%{assigns: %{screenshot_mat: nil}} = socket), do: socket
  defp scan(%{assigns: %{region: nil}} = socket), do: socket

  defp scan(socket) do
    %{screenshot_mat: mat, region: region, sinner: sinner, params: params, profiles: profiles} = socket.assigns
    scales = ProfileScan.scales(to_float(params["min_scale"], 0.5), to_float(params["max_scale"], 4.0), to_int(params["steps"], 30))
    include_base? = params["include_base"] == "true"

    owners =
      for profile <- profiles, profile.sinner == sinner, hook <- SinnerProfiles.locator_hooks(profile), include_base? or not String.ends_with?(hook, "_base"), into: %{}, do: {hook, profile.name}

    {micros, results} = :timer.tc(fn -> ProfileScan.run(mat, region, Map.keys(owners), scales) end)

    results =
      results
      |> Enum.map(&Map.put(&1, :profile, Map.fetch!(owners, &1.hook)))
      |> Enum.sort_by(&(&1.best && &1.best.score), :desc)

    socket
    |> assign(:results, results)
    |> assign(:elapsed_ms, div(micros, 1000))
    |> push_event("show_gift_overlays", %{overlays: overlays(results, socket.assigns.selected, cutoff(params))})
  end

  defp overlays(results, nil, cutoff) do
    for %{best: %{score: score, rect: {x, y, w, h}}} = r <- results, score >= if(cutoff > 0, do: cutoff, else: r.confidence) do
      overlay(x, y, w, h, @found_color, "#{short(r.profile)} #{pct(score)}")
    end
  end

  defp overlays(results, selected, _cutoff) do
    for %{hook: ^selected, best: %{score: score, rect: {x, y, w, h}}} = r <- results do
      overlay(x, y, w, h, @selected_color, "#{short(r.profile)} #{pct(score)}")
    end
  end

  defp overlay(x, y, w, h, color, text), do: %{type: "rect", x: x, y: y, w: w, h: h, color: color, text: text, text_x: x, text_y: y - 6}

  defp short(name), do: String.slice(name, 0, 24)

  def pct(nil), do: "-"
  def pct(v), do: "#{Float.round(v * 100, 1)}%"

  def score_class(nil, _), do: "text-base-content/40"
  def score_class(score, confidence) when score >= confidence, do: "text-success font-semibold"
  def score_class(score, confidence) when score >= confidence - 0.15, do: "text-warning"
  def score_class(_, _), do: "text-base-content/60"

  def cutoff(params) do
    case Float.parse(to_string(params["cutoff"])) do
      {f, _} when f > 0 -> min(f, 100.0) / 100
      _ -> 0.0
    end
  end

  def visible(results, params) do
    cutoff = cutoff(params)
    Enum.filter(results, &(&1.best && &1.best.score >= cutoff))
  end

  def selected_result(results, selected), do: Enum.find(results, &(&1.hook == selected))

  def sinner_label(sinner), do: SinnerProfiles.label(sinner)

  defp to_float(value, default) do
    case Float.parse(to_string(value)) do
      {f, _} when f > 0 -> f
      _ -> default
    end
  end

  defp to_int(value, default) do
    case Integer.parse(to_string(value)) do
      {n, _} when n > 0 -> min(n, 200)
      _ -> default
    end
  end

  defp encode_jpeg(mat) do
    Evision.imwrite(@tmp_jpeg, mat)
    File.read(@tmp_jpeg)
  rescue
    e -> {:error, Exception.message(e)}
  end
end
