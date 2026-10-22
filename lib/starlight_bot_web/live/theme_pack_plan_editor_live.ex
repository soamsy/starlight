defmodule StarlightBotWeb.Live.ThemePackPlanEditorLive do
  use StarlightBotWeb, :live_view

  import StarlightBotWeb.Components.PlanPicker

  alias StarlightBot.{Strategies, Teams, ThemePacks}
  alias StarlightBot.ThemePackPlans.Resolver

  @priorities ~w(hunt banned bonus)

  @impl true
  def mount(_params, session, socket) do
    theme_packs = ThemePacks.list_theme_packs()
    team = session["team_id"] && Teams.get_team(session["team_id"])

    socket =
      socket
      |> assign(:team_id, team && team.id)
      |> assign(:plans, Strategies.list(:theme_pack_plans))
      |> assign(:theme_packs, theme_packs)
      |> assign(:packs_by_id, Map.new(theme_packs, &{&1.id, &1}))
      |> assign(:extreme?, false)
      |> reset_editor()

    {:ok, if(team && team.theme_pack_plan_id, do: load_plan(socket, team.theme_pack_plan_id), else: socket)}
  end

  @impl true
  def handle_event("new_plan", _, socket) do
    attrs = %{name: new_plan_name(socket.assigns.plans), data: blank_plan_data()}

    case Strategies.save(:theme_pack_plans, attrs) do
      {:ok, id} ->
        {:noreply, socket |> assign(:plans, Strategies.list(:theme_pack_plans)) |> load_plan(id) |> link_team(:theme_pack_plan_id)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("select_plan", %{"id" => id}, socket) do
    {:noreply, socket |> load_plan(String.to_integer(id)) |> link_team(:theme_pack_plan_id)}
  end

  @impl true
  def handle_event("duplicate_plan", %{"id" => id}, socket) do
    case Strategies.get(:theme_pack_plans, String.to_integer(id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Plan not found.")}

      plan ->
        case Strategies.save(:theme_pack_plans, %{name: "#{plan.name} (copy)", data: plan.data}) do
          {:ok, new_id} -> {:noreply, socket |> assign(:plans, Strategies.list(:theme_pack_plans)) |> load_plan(new_id) |> link_team(:theme_pack_plan_id)}
          {:error, reason} -> {:noreply, put_flash(socket, :error, "Duplicate failed: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def handle_event("delete_plan", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Strategies.delete(:theme_pack_plans, id) do
      {:ok, _} ->
        socket = if socket.assigns.editing_id == id, do: reset_editor(socket), else: socket

        {:noreply,
         socket
         |> assign(:plans, Strategies.list(:theme_pack_plans))
         |> link_team(:theme_pack_plan_id)
         |> put_flash(:info, "Plan deleted.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("rename_plan", %{"value" => name}, socket) do
    {:noreply, socket |> assign(:name, String.trim(name)) |> persist_plan() |> link_team(:theme_pack_plan_id)}
  end

  @impl true
  def handle_event("toggle_extreme", _, socket) do
    {:noreply, update(socket, :extreme?, &(not &1))}
  end

  @impl true
  def handle_event("set_mode_tab", %{"mode" => mode}, socket) do
    {:noreply, socket |> assign(:active_mode, mode) |> assign(:floor_filter, nil)}
  end

  @impl true
  def handle_event("toggle_breakpoint", %{"floor" => floor}, socket) do
    floor = String.to_integer(floor)
    schedule = toggle_breakpoint(socket.assigns.plan_data["mode_schedule"], floor)
    plan_data = Map.put(socket.assigns.plan_data, "mode_schedule", schedule)
    {:noreply, socket |> assign(:plan_data, plan_data) |> persist_plan()}
  end

  @impl true
  def handle_event("toggle_search_floor", %{"floor" => floor}, socket) do
    floor = String.to_integer(floor)
    search_floors = socket.assigns.plan_data["search_floors"]

    search_floors =
      if floor in search_floors, do: List.delete(search_floors, floor), else: Enum.sort([floor | search_floors])

    plan_data = Map.put(socket.assigns.plan_data, "search_floors", search_floors)
    {:noreply, socket |> assign(:plan_data, plan_data) |> persist_plan()}
  end

  @impl true
  def handle_event("set_floor_filter", %{"floor" => floor}, socket) do
    floor = String.to_integer(floor)
    new_filter = if socket.assigns.floor_filter == floor, do: nil, else: floor
    {:noreply, assign(socket, :floor_filter, new_filter)}
  end

  @impl true
  def handle_event("filter_packs", %{"value" => val}, socket) do
    {:noreply, assign(socket, :filter, val)}
  end

  @impl true
  def handle_event("assign_priority", %{"pack_id" => pack_id, "priority" => priority}, socket) do
    mode = socket.assigns.active_mode
    pack = socket.assigns.packs_by_id[pack_id]

    if pack && Resolver.eligible_floors(pack, mode) != [] do
      plan_data = put_priority(socket.assigns.plan_data, pack_id, mode, priority)
      {:noreply, socket |> assign(:plan_data, plan_data) |> persist_plan()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_pack_floor", %{"pack_id" => pack_id, "floor" => floor}, socket) do
    floor = String.to_integer(floor)
    pack = socket.assigns.packs_by_id[pack_id]

    if pack do
      plan_data = toggle_pack_floor(socket.assigns.plan_data, pack, socket.assigns.active_mode, floor)
      {:noreply, socket |> assign(:plan_data, plan_data) |> persist_plan()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_floor_editor", %{"pack_id" => pack_id}, socket) do
    current = socket.assigns.floor_editor_pack_id
    {:noreply, assign(socket, :floor_editor_pack_id, if(current == pack_id, do: nil, else: pack_id))}
  end

  @impl true
  def handle_event("copy_priority", %{"priority" => priority}, socket) when priority in @priorities do
    text = copy_payload(socket.assigns.plan_data, socket.assigns.theme_packs, socket.assigns.active_mode, priority)
    {:noreply, push_event(socket, "copy_priority_json", %{text: text})}
  end

  @impl true
  def handle_event("paste_priority", %{"priority" => priority, "text" => text}, socket) when priority in @priorities do
    mode = socket.assigns.active_mode

    case parse_paste(text, socket.assigns.theme_packs, mode) do
      {:ok, entries} ->
        plan_data = apply_priority_paste(socket.assigns.plan_data, socket.assigns.theme_packs, priority, mode, entries)

        {:noreply,
         socket
         |> assign(:plan_data, plan_data)
         |> persist_plan()
         |> put_flash(:info, "Pasted #{map_size(entries)} pack(s) into #{priority_label(priority)}.")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_event("paste_priority_failed", %{"message" => message}, socket) do
    {:noreply, put_flash(socket, :error, message)}
  end

  # --- Display helpers (used from the template) ---

  def max_floor(true), do: 15
  def max_floor(false), do: 5

  def priorities, do: @priorities

  def priority_label("banned"), do: "Banned"
  def priority_label("hunt"), do: "Hunt"
  def priority_label("bonus"), do: "Bonus"
  def priority_label("fine"), do: "Fine"

  def priority_tooltip("banned"),
    do: "Never picked voluntarily. Only taken if nothing else is shown and no refreshes are left."

  def priority_tooltip("hunt"),
    do: "Picked immediately if shown. If none are shown and refreshes remain, keep refreshing to find one."

  def priority_tooltip("bonus"),
    do: "Picked immediately if shown, but its absence never triggers a refresh."

  def priority_tooltip("fine"),
    do: "The default. Acceptable filler, picked when nothing better is shown."

  def floors_in_range(schedule, mode, max_floor) do
    Enum.filter(1..max_floor, &(Resolver.mode_for_floor(schedule, &1) == mode))
  end

  def floor_covered?(plan_data, all_packs, mode, floor) do
    Resolver.priority_in_play?(plan_data, all_packs, mode, floor, "hunt") or
      Resolver.priority_in_play?(plan_data, all_packs, mode, floor, "bonus")
  end

  def packs_with_priority(plan_data, theme_packs, mode, priority) do
    Enum.filter(theme_packs, &(Resolver.priority_for(plan_data, &1.id, mode) == priority))
  end

  def fine_candidates(plan_data, theme_packs, mode, filter, floor_filter) do
    theme_packs
    |> Enum.filter(&(Resolver.priority_for(plan_data, &1.id, mode) == "fine"))
    |> Enum.filter(&(Resolver.eligible_floors(&1, mode) != []))
    |> Enum.filter(&matches_filter?(&1, filter))
    |> Enum.filter(&matches_floor_filter?(&1, mode, floor_filter))
  end

  def pack_floor_label(plan_data, pack, mode) do
    floors = Resolver.floors_for(plan_data, pack.id, mode, pack)
    eligible = Resolver.eligible_floors(pack, mode)
    if floors == eligible, do: "all", else: Enum.join(floors, ",")
  end

  def copy_payload(plan_data, theme_packs, mode, priority) do
    packs_json =
      plan_data
      |> packs_with_priority(theme_packs, mode, priority)
      |> Map.new(fn pack ->
        floors = Resolver.floors_for(plan_data, pack.id, mode, pack)
        eligible = Resolver.eligible_floors(pack, mode)
        entry = if floors == eligible, do: %{}, else: %{"floors" => floors}
        {pack.id, entry}
      end)

    Jason.encode!(%{"priority" => priority, "mode" => mode, "packs" => packs_json})
  end

  @doc """
  Validates pasted clipboard JSON against the live plan: the JSON's "mode" must
  match the mode currently being edited, and any explicit "floors" list per pack
  must be a subset of that pack's actual eligible floors for that mode. Returns
  `{:ok, %{pack_id => floors_or_nil}}` (nil floors = "all eligible") or
  `{:error, message}` describing exactly what didn't match.
  """
  def parse_paste(json_text, theme_packs, mode) do
    packs_by_id = Map.new(theme_packs, &{&1.id, &1})

    with {:ok, decoded} when is_map(decoded) <- Jason.decode(json_text),
         {:ok, packs_json} <- fetch_pasted_packs(decoded),
         :ok <- validate_pasted_mode(decoded, mode) do
      validate_pasted_packs(packs_json, packs_by_id, mode)
    else
      {:error, %Jason.DecodeError{}} -> {:error, "Clipboard doesn't contain valid JSON."}
      {:error, _} = err -> err
      _ -> {:error, "Clipboard doesn't contain valid JSON."}
    end
  end

  defp fetch_pasted_packs(%{"packs" => packs}) when is_map(packs), do: {:ok, packs}
  defp fetch_pasted_packs(_), do: {:error, "Expected a JSON object with a \"packs\" field."}

  defp validate_pasted_mode(%{"mode" => json_mode}, mode) when json_mode == mode, do: :ok

  defp validate_pasted_mode(%{"mode" => json_mode}, mode),
    do: {:error, "Expected #{mode} mode floors, got #{json_mode} mode floors."}

  defp validate_pasted_mode(_, _), do: {:error, "Clipboard JSON is missing a \"mode\" field."}

  defp validate_pasted_packs(packs_json, packs_by_id, mode) do
    Enum.reduce_while(packs_json, {:ok, %{}}, fn {pack_id, entry}, {:ok, acc} ->
      case validate_pasted_pack(pack_id, entry, packs_by_id, mode) do
        {:ok, floors} -> {:cont, {:ok, Map.put(acc, pack_id, floors)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_pasted_pack(pack_id, entry, packs_by_id, mode) do
    case packs_by_id[pack_id] do
      nil ->
        {:error, "Unknown pack: #{pack_id}."}

      pack ->
        case Resolver.eligible_floors(pack, mode) do
          [] -> {:error, "#{pack.name_en} doesn't appear in #{mode} mode."}
          eligible -> validate_pasted_floors(entry["floors"], eligible, pack)
        end
    end
  end

  defp validate_pasted_floors(nil, _eligible, _pack), do: {:ok, nil}

  defp validate_pasted_floors(floors, eligible, pack) when is_list(floors) do
    case Enum.reject(floors, &(&1 in eligible)) do
      [] -> {:ok, floors}
      invalid -> {:error, "Expected floors #{Enum.join(eligible, ", ")}, got floors #{Enum.join(invalid, ", ")} for #{pack.name_en}."}
    end
  end

  # --- Private ---

  defp matches_filter?(_pack, ""), do: true
  defp matches_filter?(pack, filter), do: String.contains?(String.downcase(pack.name_en || ""), String.downcase(filter))

  defp matches_floor_filter?(_pack, _mode, nil), do: true
  defp matches_floor_filter?(pack, mode, floor), do: floor in Resolver.eligible_floors(pack, mode)

  defp reset_editor(socket) do
    socket
    |> assign(:editing_id, nil)
    |> assign(:name, "")
    |> assign(:plan_data, blank_plan_data())
    |> assign(:active_mode, "normal")
    |> assign(:floor_filter, nil)
    |> assign(:filter, "")
    |> assign(:floor_editor_pack_id, nil)
  end

  defp load_plan(socket, id) do
    case Strategies.get(:theme_pack_plans, id) do
      nil ->
        put_flash(socket, :error, "Plan not found.")

      plan ->
        socket
        |> assign(:editing_id, plan.id)
        |> assign(:name, plan.name)
        |> assign(:plan_data, normalize_plan_data(plan.data))
        |> assign(:active_mode, "normal")
        |> assign(:floor_filter, nil)
        |> assign(:filter, "")
        |> assign(:floor_editor_pack_id, nil)
    end
  end

  defp persist_plan(socket) do
    attrs = %{id: socket.assigns.editing_id, name: socket.assigns.name, data: socket.assigns.plan_data}

    case Strategies.save(:theme_pack_plans, attrs) do
      {:ok, _id} -> assign(socket, :plans, Strategies.list(:theme_pack_plans))
      {:error, reason} -> put_flash(socket, :error, "Save failed: #{inspect(reason)}")
    end
  end

  defp new_plan_name(plans), do: "New Plan #{length(plans) + 1}"

  defp blank_plan_data do
    %{"version" => 1, "mode_schedule" => [], "packs" => %{}, "search_floors" => []}
  end

  defp normalize_plan_data(nil), do: blank_plan_data()

  defp normalize_plan_data(data) do
    data
    |> Map.put_new("mode_schedule", [])
    |> Map.put_new("packs", %{})
    |> Map.put_new("search_floors", [])
    |> Map.update!("mode_schedule", &normalize_mode_schedule/1)
  end

  def normalize_mode_schedule(schedule) do
    schedule
    |> Enum.filter(&(&1["mode"] == "hard"))
    |> Enum.min_by(& &1["from_floor"], fn -> nil end)
    |> case do
      nil -> []
      entry -> [%{"from_floor" => entry["from_floor"], "mode" => "hard"}]
    end
  end

  def toggle_breakpoint(schedule, floor) do
    if Enum.any?(schedule, &(&1["from_floor"] == floor)) do
      []
    else
      [%{"from_floor" => floor, "mode" => "hard"}]
    end
  end

  defp put_priority(plan_data, pack_id, mode, "fine") do
    packs = Map.get(plan_data, "packs", %{})
    pack_entry = packs |> Map.get(pack_id, %{}) |> Map.delete(mode)
    packs = if pack_entry == %{}, do: Map.delete(packs, pack_id), else: Map.put(packs, pack_id, pack_entry)
    Map.put(plan_data, "packs", packs)
  end

  defp put_priority(plan_data, pack_id, mode, priority) do
    packs = Map.get(plan_data, "packs", %{})
    pack_entry = packs |> Map.get(pack_id, %{}) |> Map.put(mode, %{"priority" => priority})
    Map.put(plan_data, "packs", Map.put(packs, pack_id, pack_entry))
  end

  defp toggle_pack_floor(plan_data, pack, mode, floor) do
    pack_id = pack.id
    current = Resolver.floors_for(plan_data, pack_id, mode, pack)
    new_floors = if floor in current, do: List.delete(current, floor), else: Enum.sort([floor | current])
    eligible = Resolver.eligible_floors(pack, mode)

    packs = Map.get(plan_data, "packs", %{})
    mode_entry = get_in(packs, [pack_id, mode]) || %{"priority" => "fine"}

    mode_entry =
      if new_floors == eligible do
        Map.delete(mode_entry, "floors")
      else
        Map.put(mode_entry, "floors", new_floors)
      end

    pack_entry = Map.put(Map.get(packs, pack_id, %{}), mode, mode_entry)
    Map.put(plan_data, "packs", Map.put(packs, pack_id, pack_entry))
  end

  defp apply_priority_paste(plan_data, theme_packs, priority, mode, entries) do
    currently_assigned =
      plan_data |> packs_with_priority(theme_packs, mode, priority) |> Enum.map(& &1.id)

    plan_data = Enum.reduce(currently_assigned, plan_data, &put_priority(&2, &1, mode, "fine"))

    Enum.reduce(entries, plan_data, fn {pack_id, floors}, acc ->
      acc = put_priority(acc, pack_id, mode, priority)
      if floors, do: set_pack_floors(acc, pack_id, mode, floors), else: acc
    end)
  end

  defp set_pack_floors(plan_data, pack_id, mode, floors) do
    packs = Map.get(plan_data, "packs", %{})
    mode_entry = (get_in(packs, [pack_id, mode]) || %{"priority" => "fine"}) |> Map.put("floors", floors)
    pack_entry = Map.put(Map.get(packs, pack_id, %{}), mode, mode_entry)
    Map.put(plan_data, "packs", Map.put(packs, pack_id, pack_entry))
  end
end
