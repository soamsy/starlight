defmodule StarlightBotWeb.Live.SinnerProfilesLive do
  use StarlightBotWeb, :live_view

  alias StarlightBot.{BattleStrategies, Hooks, SinnerProfiles, Strategies}
  alias StarlightBot.Vision.{Capture, Matcher, SkillTray}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:locator_names, Hooks.list_names("locator"))
     |> assign(:profile_tests, %{})
     |> assign_profiles()}
  end

  @impl true
  def handle_event("new_profile", _, socket) do
    case SinnerProfiles.save(%{name: "New Profile #{length(socket.assigns.profiles) + 1}"}) do
      {:ok, _id} -> {:noreply, assign_profiles(socket)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("save_profile", %{"profile_id" => id} = params, socket) do
    attrs = %{
      id: String.to_integer(id),
      name: String.trim(params["name"] || ""),
      sinner: blank_to_nil(params["sinner"]),
      locator_hook: blank_to_nil(String.trim(params["locator_hook"] || ""))
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
    {:noreply, update(socket, :profile_tests, &Map.put(&1, id, test_locator(profile)))}
  end

  defp assign_profiles(socket) do
    profiles = SinnerProfiles.list()

    usage =
      Strategies.list(:battle_strategies)
      |> Enum.flat_map(fn s -> if is_map(s.data), do: Enum.to_list(BattleStrategies.profile_ids_used(s.data)), else: [] end)
      |> Enum.frequencies()

    thumbs =
      Map.new(profiles, fn p ->
        image = p.locator_hook && Hooks.get_hook(p.locator_hook)
        {p.id, image && image.image && Base.encode64(image.image)}
      end)

    socket
    |> assign(:profiles, profiles)
    |> assign(:profile_usage, usage)
    |> assign(:profile_thumbs, thumbs)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp test_locator(%{locator_hook: hook}) when hook in [nil, ""], do: "No locator hook set."

  defp test_locator(%{locator_hook: hook}) do
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
