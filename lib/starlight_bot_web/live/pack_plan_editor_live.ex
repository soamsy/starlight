defmodule StarlightBotWeb.Live.PackPlanEditorLive do
  use StarlightBotWeb, :live_view

  import StarlightBotWeb.Components.PlanPicker
  import StarlightBotWeb.Components.PlanTemplates

  alias StarlightBot.{PlanCounts, Plans, Teams, ThemePacks}
  alias StarlightBot.PackPlans.Resolver

  @priorities ~w(hunt banned)
  @modes ~w(normal hard)

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: PlanCounts.subscribe()

    theme_packs = ThemePacks.list_theme_packs()
    team = session["team_id"] && Teams.get_team(session["team_id"])

    socket =
      socket
      |> assign(:team_id, team && team.id)
      |> assign(:paste_status, :unknown)
      |> assign_templates(:pack_plans)
      |> assign(:tab_counts, PlanCounts.for_team(team && team.id))
      |> assign(:theme_packs, theme_packs)
      |> assign(:packs_by_id, Map.new(theme_packs, &{&1.id, &1}))
      |> assign(:extreme?, false)
      |> reset_editor()

    {:ok, if(team && team.pack_plan_id, do: load_plan(socket, team.pack_plan_id), else: socket)}
  end

  @impl true
  def handle_info({:plan_count, team_id, table, count}, %{assigns: %{team_id: team_id}} = socket), do: {:noreply, update(socket, :tab_counts, &Map.put(&1, table, count))}

  @impl true
  def handle_info({:plan_count, _team_id, _table, _count}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("new_plan", _, socket) do
    attrs = %{name: Plans.new_name(:pack_plans, socket.assigns.team_id), data: blank_plan_data()}

    case Plans.save(:pack_plans, attrs) do
      {:ok, id} ->
        {:noreply, socket |> load_plan(id) |> link_team(:pack_plan_id)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("copy_plan", _, socket), do: {:noreply, copy_plan(socket, :pack_plans)}

  @impl true
  def handle_event("paste_plan", %{"text" => text}, socket), do: {:noreply, paste_plan(socket, :pack_plans, :pack_plan_id, text, &load_plan/2)}

  @impl true
  def handle_event("plan_clipboard_failed", %{"message" => message}, socket), do: {:noreply, put_flash(socket, :error, message)}

  @impl true
  def handle_event("template_" <> action, params, socket), do: {:noreply, template_event(socket, action, params, :pack_plans, :pack_plan_id, &load_plan/2)}

  @impl true
  def handle_event("clipboard_status", %{"text" => text}, socket), do: {:noreply, paste_status(socket, :pack_plans, text)}

  @impl true
  def handle_event("toggle_extreme", _, socket) do
    {:noreply, update(socket, :extreme?, &(not &1))}
  end

  @impl true
  def handle_event("toggle_extreme_mode", _, socket) do
    plan_data = socket.assigns.plan_data

    if Resolver.extreme_allowed?(plan_data) do
      plan_data = Map.put(plan_data, "extreme", not Resolver.extreme?(plan_data))
      {:noreply, socket |> assign(:plan_data, plan_data) |> persist_plan()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_breakpoint", %{"floor" => floor}, socket) do
    floor = String.to_integer(floor)
    schedule = toggle_breakpoint(socket.assigns.plan_data["mode_schedule"], floor)
    plan_data = socket.assigns.plan_data |> Map.put("mode_schedule", schedule) |> drop_extreme_unless_allowed()
    {:noreply, socket |> assign(:plan_data, plan_data) |> persist_plan()}
  end

  @impl true
  def handle_event("toggle_search_floor", %{"floor" => floor}, socket) do
    floor = String.to_integer(floor)
    search_floors = socket.assigns.plan_data["search_floors"]

    if Resolver.searchable_floor?(floor) do
      search_floors =
        if floor in search_floors, do: List.delete(search_floors, floor), else: Enum.sort([floor | search_floors])

      plan_data = Map.put(socket.assigns.plan_data, "search_floors", search_floors)
      {:noreply, socket |> assign(:plan_data, plan_data) |> persist_plan()}
    else
      {:noreply, socket}
    end
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
  def handle_event("assign_priority", %{"pack_id" => pack_id, "priority" => priority, "mode" => mode}, socket) when mode in @modes do
    pack = socket.assigns.packs_by_id[pack_id]

    if pack && Resolver.eligible_floors(pack, mode) != [] do
      plan_data = put_priority(socket.assigns.plan_data, pack_id, mode, priority)
      {:noreply, socket |> assign(:plan_data, plan_data) |> persist_plan()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_pack_floor", %{"pack_id" => pack_id, "floor" => floor, "mode" => mode}, socket) when mode in @modes do
    floor = String.to_integer(floor)
    pack = socket.assigns.packs_by_id[pack_id]

    if pack do
      plan_data = toggle_pack_floor(socket.assigns.plan_data, pack, mode, floor)
      {:noreply, socket |> assign(:plan_data, plan_data) |> persist_plan()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_favorite", %{"pack_id" => pack_id, "mode" => mode}, socket) when mode in @modes do
    if Resolver.priority_for(socket.assigns.plan_data, pack_id, mode) == "hunt" do
      plan_data = update_in(socket.assigns.plan_data, ["packs", pack_id, mode], &toggle_favorite/1)
      {:noreply, socket |> assign(:plan_data, plan_data) |> persist_plan()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("reorder_hunt", %{"scope" => mode, "ids" => ids}, socket) when mode in @modes do
    current = socket.assigns.plan_data |> packs_with_priority(socket.assigns.theme_packs, mode, "hunt") |> Enum.map(& &1.id)

    if Enum.sort(ids) == Enum.sort(current) do
      plan_data = put_in(socket.assigns.plan_data, [Access.key("hunt_order", %{}), mode], ids)
      {:noreply, socket |> assign(:plan_data, plan_data) |> persist_plan()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_span_floors", %{"pack_id" => pack_id, "floors" => floors, "mode" => mode}, socket) when mode in @modes do
    pack = socket.assigns.packs_by_id[pack_id]
    floors = floors |> String.split(",") |> Enum.map(&String.to_integer/1)

    if pack && floors != [] && Enum.all?(floors, &(&1 in Resolver.eligible_floors(pack, mode))) do
      plan_data = toggle_span_floors(socket.assigns.plan_data, pack, mode, floors)
      {:noreply, socket |> assign(:plan_data, plan_data) |> persist_plan()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_floor_editor", %{"pack_id" => pack_id, "mode" => mode}, socket) when mode in @modes do
    key = {mode, pack_id}
    {:noreply, assign(socket, :floor_editor, if(socket.assigns.floor_editor == key, do: nil, else: key))}
  end

  @impl true
  def handle_event("copy_priority", %{"priority" => priority, "mode" => mode}, socket) when priority in @priorities and mode in @modes do
    text = copy_payload(socket.assigns.plan_data, socket.assigns.theme_packs, mode, priority)
    {:noreply, push_event(socket, "copy_priority_json", %{text: text})}
  end

  @impl true
  def handle_event("paste_priority", %{"priority" => priority, "mode" => mode, "text" => text}, socket)
      when priority in @priorities and mode in @modes do
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

  def modes, do: @modes

  def priority_label("banned"), do: "Banned"
  def priority_label("hunt"), do: "Hunt"
  def priority_label("fine"), do: "Fine"

  def priority_tooltip("banned"),
    do: "Never picked voluntarily. Only taken if nothing else is shown and no refreshes are left."

  def priority_tooltip("hunt"),
    do: "Picked immediately if shown, highest in the list first. If none are shown and refreshes remain, keep refreshing to find one. With starred favorites, only favorites are hunted, refreshed for and searched for; the other Hunt packs are a backup once refreshes and search run out."

  def priority_tooltip("fine"),
    do: "The default. Acceptable filler, picked when nothing better is shown."

  def packs_with_priority(plan_data, theme_packs, mode, "hunt") do
    theme_packs
    |> Enum.filter(&(Resolver.priority_for(plan_data, &1.id, mode) == "hunt"))
    |> Resolver.sort_hunt(plan_data, mode)
  end

  def packs_with_priority(plan_data, theme_packs, mode, priority) do
    Enum.filter(theme_packs, &(Resolver.priority_for(plan_data, &1.id, mode) == priority))
  end

  def chart_rows(plan_data, theme_packs, filter, floor_filter, floor_count) do
    schedule = plan_data["mode_schedule"]

    theme_packs
    |> Enum.filter(&matches_filter?(&1, filter))
    |> Enum.flat_map(fn pack ->
      Enum.map(@modes, fn mode ->
        floors = Enum.filter(Resolver.eligible_floors(pack, mode), &(Resolver.mode_for_floor(schedule, &1) == mode))
        %{pack: pack, mode: mode, floors: floors}
      end)
    end)
    |> Enum.filter(&(&1.floors != [] and Enum.min(&1.floors) <= floor_count))
    |> Enum.filter(&(floor_filter == nil or floor_filter in &1.floors))
    |> Enum.sort_by(&Enum.min_max(&1.floors))
  end

  def priority_button_class("hunt"), do: "btn-success"
  def priority_button_class("banned"), do: "btn-error"

  def priority_fill_class("hunt"), do: "bg-success/30"
  def priority_fill_class("banned"), do: "bg-error/30"

  def overflow?(extreme?), do: not extreme?

  def likely_path(plan_data, theme_packs, floor_count) do
    {path, _picked} =
      Enum.map_reduce(1..floor_count, MapSet.new(), fn floor, picked ->
        mode = Resolver.mode_for_floor(plan_data["mode_schedule"], floor)

        theme_packs
        |> Enum.filter(&(floor in Resolver.eligible_floors(&1, mode) and Resolver.priority_at(plan_data, &1, mode, floor) == "hunt"))
        |> Enum.reject(&MapSet.member?(picked, &1.id))
        |> Resolver.sort_hunt(plan_data, mode)
        |> case do
          [] -> {{floor, nil}, picked}
          [top | rest] -> {{floor, {top, length(rest)}}, MapSet.put(picked, top.id)}
        end
      end)

    Map.new(path)
  end

  def extreme_disabled?(plan_data), do: not Resolver.extreme_allowed?(plan_data)

  def disabled_stripes_style do
    "background-image: repeating-linear-gradient(135deg, color-mix(in oklab, var(--color-base-content) 14%, transparent) 0 4px, transparent 4px 10px)"
  end

  def hard_column(plan_data, floor_count, overflow?) do
    from =
      case plan_data["mode_schedule"] do
        [%{"from_floor" => from} | _] -> min(from, 6)
        _ -> 6
      end

    cond do
      from <= floor_count -> from
      overflow? -> floor_count + 1
      true -> nil
    end
  end

  def span_style(row, floor_count, overflow?) do
    first = Enum.min(row.floors)
    last_col = row |> visible_floors(floor_count, overflow?) |> Enum.max() |> column_of(floor_count)
    "grid-column: #{first + 1} / span #{last_col - first + 1}"
  end

  def span_cells(row, floor_count, overflow?) do
    first = Enum.min(row.floors)
    {shown, hidden} = Enum.split_with(row.floors, &(&1 <= floor_count))
    cells = Enum.map(shown, &{&1 - first + 1, [&1], "F#{&1}"})

    if overflow? and hidden != [],
      do: cells ++ [{floor_count + 2 - first, hidden, "F#{Enum.min(hidden)}-#{Enum.max(hidden)}"}],
      else: cells
  end

  def highlight_columns(plan_data, row, floor_count, overflow?) do
    if Resolver.priority_for(plan_data, row.pack.id, row.mode) == "fine" do
      []
    else
      first = Enum.min(row.floors)

      plan_data
      |> Resolver.floors_for(row.pack.id, row.mode, row.pack)
      |> Enum.filter(&(&1 in row.floors))
      |> then(&visible_floors(%{floors: &1}, floor_count, overflow?))
      |> Enum.map(&(column_of(&1, floor_count) - first + 1))
      |> Enum.uniq()
    end
  end

  defp visible_floors(row, floor_count, overflow?) do
    if overflow?, do: row.floors, else: Enum.filter(row.floors, &(&1 <= floor_count))
  end

  defp column_of(floor, floor_count), do: min(floor, floor_count + 1)

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

  defp reset_editor(socket) do
    socket
    |> assign(:editing_id, nil)
    |> assign(:name, "")
    |> assign(:plan_data, blank_plan_data())
    |> assign(:floor_filter, nil)
    |> assign(:filter, "")
    |> assign(:floor_editor, nil)
  end

  defp load_plan(socket, id) do
    case Plans.get(:pack_plans, id) do
      nil ->
        put_flash(socket, :error, "Plan not found.")

      plan ->
        socket
        |> assign(:editing_id, plan.id)
        |> assign(:name, plan.name)
        |> assign(:plan_data, plan.data |> normalize_plan_data() |> materialize_hunt_order(socket.assigns.theme_packs))
        |> assign(:floor_filter, nil)
        |> assign(:filter, "")
        |> assign(:floor_editor, nil)
    end
  end

  defp persist_plan(socket) do
    attrs = %{id: socket.assigns.editing_id, name: socket.assigns.name, data: socket.assigns.plan_data}

    case Plans.save(:pack_plans, attrs) do
      {:ok, _id} -> broadcast_count(socket, :pack_plans, socket.assigns.plan_data)
      {:error, reason} -> put_flash(socket, :error, "Save failed: #{inspect(reason)}")
    end
  end

  defp blank_plan_data do
    Plans.blank(:pack_plans)
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

  defp drop_extreme_unless_allowed(plan_data) do
    if Resolver.extreme_allowed?(plan_data), do: plan_data, else: Map.put(plan_data, "extreme", false)
  end

  defp put_priority(plan_data, pack_id, mode, "fine") do
    packs = Map.get(plan_data, "packs", %{})
    pack_entry = packs |> Map.get(pack_id, %{}) |> Map.delete(mode)
    packs = if pack_entry == %{}, do: Map.delete(packs, pack_id), else: Map.put(packs, pack_id, pack_entry)
    plan_data |> Map.put("packs", packs) |> put_hunt_order(pack_id, mode, "fine")
  end

  defp put_priority(plan_data, pack_id, mode, priority) do
    packs = Map.get(plan_data, "packs", %{})
    pack_entry = packs |> Map.get(pack_id, %{}) |> Map.put(mode, %{"priority" => priority})
    plan_data |> Map.put("packs", Map.put(packs, pack_id, pack_entry)) |> put_hunt_order(pack_id, mode, priority)
  end

  defp put_hunt_order(plan_data, pack_id, mode, priority) do
    order = plan_data |> get_in(["hunt_order", mode]) |> List.wrap() |> List.delete(pack_id)
    order = if priority == "hunt", do: order ++ [pack_id], else: order
    put_in(plan_data, [Access.key("hunt_order", %{}), mode], order)
  end

  defp materialize_hunt_order(plan_data, theme_packs) do
    Enum.reduce(~w(normal hard), plan_data, fn mode, acc ->
      ids = acc |> packs_with_priority(theme_packs, mode, "hunt") |> Enum.map(& &1.id)
      put_in(acc, [Access.key("hunt_order", %{}), mode], ids)
    end)
  end

  defp toggle_favorite(%{"favorite" => true} = entry), do: Map.delete(entry, "favorite")
  defp toggle_favorite(entry), do: Map.put(entry, "favorite", true)

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

  defp toggle_span_floors(plan_data, pack, mode, floors) do
    if Resolver.priority_for(plan_data, pack.id, mode) == "fine" do
      plan_data |> put_priority(pack.id, mode, "hunt") |> set_pack_floors(pack.id, mode, floors)
    else
      current = Resolver.floors_for(plan_data, pack.id, mode, pack)
      new_floors = if Enum.all?(floors, &(&1 in current)), do: current -- floors, else: Enum.sort(Enum.uniq(current ++ floors))

      if new_floors == [],
        do: put_priority(plan_data, pack.id, mode, "fine"),
        else: set_pack_floors(plan_data, pack.id, mode, new_floors)
    end
  end

  defp set_pack_floors(plan_data, pack_id, mode, floors) do
    packs = Map.get(plan_data, "packs", %{})
    mode_entry = (get_in(packs, [pack_id, mode]) || %{"priority" => "fine"}) |> Map.put("floors", floors)
    pack_entry = Map.put(Map.get(packs, pack_id, %{}), mode, mode_entry)
    Map.put(plan_data, "packs", Map.put(packs, pack_id, pack_entry))
  end
end
