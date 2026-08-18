defmodule StarlightBotWeb.Live.HookEditorLive do
  use StarlightBotWeb, :live_view

  require Logger
  alias StarlightBot.{Hooks, Vision.Capture, Vision.HookRegistry, Vision.Matcher}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> refresh_hooks()
     |> assign(:hooks_filter, "")
     |> assign(:sort_by, :inserted_at)
     |> assign(:sort_dir, :desc)
     |> assign(:screenshot_mat, nil)
     |> assign(:screenshot_status, :idle)
     |> assign(:region, nil)
     |> assign(:click_region, nil)
     |> assign(:scan_region, nil)
     |> assign(:canvas_mode, :detect)
     |> assign(:form, blank_form())
     |> assign(:editing_name, nil)
     |> assign(:test_result, nil)
     |> assign(:template_b64, nil)
     |> assign(:saved_params, nil)
     |> assign(:duplicate_name, "")}
  end

  @impl true
  def handle_event("take_screenshot_delayed", _, socket) do
    Process.send_after(self(), :do_screenshot, 2000)
    {:noreply, assign(socket, :screenshot_status, :waiting)}
  end

  @impl true
  def handle_event("take_screenshot", _, socket) do
    socket = assign(socket, :screenshot_status, :loading)

    case Capture.grab_frame() do
      {:ok, frame} ->
        case encode_jpeg(frame.mat) do
          {:ok, jpeg} ->
            b64 = Base.encode64(jpeg)
            {:noreply,
             socket
             |> assign(:screenshot_mat, frame.mat)
             |> assign(:screenshot_status, :done)
             |> push_event("load_screenshot", %{data: b64})}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:screenshot_status, :error)
             |> put_flash(:error, "Encode failed: #{inspect(reason)}")}
        end

      {:error, :no_window} ->
        {:noreply,
         socket
         |> assign(:screenshot_status, :error)
         |> put_flash(:error, "Game window not found. Start Limbus Company first.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:screenshot_status, :error)
         |> put_flash(:error, "Screenshot failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("region_selected", %{"x" => x, "y" => y, "w" => w, "h" => h}, socket) do
    region = %{x: x, y: y, w: w, h: h}
    existing = form_params(socket)

    updated_params =
      Map.merge(existing, %{
        "region_x" => to_string(x),
        "region_y" => to_string(y),
        "region_w" => to_string(w),
        "region_h" => to_string(h)
      })

    {:noreply,
     socket
     |> assign(:region, region)
     |> assign(:form, build_form(updated_params))}
  end

  @impl true
  def handle_event("clear_region", _, socket) do
    params =
      form_params(socket)
      |> Map.merge(%{"region_x" => "", "region_y" => "", "region_w" => "", "region_h" => ""})

    {:noreply,
     socket
     |> assign(:region, nil)
     |> assign(:form, build_form(params))
     |> push_event("clear_selection", %{})}
  end

  @impl true
  def handle_event("click_region_selected", %{"x" => x, "y" => y, "w" => w, "h" => h}, socket) do
    click_region = %{x: x, y: y, w: w, h: h}

    params =
      form_params(socket)
      |> Map.merge(%{
        "click_x" => to_string(x),
        "click_y" => to_string(y),
        "click_w" => to_string(w),
        "click_h" => to_string(h)
      })

    {:noreply,
     socket
     |> assign(:click_region, click_region)
     |> assign(:form, build_form(params))}
  end

  @impl true
  def handle_event("clear_click_region", _, socket) do
    params =
      form_params(socket)
      |> Map.merge(%{"click_x" => "", "click_y" => "", "click_w" => "", "click_h" => ""})

    {:noreply,
     socket
     |> assign(:click_region, nil)
     |> assign(:form, build_form(params))
     |> push_event("clear_click_selection", %{})}
  end

  @impl true
  def handle_event("scan_region_selected", %{"x" => x, "y" => y, "w" => w, "h" => h}, socket) do
    scan_region = %{x: x, y: y, w: w, h: h}

    params =
      form_params(socket)
      |> Map.merge(%{
        "scan_x" => to_string(x),
        "scan_y" => to_string(y),
        "scan_w" => to_string(w),
        "scan_h" => to_string(h)
      })

    {:noreply,
     socket
     |> assign(:scan_region, scan_region)
     |> assign(:form, build_form(params))}
  end

  @impl true
  def handle_event("clear_scan_region", _, socket) do
    params =
      form_params(socket)
      |> Map.merge(%{"scan_x" => "", "scan_y" => "", "scan_w" => "", "scan_h" => ""})

    {:noreply,
     socket
     |> assign(:scan_region, nil)
     |> assign(:form, build_form(params))
     |> push_event("clear_scan_selection", %{})}
  end

  @impl true
  def handle_event("set_canvas_mode", %{"mode" => mode}, socket) do
    canvas_mode =
      case mode do
        "click" -> :click
        "scan" -> :scan
        "color" -> :color
        _ -> :detect
      end

    {:noreply,
     socket
     |> assign(:canvas_mode, canvas_mode)
     |> push_event("set_canvas_mode", %{mode: mode})}
  end

  @impl true
  def handle_event("color_picked", %{"h" => h, "s" => s, "v" => v}, socket) do
    params =
      form_params(socket)
      |> Map.merge(%{"color_h" => to_string(h), "color_s" => to_string(s), "color_v" => to_string(v)})

    {:noreply, assign(socket, :form, build_form(params))}
  end

  @impl true
  def handle_event("validate_hook", %{"hook" => params}, socket) do
    {:noreply, assign(socket, :form, build_form(params))}
  end

  @impl true
  def handle_event("save_hook", %{"hook" => params}, socket) do
    mat = socket.assigns.screenshot_mat
    region = socket.assigns.region
    editing_name = socket.assigns.editing_name
    new_name = String.trim(params["name"] || "")

    cond do
      is_nil(mat) and is_nil(editing_name) ->
        {:noreply, put_flash(socket, :error, "Take a screenshot and select a region first.")}

      not is_nil(editing_name) and new_name != "" and editing_name != new_name ->
        # Name changed while editing — rename then apply any field updates
        with {:ok, _} <- Hooks.rename_hook(editing_name, new_name),
             {:ok, attrs} <- build_save_attrs(params, mat, region, new_name),
             {:ok, saved_name} <- Hooks.save_hook(attrs) do
          {:noreply,
           socket
           |> refresh_hooks()
           |> assign(:editing_name, saved_name)
           |> assign(:saved_params, Map.put(params, "name", saved_name))
           |> assign(:test_result, nil)
           |> put_flash(:info, "Hook renamed to '#{saved_name}'.")}
        else
          {:error, msg} -> {:noreply, flash_error(socket, "Rename failed: #{inspect(msg)}")}
        end

      true ->
        with {:ok, attrs} <- build_save_attrs(params, mat, region, editing_name) do
          case Hooks.save_hook(attrs) do
            {:ok, name} ->
              base =
                socket
                |> refresh_hooks()
                |> assign(:test_result, nil)
                |> put_flash(:info, "Hook '#{name}' saved.")

              socket =
                if is_nil(editing_name) do
                  base
                  |> assign(:form, blank_form())
                  |> assign(:editing_name, nil)
                  |> assign(:saved_params, nil)
                  |> assign(:region, nil)
                  |> assign(:click_region, nil)
                  |> assign(:scan_region, nil)
                  |> assign(:canvas_mode, :detect)
                  |> push_event("clear_selection", %{})
                  |> push_event("clear_click_selection", %{})
                  |> push_event("clear_scan_selection", %{})
                  |> push_event("set_canvas_mode", %{mode: "detect"})
                else
                  base
                  |> assign(:editing_name, name)
                  |> assign(:saved_params, Map.put(params, "name", name))
                end

              {:noreply, socket}

            {:error, reason} ->
              {:noreply, flash_error(socket, "Save failed: #{inspect(reason)}")}
          end
        else
          {:error, msg} -> {:noreply, flash_error(socket, msg)}
        end
    end
  end

  @impl true
  def handle_event("test_hook", %{"name" => name}, socket) do
    case Capture.grab_frame() do
      {:ok, frame} ->
        hook_atom = safe_to_atom(name)

        case hook_atom && Matcher.find_with_score(frame, hook_atom) do
          nil ->
            {:noreply, put_flash(socket, :error, "Invalid hook name.")}

          {:ok, score, match_result} ->
            result = case match_result do
              {:ok, {x, y, w, h}} -> %{found: true, score: Float.round(score, 4), rect: %{x: x, y: y, w: w, h: h}, mode: :full}
              :not_found -> %{found: false, score: Float.round(score, 4), rect: nil, mode: :full}
            end

            socket =
              socket
              |> assign(:test_result, result)
              |> assign_template(hook_atom)

            socket = case encode_jpeg(frame.mat) do
              {:ok, jpeg} ->
                s = push_event(socket, "load_screenshot", %{data: Base.encode64(jpeg)})
                if result.found,
                  do: push_event(s, "show_match", %{rect: result.rect, score: score}),
                  else: s
              _ -> socket
            end

            {:noreply, socket}

          {:error, :hook_not_found} ->
            {:noreply,
             put_flash(socket, :error, "Hook '#{name}' not in registry — save it first.")}
        end

      {:error, :no_window} ->
        {:noreply, put_flash(socket, :error, "Game window not found.")}

      {:error, reason} ->
        {:noreply, flash_error(socket, "Screenshot failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("test_hook_region", %{"name" => name}, socket) do
    hook_atom = safe_to_atom(name)

    if is_nil(hook_atom) do
      {:noreply, put_flash(socket, :error, "Invalid hook name.")}
    else
      case HookRegistry.find(hook_atom) do
        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "Hook '#{name}' not in registry — save it first.")}

        {:ok, %{method: :color_detector, region: nil}} ->
          {:noreply, put_flash(socket, :error, "This hook has no region defined — use full Test instead.")}

        {:ok, %{method: :grayscale_detector, region: nil}} ->
          {:noreply, put_flash(socket, :error, "This hook has no region defined — use full Test instead.")}

        {:ok, %{region: nil, scan_region: nil}} ->
          {:noreply, put_flash(socket, :error, "This hook has no region defined — use full Test instead.")}

        {:ok, hook} ->
          search_region =
            if hook.method in [:color_detector, :grayscale_detector],
              do: hook.region,
              else: hook.scan_region || hook.region

          {_rx, _ry, rw, rh} = search_region

          case Capture.grab_region(search_region) do
            {:error, :no_window} ->
              {:noreply, put_flash(socket, :error, "Game window not found.")}

            {:error, reason} ->
              {:noreply, flash_error(socket, "Region capture failed: #{inspect(reason)}")}

            {:ok, mat} ->
              case Matcher.score_against_mat(mat, hook_atom) do
                {:error, reason} ->
                  {:noreply, flash_error(socket, "Match failed: #{inspect(reason)}")}

                {:ok, score, match_result} ->
                  # Scale match rect from region space (rw×rh) to canvas space (1920×1080)
                  result_rect = case match_result do
                    {:ok, {x, y, w, h}} ->
                      %{x: round(x * 1920 / rw), y: round(y * 1080 / rh),
                        w: round(w * 1920 / rw), h: round(h * 1080 / rh)}
                    :not_found -> nil
                  end

                  result = %{
                    found: match_result != :not_found,
                    score: Float.round(score, 4),
                    rect: result_rect,
                    mode: :region
                  }

                  socket =
                    socket
                    |> assign(:test_result, result)
                    |> assign_template(hook_atom)

                  socket = case encode_jpeg(mat) do
                    {:ok, jpeg} ->
                      s = push_event(socket, "load_screenshot", %{data: Base.encode64(jpeg)})
                      if result.found,
                        do: push_event(s, "show_match", %{rect: result_rect, score: score}),
                        else: s
                    _ -> socket
                  end

                  {:noreply, socket}
              end
          end
      end
    end
  end

  @impl true
  def handle_event("edit_hook", %{"name" => name}, socket) do
    case Hooks.get_hook(name) do
      nil ->
        {:noreply, put_flash(socket, :error, "Hook not found.")}

      hook ->
        params = %{
          "name" => hook.name,
          "match_method" => hook.match_method,
          "feature_channel" => hook.feature_channel || "gray",
          "confidence" => to_string(hook.confidence),
          "notes" => hook.notes || "",
          "region_x" => to_string(hook.region_x || ""),
          "region_y" => to_string(hook.region_y || ""),
          "region_w" => to_string(hook.region_w || ""),
          "region_h" => to_string(hook.region_h || ""),
          "click_x" => to_string(hook.click_x || ""),
          "click_y" => to_string(hook.click_y || ""),
          "click_w" => to_string(hook.click_w || ""),
          "click_h" => to_string(hook.click_h || ""),
          "scan_x" => to_string(hook.scan_x || ""),
          "scan_y" => to_string(hook.scan_y || ""),
          "scan_w" => to_string(hook.scan_w || ""),
          "scan_h" => to_string(hook.scan_h || ""),
          "mask" => mask_param(hook.mask),
          "color_h" => to_string(hook.color_h || ""),
          "color_s" => to_string(hook.color_s || ""),
          "color_v" => to_string(hook.color_v || ""),
          "min_cluster_size" => to_string(hook.min_cluster_size || "")
        }

        region =
          if hook.region_x && hook.region_y && hook.region_w && hook.region_h,
            do: %{x: hook.region_x, y: hook.region_y, w: hook.region_w, h: hook.region_h},
            else: nil

        click_region =
          if hook.click_x && hook.click_y && hook.click_w && hook.click_h,
            do: %{x: hook.click_x, y: hook.click_y, w: hook.click_w, h: hook.click_h},
            else: nil

        scan_region =
          if hook.scan_x && hook.scan_y && hook.scan_w && hook.scan_h,
            do: %{x: hook.scan_x, y: hook.scan_y, w: hook.scan_w, h: hook.scan_h},
            else: nil

        socket =
          socket
          |> push_event(if(region, do: "set_selection", else: "clear_selection"), region || %{})
          |> push_event(if(click_region, do: "set_click_selection", else: "clear_click_selection"), click_region || %{})
          |> push_event(if(scan_region, do: "set_scan_selection", else: "clear_scan_selection"), scan_region || %{})
          |> push_event("set_canvas_mode", %{mode: "detect"})

        {:noreply,
         socket
         |> assign(:form, build_form(params))
         |> assign(:editing_name, name)
         |> assign(:region, region)
         |> assign(:click_region, click_region)
         |> assign(:scan_region, scan_region)
         |> assign(:canvas_mode, :detect)
         |> assign(:screenshot_mat, nil)
         |> assign(:screenshot_status, :idle)
         |> assign(:test_result, nil)
         |> assign(:saved_params, params)}
    end
  end

  @impl true
  def handle_event("new_hook", _, socket) do
    region = socket.assigns.region
    scan_region = socket.assigns.scan_region

    params = %{"match_method" => "gray", "feature_channel" => "gray", "confidence" => "0.85", "min_cluster_size" => "50"}
    params = if region do
      Map.merge(params, %{
        "region_x" => to_string(region.x),
        "region_y" => to_string(region.y),
        "region_w" => to_string(region.w),
        "region_h" => to_string(region.h)
      })
    else
      params
    end
    params = if scan_region do
      Map.merge(params, %{
        "scan_x" => to_string(scan_region.x),
        "scan_y" => to_string(scan_region.y),
        "scan_w" => to_string(scan_region.w),
        "scan_h" => to_string(scan_region.h)
      })
    else
      params
    end
    params = Map.merge(params, %{"click_x" => "", "click_y" => "", "click_w" => "", "click_h" => ""})

    {:noreply,
     socket
     |> assign(:form, build_form(params))
     |> assign(:editing_name, nil)
     |> assign(:saved_params, nil)
     |> assign(:click_region, nil)
     |> assign(:canvas_mode, :detect)
     |> assign(:test_result, nil)
     |> push_event("set_canvas_mode", %{mode: "detect"})}
  end

  @impl true
  def handle_event("delete_hook", %{"name" => name}, socket) do
    case Hooks.delete_hook(name) do
      {:ok, _} ->
        editing_name =
          if socket.assigns.editing_name == name, do: nil, else: socket.assigns.editing_name

        {:noreply,
         socket
         |> assign(:hooks, Hooks.list_hooks())
         |> assign(:editing_name, editing_name)
         |> put_flash(:info, "Deleted '#{name}'.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Hook '#{name}' not found.")}
    end
  end

  @impl true
  def handle_event("save_notes", %{"name" => name, "value" => value}, socket) do
    case Hooks.update_notes(name, value) do
      {:ok, _} -> {:noreply, refresh_hooks(socket)}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set_duplicate_name", %{"value" => val}, socket) do
    {:noreply, assign(socket, :duplicate_name, val)}
  end

  @impl true
  def handle_event("duplicate_hook", %{"source" => source}, socket) do
    new_name = String.trim(socket.assigns.duplicate_name)

    if new_name == "" do
      {:noreply, put_flash(socket, :error, "Enter a name for the duplicate.")}
    else
      case Hooks.duplicate_hook(source, new_name) do
        {:ok, _} ->
          {:noreply,
           socket
           |> refresh_hooks()
           |> assign(:duplicate_name, "")
           |> put_flash(:info, "Duplicated as '#{new_name}'.")}

        {:error, reason} ->
          {:noreply, flash_error(socket, "Duplicate failed: #{inspect(reason)}")}
      end
    end
  end

  @impl true
  def handle_event("save_screenshot", _, socket) do
    case socket.assigns.screenshot_mat do
      nil ->
        {:noreply, put_flash(socket, :error, "No screenshot to save.")}

      mat ->
        dir = Path.join(File.cwd!(), "screenshots")
        File.mkdir_p!(dir)
        ts = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d_%H-%M-%S")
        path = Path.join(dir, "#{ts}.jpg")

        case encode_jpeg(mat) do
          {:ok, jpeg} ->
            File.write!(path, jpeg)
            {:noreply, put_flash(socket, :info, "Saved screenshots/#{ts}.jpg")}

          {:error, reason} ->
            {:noreply, flash_error(socket, "Save failed: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def handle_event("save_raw_screenshot", _, socket) do
    case Capture.grab_frame_raw() do
      {:ok, mat, w, h} ->
        dir = Path.join(File.cwd!(), "screenshots")
        File.mkdir_p!(dir)
        ts = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d_%H-%M-%S")
        path = Path.join(dir, "#{ts}_raw_#{w}x#{h}.png")

        case Evision.imwrite(path, mat) do
          true ->
            {:noreply, put_flash(socket, :info, "Saved screenshots/#{ts}_raw_#{w}x#{h}.png")}

          _ ->
            {:noreply, flash_error(socket, "Save failed")}
        end

      {:error, :no_window} ->
        {:noreply, put_flash(socket, :error, "Game window not found. Start Limbus Company first.")}

      {:error, reason} ->
        {:noreply, flash_error(socket, "Raw screenshot failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("filter_hooks", %{"value" => val}, socket) do
    {:noreply, assign(socket, :hooks_filter, val)}
  end

  @impl true
  def handle_event("sort_hooks", %{"by" => by}, socket) do
    col =
      try do
        String.to_existing_atom(by)
      rescue
        _ -> socket.assigns.sort_by
      end

    {sort_by, sort_dir} =
      if socket.assigns.sort_by == col do
        {col, if(socket.assigns.sort_dir == :asc, do: :desc, else: :asc)}
      else
        {col, :asc}
      end

    {:noreply, socket |> assign(:sort_by, sort_by) |> assign(:sort_dir, sort_dir)}
  end

  @impl true
  def handle_event("use_hook_region", %{"x" => x, "y" => y, "w" => w, "h" => h}, socket) do
    region = %{
      x: String.to_integer(x),
      y: String.to_integer(y),
      w: String.to_integer(w),
      h: String.to_integer(h)
    }

    case socket.assigns.canvas_mode do
      :detect ->
        params =
          form_params(socket)
          |> Map.merge(%{
            "region_x" => to_string(region.x),
            "region_y" => to_string(region.y),
            "region_w" => to_string(region.w),
            "region_h" => to_string(region.h)
          })

        {:noreply,
         socket
         |> assign(:region, region)
         |> assign(:form, build_form(params))
         |> push_event("set_selection", region)}

      :click ->
        params =
          form_params(socket)
          |> Map.merge(%{
            "click_x" => to_string(region.x),
            "click_y" => to_string(region.y),
            "click_w" => to_string(region.w),
            "click_h" => to_string(region.h)
          })

        {:noreply,
         socket
         |> assign(:click_region, region)
         |> assign(:form, build_form(params))
         |> push_event("set_click_selection", region)}

      :scan ->
        params =
          form_params(socket)
          |> Map.merge(%{
            "scan_x" => to_string(region.x),
            "scan_y" => to_string(region.y),
            "scan_w" => to_string(region.w),
            "scan_h" => to_string(region.h)
          })

        {:noreply,
         socket
         |> assign(:scan_region, region)
         |> assign(:form, build_form(params))
         |> push_event("set_scan_selection", region)}

      :color ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("use_hook_regions", params, socket) do
    region =
      parse_region_values(params["region-x"], params["region-y"], params["region-w"], params["region-h"])

    click_region =
      parse_region_values(params["click-x"], params["click-y"], params["click-w"], params["click-h"])

    scan_region =
      parse_region_values(params["scan-x"], params["scan-y"], params["scan-w"], params["scan-h"])

    params =
      form_params(socket)
      |> Map.merge(region_form_params("region", region))
      |> Map.merge(region_form_params("click", click_region))
      |> Map.merge(region_form_params("scan", scan_region))

    socket =
      socket
      |> assign(:region, region)
      |> assign(:click_region, click_region)
      |> assign(:scan_region, scan_region)
      |> assign(:form, build_form(params))
      |> push_region_event(region, "set_selection", "clear_selection")
      |> push_region_event(click_region, "set_click_selection", "clear_click_selection")
      |> push_region_event(scan_region, "set_scan_selection", "clear_scan_selection")

    {:noreply, socket}
  end

  @impl true
  def handle_event("open_template_editor", %{"name" => name}, socket) do
    case Hooks.get_hook(name) do
      nil ->
        {:noreply, put_flash(socket, :error, "Hook not found.")}

      %{image: nil} ->
        {:noreply, put_flash(socket, :error, "Hook has no template image — save it first.")}

      %{image: png} ->
        {:noreply, push_event(socket, "load_template_editor", %{data: Base.encode64(png), name: name})}
    end
  end

  @impl true
  def handle_event("save_template_mask", %{"name" => name, "data" => b64}, socket) do
    case Base.decode64(b64) do
      {:ok, png} ->
        case Hooks.update_hook_image(name, png) do
          {:ok, _} ->
            {:noreply,
             socket
             |> refresh_hooks()
             |> assign(:template_b64, nil)
             |> put_flash(:info, "Template updated.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
        end

      :error ->
        {:noreply, put_flash(socket, :error, "Invalid image data from editor.")}
    end
  end

  @impl true
  def handle_params(%{"from_cache" => "1"}, _uri, socket) do
    case load_handoff_screenshot() do
      {:ok, mat, b64} ->
        {:noreply,
         socket
         |> assign(:screenshot_mat, mat)
         |> assign(:screenshot_status, :done)
         |> push_event("load_screenshot", %{data: b64})}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to load frame from screenshot stream.")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:do_screenshot, socket) do
    socket = assign(socket, :screenshot_status, :loading)

    case Capture.grab_frame() do
      {:ok, frame} ->
        case encode_jpeg(frame.mat) do
          {:ok, jpeg} ->
            b64 = Base.encode64(jpeg)
            {:noreply,
             socket
             |> assign(:screenshot_mat, frame.mat)
             |> assign(:screenshot_status, :done)
             |> push_event("load_screenshot", %{data: b64})}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:screenshot_status, :error)
             |> put_flash(:error, "Encode failed: #{inspect(reason)}")}
        end

      {:error, :no_window} ->
        {:noreply,
         socket
         |> assign(:screenshot_status, :error)
         |> put_flash(:error, "Game window not found. Start Limbus Company first.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:screenshot_status, :error)
         |> put_flash(:error, "Screenshot failed: #{inspect(reason)}")}
    end
  end

  defp refresh_hooks(socket) do
    socket
    |> assign(:hooks, Hooks.list_hooks())
    |> assign(:hook_thumbnails, Hooks.hook_thumbnails())
  end

  defp blank_form do
    build_form(%{"match_method" => "gray", "feature_channel" => "gray", "confidence" => "0.85", "min_cluster_size" => "50"})
  end

  defp build_form(params) do
    types = %{
      name: :string,
      match_method: :string,
      feature_channel: :string,
      confidence: :float,
      notes: :string,
      region_x: :integer,
      region_y: :integer,
      region_w: :integer,
      region_h: :integer,
      click_x: :integer,
      click_y: :integer,
      click_w: :integer,
      click_h: :integer,
      scan_x: :integer,
      scan_y: :integer,
      scan_w: :integer,
      scan_h: :integer,
      mask: :boolean,
      color_h: :integer,
      color_s: :integer,
      color_v: :integer,
      min_cluster_size: :integer
    }

    changeset =
      {%{}, types}
      |> Ecto.Changeset.cast(params, Map.keys(types))
      |> Ecto.Changeset.validate_required([:name, :match_method, :confidence])
      |> Ecto.Changeset.validate_inclusion(:match_method,
        ~w(gray rgb edge akaze sift binary_thresh color_detector grayscale_detector))
      |> Ecto.Changeset.validate_inclusion(:feature_channel, ~w(gray saturation))
      |> Ecto.Changeset.validate_number(:confidence,
        greater_than_or_equal_to: 0.0,
        less_than_or_equal_to: 1.0)
      |> Ecto.Changeset.validate_number(:color_h,
        greater_than_or_equal_to: 0, less_than_or_equal_to: 179)
      |> Ecto.Changeset.validate_number(:color_s,
        greater_than_or_equal_to: 0, less_than_or_equal_to: 255)
      |> Ecto.Changeset.validate_number(:color_v,
        greater_than_or_equal_to: 0, less_than_or_equal_to: 255)
      |> Ecto.Changeset.validate_number(:min_cluster_size, greater_than_or_equal_to: 0)

    to_form(changeset, as: :hook)
  end

  defp form_params(socket) do
    Enum.into(socket.assigns.form.params || %{}, %{}, fn {k, v} ->
      {to_string(k), to_string(v || "")}
    end)
  end

  defp build_save_attrs(params, mat, region, editing_name) do
    name = String.trim(params["name"] || "")

    if name == "" do
      {:error, "Hook name is required."}
    else
      region_x = parse_int(params["region_x"])
      region_y = parse_int(params["region_y"])
      region_w = parse_int(params["region_w"])
      region_h = parse_int(params["region_h"])

      image =
        cond do
          # New hook: crop the selected region from the screenshot
          not is_nil(mat) and not is_nil(region) ->
            crop_to_png(mat, region)

          # Editing existing hook without a new screenshot: keep existing image
          not is_nil(editing_name) ->
            nil

          true ->
            nil
        end

      if is_nil(image) and is_nil(editing_name) do
        {:error, "Take a screenshot and select a region first."}
      else
        {:ok,
         %{
           name: name,
           image: image,
           region_x: region_x,
           region_y: region_y,
           region_w: region_w,
           region_h: region_h,
           click_x: parse_int(params["click_x"]),
           click_y: parse_int(params["click_y"]),
           click_w: parse_int(params["click_w"]),
           click_h: parse_int(params["click_h"]),
           scan_x: parse_int(params["scan_x"]),
           scan_y: parse_int(params["scan_y"]),
           scan_w: parse_int(params["scan_w"]),
           scan_h: parse_int(params["scan_h"]),
           mask: params["mask"] == "true",
           color_h: parse_int(params["color_h"]),
           color_s: parse_int(params["color_s"]),
           color_v: parse_int(params["color_v"]),
           min_cluster_size: parse_int(params["min_cluster_size"]),
           match_method: params["match_method"] || "gray",
           feature_channel: params["feature_channel"] || "gray",
           confidence: parse_float(params["confidence"], 0.85),
           notes: params["notes"]
         }}
      end
    end
  end

  defp crop_to_png(mat, %{x: x, y: y, w: w, h: h}) do
    crop = Evision.Mat.roi(mat, {x, y, w, h})
    tmp = "/tmp/_starlight_hook_crop.png"
    Evision.imwrite(tmp, crop)

    case File.read(tmp) do
      {:ok, data} -> data
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp encode_jpeg(mat) do
    tmp = "/tmp/_starlight_screenshot_display.jpg"
    Evision.imwrite(tmp, mat)
    File.read(tmp)
  rescue
    e -> {:error, Exception.message(e)}
  end

  @handoff_path "/tmp/_starlight_hook_handoff.jpg"

  defp load_handoff_screenshot do
    mat = Evision.imread(@handoff_path)
    case encode_jpeg(mat) do
      {:ok, jpeg} -> {:ok, mat, Base.encode64(jpeg)}
      {:error, _} = err -> err
    end
  rescue
    _ -> {:error, :load_failed}
  end

  defp flash_error(socket, msg) do
    Logger.error("HookEditor flash error: #{msg}", module: __MODULE__)
    put_flash(socket, :error, msg)
  end

  defp assign_template(socket, hook_atom) do
    with {:ok, hook} <- HookRegistry.find(hook_atom),
         {:ok, jpeg} <- encode_jpeg(hook.mat) do
      assign(socket, :template_b64, Base.encode64(jpeg))
    else
      _ -> socket
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end
  defp parse_int(n) when is_integer(n), do: n

  defp parse_float(nil, default), do: default
  defp parse_float("", default), do: default
  defp parse_float(s, default) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> default
    end
  end
  defp parse_float(f, _) when is_float(f), do: f

  defp parse_region_values(x, y, w, h) do
    case {parse_int(x), parse_int(y), parse_int(w), parse_int(h)} do
      {nil, _, _, _} -> nil
      {x, y, w, h} -> %{x: x, y: y, w: w, h: h}
    end
  end

  defp region_form_params(prefix, nil) do
    %{"#{prefix}_x" => "", "#{prefix}_y" => "", "#{prefix}_w" => "", "#{prefix}_h" => ""}
  end

  defp region_form_params(prefix, %{x: x, y: y, w: w, h: h}) do
    %{
      "#{prefix}_x" => to_string(x),
      "#{prefix}_y" => to_string(y),
      "#{prefix}_w" => to_string(w),
      "#{prefix}_h" => to_string(h)
    }
  end

  defp push_region_event(socket, nil, _set_event, clear_event), do: push_event(socket, clear_event, %{})
  defp push_region_event(socket, region, set_event, _clear_event), do: push_event(socket, set_event, region)

  defp mask_param(val), do: if(val in [true, "true", 1], do: "true", else: "false")

  defp safe_to_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    _ -> nil
  end

  def filtered_hooks(hooks, ""), do: hooks

  def filtered_hooks(hooks, filter) do
    f = String.downcase(filter)
    Enum.filter(hooks, fn h -> String.contains?(String.downcase(h.name), f) end)
  end

  def sorted_hooks(hooks, sort_by, sort_dir) do
    Enum.sort_by(hooks, &sort_key(&1, sort_by), sort_dir)
  end

  def thumb_src(nil), do: nil
  def thumb_src(image), do: "data:image/png;base64,#{Base.encode64(image)}"

  @doc "CSS color for the color_detector swatch preview, from OpenCV-scale HSV (h: 0-179, s/v: 0-255)."
  def color_swatch_css(h, s, v) when is_integer(h) and is_integer(s) and is_integer(v) do
    # OpenCV hue is 0-179 (degrees/2), so degrees/60 == h/30
    hue60 = h / 30.0
    sat = s / 255.0
    val = v / 255.0

    i = trunc(hue60) |> rem(6)
    f = hue60 - trunc(hue60)
    p = val * (1 - sat)
    q = val * (1 - f * sat)
    t = val * (1 - (1 - f) * sat)

    {r, g, b} =
      case i do
        0 -> {val, t, p}
        1 -> {q, val, p}
        2 -> {p, val, t}
        3 -> {p, q, val}
        4 -> {t, p, val}
        _ -> {val, p, q}
      end

    "rgb(#{round(r * 255)}, #{round(g * 255)}, #{round(b * 255)})"
  end

  def color_swatch_css(_, _, _), do: "transparent"

  def canvas_mode_label(:click), do: "click"
  def canvas_mode_label(:scan), do: "scan"
  def canvas_mode_label(:color), do: "color"
  def canvas_mode_label(_), do: "detect"

  def mask_on?(val), do: val in [true, "true", 1]

  defp sort_key(hook, :name), do: String.downcase(hook.name || "")
  defp sort_key(hook, :match_method), do: hook.match_method || ""
  defp sort_key(hook, :confidence), do: hook.confidence || 0.0
  defp sort_key(hook, :region), do: if(hook.region_x, do: 0, else: 1)
  defp sort_key(hook, :click), do: if(hook.click_x, do: 0, else: 1)
  defp sort_key(hook, :scan), do: if(hook.scan_x, do: 0, else: 1)
  defp sort_key(hook, :mask), do: if(mask_on?(hook.mask), do: 0, else: 1)
  defp sort_key(hook, :notes), do: String.downcase(hook.notes || "")
  defp sort_key(hook, :inserted_at), do: to_string(hook.inserted_at || "")
  defp sort_key(hook, _), do: String.downcase(hook.name || "")

  def field_dirty?(_form, nil, _field), do: false

  def field_dirty?(form, saved_params, field) do
    value = form[field].value
    current = to_string(if is_nil(value), do: "", else: value)
    saved   = to_string(Map.get(saved_params, to_string(field), ""))
    String.trim(current) != String.trim(saved)
  end
end
