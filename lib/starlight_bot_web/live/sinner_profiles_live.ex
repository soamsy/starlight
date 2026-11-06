defmodule StarlightBotWeb.Live.SinnerProfilesLive do
  use StarlightBotWeb, :live_view

  alias StarlightBot.{BattlePlans, Hooks, Plans, SinnerProfiles}
  alias StarlightBot.Vision.{Capture, Frame, Matcher, SkillTray}

  @portrait_x_offset 0
  @portrait_w 33
  @edge_pull -3

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:locator_names, Hooks.list_names("locator"))
     |> assign(:profile_tests, %{})
     |> assign(:capture, nil)
     |> assign(:search, "")
     |> assign(:picking_sinner, false)
     |> assign(:focus_id, nil)
     |> assign_profiles()}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket), do: {:noreply, assign(socket, :search, q)}

  @impl true
  def handle_event("cancel_new", _, socket), do: {:noreply, assign(socket, :picking_sinner, false)}

  @impl true
  def handle_event("capture_locator", %{"id" => id, "kind" => kind}, socket) do
    id = String.to_integer(id)
    profile = Enum.find(socket.assigns.profiles, &(&1.id == id))
    hook_name = locator_name(profile, kind)

    case capture_candidates(hook_name) do
      {:ok, candidates} ->
        {:noreply, assign(socket, :capture, %{profile: profile, kind: kind, hook_name: hook_name, candidates: candidates})}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_event("pick_capture", %{"column" => column}, socket) do
    %{hook_name: hook_name, candidates: candidates} = socket.assigns.capture
    candidate = Enum.find(candidates, &(&1.column == String.to_integer(column)))
    {x, y, w, h} = candidate.region

    ensure_editable_hook(hook_name)

    attrs =
      hook_name
      |> Hooks.get_hook()
      |> Map.merge(%{image: candidate.png, region_x: x, region_y: y, region_w: w, region_h: h})

    case Hooks.save_hook(attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:capture, nil)
         |> assign_profiles()
         |> put_flash(:info, "Updated #{hook_name} from slot #{candidate.column + 1}.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("reset_locator", %{"id" => id, "kind" => kind}, socket) do
    id = String.to_integer(id)
    profile = Enum.find(socket.assigns.profiles, &(&1.id == id))
    hook_name = locator_name(profile, kind)

    with %{} <- hook_name && Hooks.get_hook(hook_name),
         _ <- ensure_editable_hook(hook_name),
         {:ok, _} <- Hooks.update_hook_image(hook_name, SinnerProfiles.placeholder_png()) do
      {:noreply, socket |> assign_profiles() |> put_flash(:info, "Replaced #{hook_name} image with the placeholder.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Set a locator hook first.")}
    end
  end

  @impl true
  def handle_event("cancel_capture", _, socket), do: {:noreply, assign(socket, :capture, nil)}

  @impl true
  def handle_event("new_profile", _, socket), do: {:noreply, assign(socket, :picking_sinner, true)}

  @impl true
  def handle_event("create_profile", %{"sinner" => sinner}, socket) do
    case SinnerProfiles.save(%{name: "New Profile #{length(socket.assigns.profiles) + 1}", sinner: sinner}) do
      {:ok, id} ->
        {:noreply,
         socket
         |> assign(picking_sinner: false, search: "", focus_id: id)
         |> assign_profiles()}

      {:error, reason} ->
        {:noreply, socket |> assign(:picking_sinner, false) |> put_flash(:error, "Create failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("save_profile", %{"profile_id" => id} = params, socket) do
    attrs = %{
      id: String.to_integer(id),
      name: String.trim(params["name"] || ""),
      sinner: blank_to_nil(params["sinner"]),
      locator_hook: blank_to_nil(String.trim(params["locator_hook"] || "")),
      base_locator_hook: blank_to_nil(String.trim(params["base_locator_hook"] || ""))
    }

    case SinnerProfiles.save(attrs) do
      {:ok, _id} -> {:noreply, assign_profiles(socket)}
      {:error, reason} -> {:noreply, socket |> assign_profiles() |> put_flash(:error, "Save failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("delete_profile", %{"id" => id}, socket) do
    id = String.to_integer(id)

    if Map.get(socket.assigns.profile_usage, id, 0) > 0 do
      {:noreply, put_flash(socket, :error, "Profile is still used by a playbook.")}
    else
      SinnerProfiles.delete(id)
      {:noreply, assign_profiles(socket)}
    end
  end

  @impl true
  def handle_event("test_profile", %{"id" => id}, socket) do
    id = String.to_integer(id)
    profile = Enum.find(socket.assigns.profiles, &(&1.id == id))

    result =
      Enum.map_join(["base", "uptie"], " | ", fn kind ->
        "#{String.capitalize(kind)}: #{test_locator(locator_name(profile, kind))}"
      end)

    {:noreply, update(socket, :profile_tests, &Map.put(&1, id, result))}
  end

  defp assign_profiles(socket) do
    profiles = SinnerProfiles.list()

    usage =
      Plans.list(:battle_plans)
      |> Enum.flat_map(fn s -> if is_map(s.data), do: Enum.to_list(BattlePlans.profile_ids_used(s.data)), else: [] end)
      |> Enum.frequencies()

    thumbs =
      Map.new(profiles, fn p ->
        {p.id, %{"uptie" => thumb(p.locator_hook), "base" => thumb(p.base_locator_hook)}}
      end)

    socket
    |> assign(:profiles, profiles)
    |> assign(:profile_usage, usage)
    |> assign(:profile_thumbs, thumbs)
  end

  defp thumb(nil), do: nil

  defp thumb(hook_name) do
    case Hooks.get_hook(hook_name) do
      %{image: image} when is_binary(image) -> Base.encode64(image)
      _ -> nil
    end
  end

  defp locator_name(profile, "uptie"), do: profile.locator_hook
  defp locator_name(profile, "base"), do: profile.base_locator_hook

  defp locator_missing?(profile, locator_names) do
    Enum.any?([profile.locator_hook, profile.base_locator_hook], &(is_nil(&1) or &1 not in locator_names))
  end

  defp visible_profiles(profiles, search) do
    case String.downcase(String.trim(search)) do
      "" ->
        profiles

      q ->
        Enum.filter(profiles, fn p ->
          [p.name, p.name_en, p.sinner, p.locator_hook, p.base_locator_hook]
          |> Enum.any?(&(is_binary(&1) and String.contains?(String.downcase(&1), q)))
        end)
    end
  end

  defp grouped_profiles(profiles, search) do
    visible = visible_profiles(profiles, search)
    known = StarlightBot.SinnerProfiles.sinners()
    grouped = Enum.group_by(visible, & &1.sinner)
    extra = Enum.filter(visible, &(&1.sinner not in known))

    Enum.map(known, &{&1, Map.get(grouped, &1, [])}) ++
      if(extra == [], do: [], else: [{nil, extra}])
  end

  defp delete_message(profile, usage) do
    case Map.get(usage, profile.id, 0) do
      0 -> "Delete '#{profile.name}'?"
      n -> "Delete '#{profile.name}'? It is used by #{n}."
    end
  end

  defp sinner_label(sinner), do: sinner |> String.split("_") |> Enum.map_join(" ", &String.capitalize/1)

  defp ensure_editable_hook(name) do
    case Hooks.effective_row(name) do
      %{source: :base} = row -> if Hooks.editable?(row), do: :ok, else: Hooks.override_hook(name)
      _ -> :ok
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp capture_candidates(hook_name) when hook_name in [nil, ""], do: {:error, "Set a locator hook first."}

  defp capture_candidates(hook_name) do
    with %{} = hook <- Hooks.get_hook(hook_name) || {:error, "Hook '#{hook_name}' doesn't exist."},
         {:ok, frame} <- Capture.grab_frame(),
         {:ok, tray} <- SkillTray.scan(frame) do
      w = @portrait_w
      h = hook.region_h || 40
      y = hook.region_y || 972

      candidates =
        tray.sinner_of_slot
        |> Enum.with_index()
        |> Enum.dedup_by(&elem(&1, 0))
        |> Enum.map(fn {_sinner, column} ->
          region = {round(portrait_center(tray, column) + @portrait_x_offset - w / 2), y, w, h}
          png = Evision.imencode(".png", Frame.crop(frame.mat, region))
          %{column: column, region: region, png: png, png_b64: Base.encode64(png)}
        end)

      {:ok, candidates}
    else
      :not_found -> {:error, "Skill tray not found. Is a battle turn on screen?"}
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, "Capture failed: #{inspect(reason)}"}
    end
  end

  defp portrait_center(tray, column) do
    mid = (tray.tray_start_x + tray.tray_end_x) / 2
    half_span = (tray.tray_end_x - tray.tray_start_x - tray.bin_width) / 2
    x = SkillTray.slot_x(tray, column)
    if half_span > 0, do: x - @edge_pull * (x - mid) / half_span, else: x
  end

  defp test_locator(hook) when hook in [nil, ""], do: "No locator hook set."

  defp test_locator(hook) do
    hook_atom = String.to_existing_atom(hook)

    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, tray} <- SkillTray.scan(frame),
         [_ | _] = rects <- Matcher.find_all(frame, hook_atom) do
      {x, _y, w, _h} = Enum.min_by(rects, &elem(&1, 0))
      column = SkillTray.column_at(tray, x + w / 2)
      slots = SkillTray.owned_columns(tray, column)

      extra = if length(rects) > 1, do: " (#{length(rects)} matches, used leftmost)", else: ""
      "Matched column #{column + 1}, owner slots #{Enum.min(slots) + 1}-#{Enum.max(slots) + 1} (#{length(slots)} skill(s))#{extra}"
    else
      [] -> "Locator hook didn't match."
      :not_found -> "Skill tray not found. Is a battle turn on screen?"
      {:error, reason} -> "Failed: #{inspect(reason)}"
    end
  rescue
    ArgumentError -> "Hook '#{hook}' isn't loaded."
  end
end
