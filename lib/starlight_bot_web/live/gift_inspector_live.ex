defmodule StarlightBotWeb.Live.GiftInspectorLive do
  use StarlightBotWeb, :live_view

  alias StarlightBot.{Vision.Capture, Vision.EgoGiftDetector}

  @tmp_jpeg "/tmp/_starlight_gift_inspector.jpg"

  @found_color "#4ade80"
  @unmatched_color "#facc15"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:status, :idle)
     |> assign(:frame_b64, nil)
     |> assign(:screenshot_mat, nil)
     |> assign(:region, nil)
     |> assign(:results, [])
     |> assign(:min_area, 0)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_event("set_min_area", %{"min_area" => value}, socket) do
    min_area = parse_min_area(value)

    {:noreply,
     socket
     |> assign(:min_area, min_area)
     |> push_event("show_gift_overlays", %{overlays: overlays(socket.assigns.results, min_area)})}
  end

  @impl true
  def handle_event("take_screenshot", _, socket) do
    socket = assign(socket, :status, :loading)

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
             |> assign(:error, nil)
             |> push_event("load_gift_inspector_frame", %{data: Base.encode64(jpeg)})}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:status, :error)
             |> put_flash(:error, "Encode failed: #{inspect(reason)}")}
        end

      {:error, :no_window} ->
        {:noreply,
         socket
         |> assign(:status, :error)
         |> put_flash(:error, "Game window not found. Start Limbus Company first.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:status, :error)
         |> put_flash(:error, "Screenshot failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("region_selected", %{"x" => x, "y" => y, "w" => w, "h" => h}, socket) do
    region = %{x: x, y: y, w: w, h: h}

    case socket.assigns.screenshot_mat do
      nil ->
        {:noreply, socket}

      mat ->
        case EgoGiftDetector.detect(mat, {x, y, w, h}) do
          {:ok, results} ->
            {:noreply,
             socket
             |> assign(:region, region)
             |> assign(:results, results)
             |> assign(:error, nil)
             |> push_event("show_gift_overlays", %{overlays: overlays(results, socket.assigns.min_area)})}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:region, region)
             |> assign(:results, [])
             |> assign(:error, reason)
             |> push_event("show_gift_overlays", %{overlays: []})}
        end
    end
  end

  def filtered_results(results, min_area), do: Enum.filter(results, &above_min_area?(&1, min_area))

  defp overlays(results, min_area) do
    results
    |> filtered_results(min_area)
    |> Enum.map(&result_overlay/1)
  end

  defp above_min_area?(%{w: w, h: h}, min_area), do: w * h >= min_area

  defp parse_min_area(value) do
    case Integer.parse(to_string(value)) do
      {n, _} when n > 0 -> n
      _ -> 0
    end
  end

  defp result_overlay(%{gift_id: nil} = r) do
    %{
      type: "rect",
      x: r.x,
      y: r.y,
      w: r.w,
      h: r.h,
      color: @unmatched_color,
      text: "? det=#{pct(r.detector_confidence)}",
      text_x: r.x,
      text_y: r.y - 6
    }
  end

  defp result_overlay(r) do
    %{
      type: "rect",
      x: r.x,
      y: r.y,
      w: r.w,
      h: r.h,
      color: @found_color,
      text: "#{r.gift_name} #{pct(r.classifier_confidence)}",
      text_x: r.x,
      text_y: r.y - 6
    }
  end

  defp pct(nil), do: "—"
  defp pct(v), do: "#{round(v * 100)}%"

  defp encode_jpeg(mat) do
    Evision.imwrite(@tmp_jpeg, mat)
    File.read(@tmp_jpeg)
  rescue
    e -> {:error, Exception.message(e)}
  end

  def error_message(:models_not_loaded),
    do: "Detector/classifier models not loaded — run `mix ego_gifts.fetch_model`."

  def error_message(:empty_region), do: "Selected region is empty."
  def error_message(other), do: inspect(other)
end
