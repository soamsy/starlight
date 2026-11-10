defmodule StarlightBotWeb.Live.HookEditorLive do
  use StarlightBotWeb, :live_view

  require Logger
  alias StarlightBot.{Hooks, Vision.Capture, Vision.HookRegistry, Vision.Matcher}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:category, "general")
     |> assign(:overwrite_image, true)
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
     |> assign(:saved_params, nil)}
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
     |> assign(:overwrite_image, true)
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

  @region_prefixes ~w(region click scan)

  @impl true
  def handle_event("copy_region", %{"from" => from, "to" => to}, socket)
      when from in @region_prefixes and to in @region_prefixes do
    params = form_params(socket)

    case parse_region_values(params["#{from}_x"], params["#{from}_y"], params["#{from}_w"], params["#{from}_h"]) do
      nil ->
        {:noreply, socket}

      region ->
        {:noreply,
         socket
         |> assign(region_assign_key(to), region)
         |> enable_overwrite_for(to)
         |> assign(:form, build_form(Map.merge(params, region_form_params(to, region))))
         |> push_event(region_set_event(to), region)}
    end
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
      |> put_default_tolerances()

    {:noreply, assign(socket, :form, build_form(params))}
  end

  @impl true
  def handle_event("toggle_overwrite_image", _, socket) do
    {:noreply, assign(socket, :overwrite_image, !socket.assigns.overwrite_image)}
  end

  @impl true
  def handle_event("validate_hook", %{"hook" => params}, socket) do
    old_params = form_params(socket)
    socket = if region_params_changed?(old_params, params), do: assign(socket, :overwrite_image, true), else: socket

    socket =
      Enum.reduce(@region_prefixes, socket, fn prefix, acc ->
        sync_region_from_params(acc, prefix, old_params, params)
      end)

    {:noreply, assign(socket, :form, build_form(params))}
  end

  @impl true
  def handle_event("save_hook", %{"hook" => params}, socket) do
    mat = socket.assigns.screenshot_mat
    region = socket.assigns.region
    editing_name = socket.assigns.editing_name
    overwrite_image = socket.assigns.overwrite_image
    new_name = String.trim(params["name"] || "")

    cond do
      is_nil(mat) and is_nil(editing_name) ->
        {:noreply, put_flash(socket, :error, "Take a screenshot and select a region first.")}

      not is_nil(editing_name) and new_name != "" and editing_name != new_name ->
        # Name changed while editing — rename then apply any field updates
        with {:ok, _} <- Hooks.rename_hook(editing_name, new_name),
             {:ok, attrs} <- build_save_attrs(params, mat, region, new_name, overwrite_image),
             {:ok, saved_name} <- Hooks.save_hook(attrs) do
          {:noreply,
           socket
           |> show_category(attrs.category)
           |> assign(:editing_name, saved_name)
           |> assign(:saved_params, Map.put(params, "name", saved_name))
           |> assign(:test_result, nil)
           |> assign_template(safe_to_atom(saved_name))
           |> put_flash(:info, "Hook renamed to '#{saved_name}'.")}
        else
          {:error, msg} -> {:noreply, flash_error(socket, "Rename failed: #{inspect(msg)}")}
        end

      true ->
        with {:ok, attrs} <- build_save_attrs(params, mat, region, editing_name, overwrite_image) do
          case Hooks.save_hook(attrs) do
            {:ok, name} ->
              base =
                socket
                |> show_category(attrs.category)
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
                  |> assign_template(safe_to_atom(name))
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
    hook_atom = safe_to_atom(name)

    if is_nil(hook_atom) do
      {:noreply, put_flash(socket, :error, "Invalid hook name.")}
    else
      case Capture.grab_frame() do
        {:ok, frame} ->
          case Matcher.find_with_score(frame, hook_atom) do
            {:ok, score, match_result} ->
              rect =
                case match_result do
                  {:ok, {x, y, w, h}} -> %{x: x, y: y, w: w, h: h}
                  :not_found -> nil
                end

              result = %{name: name, found: rect != nil, score: Float.round(score, 4), rect: rect}
              {:noreply,
               socket
               |> assign(:screenshot_mat, frame.mat)
               |> assign(:screenshot_status, :done)
               |> assign(:overwrite_image, false)
               |> show_test_result(result, frame.mat)}

            {:error, :hook_not_found} ->
              {:noreply, put_flash(socket, :error, "Hook '#{name}' not in registry — save it first.")}
          end

        {:error, :no_window} ->
          {:noreply, put_flash(socket, :error, "Game window not found.")}

        {:error, reason} ->
          {:noreply, flash_error(socket, "Screenshot failed: #{inspect(reason)}")}
      end
    end
  end

  @impl true
  def handle_event("test_hook_all", %{"name" => name}, socket) do
    case socket.assigns.screenshot_mat do
      nil ->
        {:noreply, put_flash(socket, :error, "No screenshot loaded. Take one first.")}

      mat ->
        frame = %StarlightBot.Vision.Frame{binary: nil, mat: mat, window_rect: {0, 0, 1920, 1080}, scale: 1.0, captured_at: System.monotonic_time(:millisecond)}
        hook_atom = safe_to_atom(name)

        case hook_atom && Matcher.find_all_with_scores(frame, hook_atom) do
          nil ->
            {:noreply, put_flash(socket, :error, "Invalid hook name.")}

          {:error, :hook_not_found} ->
            {:noreply,
             put_flash(socket, :error, "Hook '#{name}' not in registry — save it first.")}

          {:ok, matches} ->
            match_maps =
              matches
              |> Enum.sort_by(fn {_rect, score} -> score end, :desc)
              |> Enum.map(fn {{x, y, w, h}, score} ->
                %{rect: %{x: x, y: y, w: w, h: h}, score: Float.round(score * 1.0, 4)}
              end)

            best = List.first(match_maps)

            result = %{
              name: name,
              found: best != nil,
              score: if(best, do: best.score, else: 0.0),
              rect: best && best.rect,
              mode: :all,
              matches: match_maps
            }

            socket = assign(socket, :test_result, result)

            socket =
              case encode_jpeg(frame.mat) do
                {:ok, jpeg} ->
                  socket
                  |> push_event("load_screenshot", %{data: Base.encode64(jpeg)})
                  |> push_event("show_matches", %{matches: match_maps})

                _ ->
                  socket
              end

            {:noreply, socket}
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
          "confidence" => to_string(hook.confidence),
          "notes" => hook.notes || "",
          "category" => hook.category,
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
          "tol_h" => to_string(hook.tol_h || ""),
          "tol_s" => to_string(hook.tol_s || ""),
          "tol_v" => to_string(hook.tol_v || ""),
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
         |> assign(:overwrite_image, true)
         |> assign(:test_result, nil)
         |> assign(:saved_params, params)
         |> assign_template(safe_to_atom(name))}
    end
  end

  @impl true
  def handle_event("new_hook", _, socket) do
    region = socket.assigns.region
    scan_region = socket.assigns.scan_region

    params = %{"match_method" => "gray", "confidence" => "0.85", "min_cluster_size" => "50"}
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
     |> assign(:template_b64, nil)
     |> push_event("set_canvas_mode", %{mode: "detect"})}
  end

  @impl true
  def handle_event("override_hook", %{"name" => name}, socket) do
    {:noreply, hook_action(socket, Hooks.override_hook(name), "Created your override of '#{name}'.")}
  end

  @impl true
  def handle_event("reapply_hook", %{"name" => name}, socket) do
    {:noreply, hook_action(socket, Hooks.reapply_hook(name), "Re-applied your override of '#{name}'.")}
  end

  @impl true
  def handle_event("bump_version", %{"name" => name}, socket) do
    {:noreply, hook_action(socket, Hooks.bump_version(name), "Bumped '#{name}' to a new version.")}
  end

  @impl true
  def handle_event("delete_hook", %{"name" => name}, socket) do
    case Hooks.delete_hook(name) do
      {:ok, _} ->
        editing_name =
          if socket.assigns.editing_name == name, do: nil, else: socket.assigns.editing_name

        {:noreply,
         socket
         |> refresh_hooks()
         |> assign(:editing_name, editing_name)
         |> put_flash(:info, "Deleted '#{name}'.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Hook '#{name}' not found.")}

      {:error, reason} ->
        {:noreply, flash_error(socket, "Couldn't delete '#{name}': #{inspect(reason)}")}
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
  def handle_event("duplicate_hook", %{"source" => source}, socket) do
    new_name = source <> "_copy"

    case Hooks.duplicate_hook(source, new_name) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_hooks()
         |> put_flash(:info, "Duplicated as '#{new_name}'.")}

      {:error, reason} ->
        {:noreply, flash_error(socket, "Duplicate failed: #{inspect(reason)}")}
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
  def handle_event("use_hook_region", %{"x" => x, "y" => y, "w" => w, "h" => h, "kind" => kind}, socket) do
    region = %{
      x: String.to_integer(x),
      y: String.to_integer(y),
      w: String.to_integer(w),
      h: String.to_integer(h)
    }

    case kind do
      "detect" ->
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
         |> assign(:overwrite_image, true)
         |> assign(:form, build_form(params))
         |> push_event("set_selection", region)}

      "click" ->
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

      "scan" ->
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
    end
  end

  @impl true
  def handle_event("download_template", %{"name" => name}, socket), do: {:noreply, push_template(socket, name, "download_template")}

  @impl true
  def handle_event("copy_template", %{"name" => name}, socket), do: {:noreply, push_template(socket, name, "copy_template")}

  @impl true
  def handle_event("upload_template", %{"name" => name, "data" => b64}, socket) do
    case Base.decode64(b64) do
      {:ok, png} ->
        case Hooks.update_hook_image(name, png) do
          {:ok, _} ->
            {:noreply,
             socket
             |> refresh_hooks()
             |> assign_template(safe_to_atom(name))
             |> put_flash(:info, "Template updated.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
        end

      :error ->
        {:noreply, put_flash(socket, :error, "Invalid image data from editor.")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    category = if params["cat"] in Hooks.categories(), do: params["cat"], else: "general"
    socket = socket |> assign(:category, category) |> refresh_hooks()

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

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp hook_action(socket, {:ok, _name}, message), do: socket |> refresh_hooks() |> put_flash(:info, message)
  defp hook_action(socket, {:error, reason}, _message), do: flash_error(socket, "Failed: #{inspect(reason)}")

  def hook_for(_hooks, nil), do: nil
  def hook_for(hooks, name), do: Enum.find(hooks, &(&1.name == name))

  def deletable?(nil), do: true
  def deletable?(hook), do: Hooks.editable?(hook)

  def source_label(%{source: :base, retired: true}), do: "override retired"
  def source_label(%{source: :base}), do: "shipped"
  def source_label(%{source: :override}), do: "your override"
  def source_label(%{source: :user}), do: "yours"

  def source_badge_class(%{source: :base, retired: true}), do: "badge-warning"
  def source_badge_class(%{source: :base}), do: "badge-ghost"
  def source_badge_class(%{source: :override}), do: "badge-accent"
  def source_badge_class(%{source: :user}), do: "badge-success"

  def source_help(%{source: :base, retired: true}),
    do: "The shipped hook was updated after you overrode it, so your override is paused and the shipped hook is in use."

  def source_help(%{source: :base} = hook) do
    if Hooks.editable?(hook),
      do: "Shipped with the app. Editing here changes the app's default hook.",
      else: "Shipped with the app and read-only. Override it to use your own region and template instead."
  end

  def source_help(%{source: :override}), do: "Your override is in use in place of the shipped hook."
  def source_help(%{source: :user}), do: "Created by you."

  defp refresh_hooks(socket) do
    category = socket.assigns.category
    rows = Hooks.list_hooks()
    hooks = Enum.filter(rows, &(&1.category == category))

    socket
    |> assign(:hooks, hooks)
    |> assign(:hook_thumbnails, Hooks.thumbnails_for(hooks))
    |> assign(:category_counts, Hooks.category_counts(rows))
  end

  defp show_category(socket, category) do
    if category == socket.assigns.category,
      do: refresh_hooks(socket),
      else: push_patch(socket, to: ~p"/hooks?#{[cat: category]}")
  end

  defp blank_form do
    build_form(%{"match_method" => "gray", "confidence" => "0.85", "min_cluster_size" => "50"})
  end

  defp build_form(params) do
    types = %{
      name: :string,
      match_method: :string,
      confidence: :float,
      notes: :string,
      category: :string,
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
      tol_h: :integer,
      tol_s: :integer,
      tol_v: :integer,
      min_cluster_size: :integer
    }

    changeset =
      {%{}, types}
      |> Ecto.Changeset.cast(params, Map.keys(types))
      |> Ecto.Changeset.validate_required([:name, :match_method, :confidence])
      |> Ecto.Changeset.validate_inclusion(:match_method,
        ~w(gray rgb sift sift_saturation binary_thresh hsv_range grayscale_detector))
      |> Ecto.Changeset.validate_number(:confidence,
        greater_than_or_equal_to: 0.0,
        less_than_or_equal_to: 1.0)
      |> Ecto.Changeset.validate_number(:color_h,
        greater_than_or_equal_to: 0, less_than_or_equal_to: 179)
      |> Ecto.Changeset.validate_number(:color_s,
        greater_than_or_equal_to: 0, less_than_or_equal_to: 255)
      |> Ecto.Changeset.validate_number(:color_v,
        greater_than_or_equal_to: 0, less_than_or_equal_to: 255)
      |> Ecto.Changeset.validate_number(:tol_h,
        greater_than_or_equal_to: 0, less_than_or_equal_to: 90)
      |> Ecto.Changeset.validate_number(:tol_s,
        greater_than_or_equal_to: 0, less_than_or_equal_to: 255)
      |> Ecto.Changeset.validate_number(:tol_v,
        greater_than_or_equal_to: 0, less_than_or_equal_to: 255)
      |> Ecto.Changeset.validate_number(:min_cluster_size, greater_than_or_equal_to: 0)

    to_form(changeset, as: :hook)
  end

  @default_tolerances %{"tol_h" => "5", "tol_s" => "30", "tol_v" => "30"}

  defp put_default_tolerances(params) do
    Enum.reduce(@default_tolerances, params, fn {key, default}, acc ->
      if Map.get(acc, key, "") == "", do: Map.put(acc, key, default), else: acc
    end)
  end

  defp form_params(socket) do
    Enum.into(socket.assigns.form.params || %{}, %{}, fn {k, v} ->
      {to_string(k), to_string(v || "")}
    end)
  end

  defp enable_overwrite_for(socket, "region"), do: assign(socket, :overwrite_image, true)
  defp enable_overwrite_for(socket, _prefix), do: socket

  defp region_params_changed?(old, new) do
    Enum.any?(~w(region_x region_y region_w region_h), fn key ->
      Map.has_key?(new, key) and to_string(new[key]) != Map.get(old, key, "")
    end)
  end

  defp build_save_attrs(params, mat, region, editing_name, overwrite_image) do
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
          not is_nil(mat) and not is_nil(region) and (overwrite_image or is_nil(editing_name)) ->
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
           tol_h: parse_int(params["tol_h"]),
           tol_s: parse_int(params["tol_s"]),
           tol_v: parse_int(params["tol_v"]),
           min_cluster_size: parse_int(params["min_cluster_size"]),
           match_method: params["match_method"] || "gray",
           confidence: parse_float(params["confidence"], 0.85),
           notes: params["notes"],
           category: Hooks.resolve_category(params["category"], name)
         }}
      end
    end
  end

  defp crop_to_png(mat, %{x: x, y: y, w: w, h: h}) do
    crop = StarlightBot.Vision.Frame.crop(mat, {x, y, w, h})
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

  defp flash_error(socket, msg) do
    Logger.error("HookEditor flash error: #{msg}", module: __MODULE__)
    put_flash(socket, :error, msg)
  end

  defp show_test_result(socket, result, mat) do
    socket = assign(socket, :test_result, result)

    case encode_jpeg(mat) do
      {:ok, jpeg} ->
        socket = push_event(socket, "load_screenshot", %{data: Base.encode64(jpeg)})

        if result.found,
          do: push_event(socket, "show_match", %{rect: result.rect, score: result.score}),
          else: socket

      _ ->
        socket
    end
  end

  attr :mat, :any, default: nil
  attr :region, :map, default: nil
  attr :editing, :boolean, default: false
  attr :overwrite, :boolean, default: true

  defp after_preview(%{mat: mat, region: %{x: x, y: y, w: w, h: h}} = assigns) when not is_nil(mat) do
    case encode_jpeg(StarlightBot.Vision.Frame.crop(mat, {x, y, w, h})) do
      {:ok, jpeg} ->
        assigns = assign(assigns, :src, "data:image/jpeg;base64," <> Base.encode64(jpeg))

        ~H"""
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-2 mb-1">
            <h3 class="font-semibold text-sm text-base-content/60">After</h3>
            <label :if={@editing} class="flex items-center gap-1 cursor-pointer ml-auto" title="When on, saving replaces the template image with this crop">
              <input type="checkbox" class="toggle toggle-xs toggle-warning" checked={@overwrite} phx-click="toggle_overwrite_image" />
              <span class="text-xs text-base-content/60">Overwrite on save</span>
            </label>
          </div>
          <img src={@src} alt="selected region"
               class="max-w-full max-h-40 object-contain rounded border border-warning"
               style="image-rendering: pixelated;" />
        </div>
        """

      _ ->
        ~H""
    end
  end

  defp after_preview(assigns), do: ~H""

  attr :result, :map, default: nil
  attr :name, :string, required: true

  defp test_badge(%{result: %{name: name}, name: name} = assigns) do
    ~H"""
    <span class="flex items-center gap-1 font-mono text-xs">
      <span :if={Map.get(@result, :mode) == :all} class={["badge badge-sm", if(@result.found, do: "badge-success", else: "badge-error")]}>
        <%= length(@result.matches) %> matches
      </span>
      <span :if={Map.get(@result, :mode) != :all} class={["badge badge-sm", if(@result.found, do: "badge-success", else: "badge-error")]}>
        <%= if @result.found, do: "match", else: "no match" %>
      </span>
      <span><%= @result.score %></span>
    </span>
    """
  end

  defp test_badge(assigns), do: ~H""

  defp push_template(socket, name, event) do
    case Hooks.get_hook(name) do
      %{image: png} when is_binary(png) ->
        push_event(socket, event, %{name: name, data: Base.encode64(png)})

      _ ->
        put_flash(socket, :error, "Hook has no template image.")
    end
  end

  defp assign_template(socket, nil), do: assign(socket, :template_b64, nil)

  defp assign_template(socket, hook_atom) do
    with {:ok, hook} <- HookRegistry.find(hook_atom),
         {:ok, jpeg} <- encode_jpeg(hook.mat) do
      assign(socket, :template_b64, Base.encode64(jpeg))
    else
      _ -> assign(socket, :template_b64, nil)
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

  defp sync_region_from_params(socket, prefix, old, new) do
    keys = Enum.map(~w(x y w h), &"#{prefix}_#{&1}")

    if Enum.any?(keys, &(Map.has_key?(new, &1) and to_string(new[&1]) != Map.get(old, &1, ""))) do
      values = Enum.map(keys, &parse_int(new[&1]))

      case values do
        [x, y, w, h] when is_integer(x) and is_integer(y) and is_integer(w) and is_integer(h) and w > 0 and h > 0 ->
          region = %{x: x, y: y, w: w, h: h}

          socket
          |> assign(region_assign_key(prefix), region)
          |> push_event(region_set_event(prefix), region)

        [nil, nil, nil, nil] ->
          socket
          |> assign(region_assign_key(prefix), nil)
          |> push_event(region_clear_event(prefix), %{})

        _ ->
          socket
      end
    else
      socket
    end
  end

  defp region_clear_event("region"), do: "clear_selection"
  defp region_clear_event("click"), do: "clear_click_selection"
  defp region_clear_event("scan"), do: "clear_scan_selection"

  defp region_form_params(prefix, %{x: x, y: y, w: w, h: h}) do
    %{
      "#{prefix}_x" => to_string(x),
      "#{prefix}_y" => to_string(y),
      "#{prefix}_w" => to_string(w),
      "#{prefix}_h" => to_string(h)
    }
  end

  defp region_assign_key("region"), do: :region
  defp region_assign_key("click"), do: :click_region
  defp region_assign_key("scan"), do: :scan_region

  defp region_set_event("region"), do: "set_selection"
  defp region_set_event("click"), do: "set_click_selection"
  defp region_set_event("scan"), do: "set_scan_selection"

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

  def category_label("general"), do: "General"
  def category_label("sleeve"), do: "Sleeve"
  def category_label("sleevesearch"), do: "Sleeve search"
  def category_label("locator"), do: "Locator"
  def category_label("team"), do: "Team"
  def category_label("team_selected"), do: "Team selected"

  def thumb_src(_hook, nil), do: nil
  def thumb_src(hook, version), do: ~p"/hooks/#{hook.name}/thumb.png?#{[v: version, s: hook.source]}"

  @channel_max %{h: 179, s: 255, v: 255}

  @doc "Inclusive bands a center ± tolerance covers on one channel; hue wraps around its ends."
  def range_bands(center, tol, :h) when is_integer(center) and is_integer(tol) do
    max = @channel_max.h
    lo = center - tol
    hi = center + tol

    cond do
      tol >= 90 -> [{0, max}]
      lo < 0 -> [{0, hi}, {max + 1 + lo, max}]
      hi > max -> [{lo, max}, {0, hi - max - 1}]
      true -> [{lo, hi}]
    end
  end

  def range_bands(center, tol, channel) when is_integer(center) and is_integer(tol) do
    [{max(center - tol, 0), min(center + tol, @channel_max[channel])}]
  end

  def range_bands(_, _, _), do: []

  @doc "Human label for a channel's range: a single value when it collapses, `any` when it spans the channel."
  def range_label(center, tol, channel) do
    max = @channel_max[channel]

    case range_bands(center, tol, channel) do
      [] -> "-"
      [{0, ^max}] -> "any"
      [{value, value}] -> to_string(value)
      [{lo, hi}] -> "#{lo}-#{hi}"
      [{lo1, hi1}, {lo2, hi2}] -> "#{lo1}-#{hi1}, #{lo2}-#{hi2}"
    end
  end

  def range_band_boxes(center, tol, channel) do
    max = @channel_max[channel]

    for {lo, hi} <- range_bands(center, tol, channel) do
      "left: #{Float.round(lo / max * 100, 2)}%; width: #{Float.round(max((hi - lo) / max * 100, 0.8), 2)}%;"
    end
  end

  def form_int(form, field, default) do
    case form[field].value do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> default
        end

      _ ->
        default
    end
  end

  def channel_gradient(:h, _s, _v) do
    stops = for h <- 0..179//15, do: "#{color_swatch_css(h, 255, 255)} #{Float.round(h / 179 * 100, 1)}%"
    "linear-gradient(to right, #{Enum.join(stops, ", ")}, #{color_swatch_css(179, 255, 255)} 100%)"
  end

  def channel_gradient(:s, h, v) do
    "linear-gradient(to right, #{color_swatch_css(h, 0, v)}, #{color_swatch_css(h, 255, v)})"
  end

  def channel_gradient(:v, h, s) do
    "linear-gradient(to right, #{color_swatch_css(h, s, 0)}, #{color_swatch_css(h, s, 255)})"
  end

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

  def tolerance_gradient_css(h, s, v, tol_h, tol_v) do
    stops = 8
    v_hi = min(v + tol_v, 255)
    v_lo = max(v - tol_v, 0)
    dim = if v_hi == 0, do: 0.0, else: 1 - v_lo / v_hi

    hues =
      for i <- 0..stops do
        hue = round(h - tol_h + 2 * tol_h * i / stops)
        color_swatch_css(Integer.mod(hue, 180), s, v_hi)
      end

    "linear-gradient(to bottom, rgba(0,0,0,0), rgba(0,0,0,#{Float.round(dim, 3)})), linear-gradient(to right, #{Enum.join(hues, ", ")})"
  end

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
