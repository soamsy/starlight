defmodule StarlightBotWeb.Live.PackPlanEditorLive do
  use StarlightBotWeb, :live_view

  import StarlightBotWeb.Components.PlanPicker
  import StarlightBotWeb.Components.PlanTemplates

  alias StarlightBot.{PlanCounts, Plans, Teams, ThemePacks}
  alias StarlightBot.PackPlans.{Odds, Resolver}

  @modes ~w(normal hard)
  @cell_actions ~w(hunt favorite banned)
  @hunted ~w(hunt favorite)
  @read_only_events ~w(set_floor_filter set_view filter_packs toggle_help toggle_odds copy_plan clipboard_status plan_clipboard_failed)

  def read_only_events, do: @read_only_events

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: PlanCounts.subscribe()

    theme_packs = ThemePacks.list_plannable_theme_packs()
    team = session["team_id"] && Teams.get_team(session["team_id"])

    socket =
      socket
      |> assign(:team_id, team && team.id)
      |> assign(:paste_status, :unknown)
      |> assign(:template_id, nil)
      |> read_only_guard(@read_only_events)
      |> assign_templates(:pack_plans)
      |> assign(:tab_counts, PlanCounts.for_team(team && team.id))
      |> assign(:grace_picks, (team && team.grace_picks) || [])
      |> assign(:theme_packs, theme_packs)
      |> assign(:packs_by_id, Map.new(theme_packs, &{&1.id, &1}))
      |> assign(:view, "plan")
      |> assign(:show_help, false)
      |> assign(:show_odds, false)
      |> reset_editor()

    {:ok, if(team && team.pack_plan_id, do: load_plan(socket, team.pack_plan_id, team.pack_template_id), else: socket)}
  end

  @impl true
  def handle_info({:plan_count, team_id, table, count}, %{assigns: %{team_id: team_id}} = socket) do
    socket = update(socket, :tab_counts, &Map.put(&1, table, count))
    {:noreply, if(table == :gift_plans, do: refresh_grace_picks(socket), else: socket)}
  end

  @impl true
  def handle_info({:plan_count, _team_id, _table, _count}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("new_plan", _, socket) do
    attrs = %{name: Plans.new_name(:pack_plans, socket.assigns.team_id), data: blank_plan_data(), team_id: socket.assigns.team_id}

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
  def handle_event("template_" <> action, params, socket), do: {:noreply, template_event(socket, action, params, :pack_plans, :pack_plan_id, &load_plan/3)}

  @impl true
  def handle_event("clipboard_status", %{"text" => text}, socket), do: {:noreply, paste_status(socket, :pack_plans, text)}

  @impl true
  def handle_event("toggle_extreme_mode", _, socket) do
    plan_data = socket.assigns.plan_data

    plan_data =
      if Resolver.extreme?(plan_data),
        do: Map.put(plan_data, "extreme", false),
        else: Resolver.with_mode_override(plan_data, "extreme")

    {:noreply, socket |> assign(:plan_data, plan_data) |> persist_plan()}
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
  def handle_event("set_view", %{"view" => view}, socket) when view in ~w(plan normal hard extreme) do
    {:noreply, assign(socket, :view, view)}
  end

  @impl true
  def handle_event("filter_packs", %{"value" => val}, socket) do
    {:noreply, assign(socket, :filter, val)}
  end

  @impl true
  def handle_event("toggle_cell", %{"pack_id" => pack_id, "mode" => mode, "floors" => floors, "action" => action}, socket)
      when mode in @modes and action in @cell_actions do
    case requested_floors(socket, pack_id, mode, floors) do
      [] ->
        {:noreply, socket}

      floors ->
        plan_data = socket.assigns.plan_data
        statuses = Map.new(floors, &{&1, Resolver.status_at(plan_data, pack_id, mode, &1)})
        plan_data = Enum.reduce(cell_changes(statuses, action), plan_data, fn {floor, status}, acc -> put_status(acc, pack_id, mode, floor, status) end)
        {:noreply, socket |> assign(:plan_data, plan_data) |> persist_plan()}
    end
  end

  @impl true
  def handle_event("set_row_status", %{"pack_id" => pack_id, "mode" => mode, "floors" => floors, "status" => status}, socket)
      when mode in @modes and status in @cell_actions do
    case requested_floors(socket, pack_id, mode, floors) do
      [] ->
        {:noreply, socket}

      floors ->
        plan_data = socket.assigns.plan_data
        target = if row_status?(plan_data, pack_id, mode, floors, status), do: "none", else: status
        plan_data = Enum.reduce(floors, plan_data, &put_status(&2, pack_id, mode, &1, target))
        {:noreply, socket |> assign(:plan_data, plan_data) |> persist_plan()}
    end
  end

  @impl true
  def handle_event("toggle_path_floor", %{"floor" => floor}, socket) do
    floor = String.to_integer(floor)
    {:noreply, socket |> assign(:path_floor, if(socket.assigns.path_floor == floor, do: nil, else: floor)) |> assign(:path_browse, false)}
  end

  @impl true
  def handle_event("close_path_floor", _, socket), do: {:noreply, socket |> assign(:path_floor, nil) |> assign(:path_query, "") |> assign(:path_browse, false)}

  @impl true
  def handle_event("path_clear_floor", %{"floor" => floor}, socket) do
    floor = String.to_integer(floor)
    plan_data = socket.assigns.plan_data
    mode = path_mode(plan_data, floor, socket.assigns.view)

    plan_data =
      socket.assigns.theme_packs
      |> Enum.filter(&(Resolver.priority_at(plan_data, &1, mode, floor) == "hunt"))
      |> Enum.reduce(plan_data, &put_status(&2, &1.id, mode, floor, "none"))

    {:noreply, socket |> assign(:plan_data, plan_data) |> assign(:path_floor, nil) |> assign(:path_query, "") |> assign(:path_browse, false) |> persist_plan()}
  end

  @impl true
  def handle_event("path_query", %{"query" => query}, socket), do: {:noreply, socket |> assign(:path_query, query) |> assign(:path_browse, socket.assigns.path_browse and String.trim(query) == "")}

  @impl true
  def handle_event("path_browse", _, socket), do: {:noreply, assign(socket, :path_browse, true)}

  @impl true
  def handle_event("path_key", %{"key" => "Escape"}, socket), do: handle_event("close_path_floor", %{}, socket)

  @impl true
  def handle_event("path_query_clear", _, socket), do: {:noreply, socket |> assign(:path_query, "") |> assign(:path_browse, false)}

  @impl true
  def handle_event("path_add", %{"floor" => floor, "pack_id" => pack_id}, socket) do
    floor = String.to_integer(floor)
    mode = path_mode(socket.assigns.plan_data, floor, socket.assigns.view)
    pack = Enum.find(path_options(socket.assigns.plan_data, socket.assigns.theme_packs, floor, mode), &(&1.id == pack_id))
    {:noreply, add_path_pack(socket, pack, mode, floor)}
  end

  @impl true
  def handle_event("path_add", %{"floor" => floor, "query" => query}, socket) do
    floor = String.to_integer(floor)
    mode = path_mode(socket.assigns.plan_data, floor, socket.assigns.view)
    pack = if String.trim(query) == "", do: nil, else: socket.assigns.plan_data |> path_matches(socket.assigns.theme_packs, floor, mode, query) |> List.first()
    {:noreply, add_path_pack(socket, pack, mode, floor)}
  end

  @impl true
  def handle_event("path_reorder", %{"scope" => scope, "ids" => ids}, socket) do
    case parse_path_scope(scope) do
      {mode, floor, _favorite?} -> {:noreply, socket |> reorder_path(mode, floor, ids) |> persist_plan()}
      :error -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("path_move", %{"scope" => scope, "id" => id, "ids" => ids}, socket) do
    with {mode, floor, favorite?} <- parse_path_scope(scope),
         "hunt" <- Resolver.priority_at(socket.assigns.plan_data, %{id: id}, mode, floor) do
      plan_data = put_status(socket.assigns.plan_data, id, mode, floor, if(favorite?, do: "favorite", else: "hunt"))
      {:noreply, socket |> assign(:plan_data, plan_data) |> reorder_path(mode, floor, ids) |> persist_plan()}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_favorite", %{"pack_id" => pack_id, "mode" => mode, "floor" => floor}, socket) when mode in @modes do
    floor = String.to_integer(floor)
    plan_data = socket.assigns.plan_data

    case Resolver.status_at(plan_data, pack_id, mode, floor) do
      status when status in @hunted ->
        plan_data = put_status(plan_data, pack_id, mode, floor, if(status == "favorite", do: "hunt", else: "favorite"))
        {:noreply, socket |> assign(:plan_data, plan_data) |> persist_plan()}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("path_remove", %{"pack_id" => pack_id, "mode" => mode, "floor" => floor}, socket) when mode in @modes do
    plan_data = put_status(socket.assigns.plan_data, pack_id, mode, String.to_integer(floor), "none")
    {:noreply, socket |> assign(:plan_data, plan_data) |> persist_plan()}
  end

  @impl true
  def handle_event("toggle_help", _, socket), do: {:noreply, update(socket, :show_help, &(!&1))}

  @impl true
  def handle_event("toggle_odds", _, socket), do: {:noreply, update(socket, :show_odds, &(!&1))}

  # --- Display helpers (used from the template) ---

  def max_floor(true), do: 15
  def max_floor(false), do: 5

  def path_row(assigns) do
    ~H"""
    <div data-sort-id={@alt.id} data-sort-handle class="rounded-full cursor-grab">
      <div class={"flex items-center gap-1 rounded-full border pl-1 pr-1 py-0.5 text-[10px] " <> if(@hard?, do: "border-warning bg-warning/30", else: "border-success/60 bg-success/30")}
           style={"opacity: #{path_alt_opacity(@index, @total)}"}>
        <span data-sort-handle class="cursor-grab text-base-content/50 select-none" title="Drag to reorder, or between lists to change favorite">⠿</span>
        <img src={@alt.image_path} class="w-4 h-4 rounded-full object-cover shrink-0" draggable="false" />
        <span class="truncate flex-1"><%= @alt.name_en %></span>
        <span :if={@percent} class="shrink-0 text-[9px] font-mono text-base-content/70"><%= @percent %></span>
        <span class="shrink-0 text-[9px] text-base-content/60"><%= @index + 1 %></span>
        <button type="button" phx-click="path_remove" phx-value-pack_id={@alt.id} phx-value-mode={@mode} phx-value-floor={@floor}
                class="shrink-0 leading-none text-base-content/50 hover:text-error cursor-pointer" title="Remove from Hunt">
          ✕
        </button>
      </div>
    </div>
    """
  end

  def chart_rows(plan_data, theme_packs, filter, floor_filter, floor_count, view \\ "plan") do
    schedule = plan_data["mode_schedule"]

    theme_packs
    |> Enum.filter(&matches_filter?(&1, filter))
    |> Enum.flat_map(fn pack ->
      Enum.map(view_modes(view), fn mode ->
        floors =
          if view == "plan",
            do: Enum.filter(Resolver.eligible_floors(pack, mode), &(Resolver.mode_for_floor(schedule, &1) == mode)),
            else: Resolver.eligible_floors(pack, mode)

        %{pack: pack, mode: mode, floors: floors}
      end)
    end)
    |> Enum.filter(&(&1.floors != [] and Enum.min(&1.floors) <= floor_count))
    |> Enum.filter(&(floor_filter == nil or floor_filter in &1.floors))
    |> Enum.sort_by(&Enum.min_max(&1.floors))
  end

  defp view_modes("plan"), do: @modes
  defp view_modes("extreme"), do: ["hard"]
  defp view_modes(view), do: [view]

  def view_button_class(view, view), do: active_view_class(view)
  def view_button_class(_view, _current), do: ""

  defp active_view_class("plan"), do: "btn-neutral"
  defp active_view_class("normal"), do: "btn-success"
  defp active_view_class("hard"), do: "btn-warning"
  defp active_view_class("extreme"), do: "btn-error"

  def cell_fill_class("favorite"), do: "bg-warning/30 hover:bg-warning/50"
  def cell_fill_class("hunt"), do: "bg-success/30 hover:bg-success/50"
  def cell_fill_class("banned"), do: "bg-error/30 hover:bg-error/50"
  def cell_fill_class("none"), do: "hover:bg-base-content/10"

  def overflow?(extreme?), do: not extreme?

  def path_alt_opacity(index, total), do: Float.round(1.0 - 0.65 * index / max(total - 1, 1), 2)

  def path_mode(plan_data, floor, "plan"), do: Resolver.mode_for_floor(plan_data["mode_schedule"], floor)
  def path_mode(_plan_data, _floor, "extreme"), do: "hard"
  def path_mode(_plan_data, _floor, view), do: view

  def view_warning(plan_data, "hard") do
    case Enum.find(1..5, &(Resolver.mode_for_floor(plan_data["mode_schedule"], &1) == "hard")) do
      1 -> nil
      floor -> {"Hiding normal packs on F1#{if floor > 2, do: "-F#{floor-1}", else: ""}", "This plan starts on normal at F1. All hard shows hard picks on every floor, so it won't match what the run does."}
    end
  end

  def view_warning(plan_data, "normal") do
    case Enum.find(1..5, &(Resolver.mode_for_floor(plan_data["mode_schedule"], &1) == "hard")) do
      nil -> nil
      floor -> {"Hiding hard packs on F#{floor}+", "This plan switches to hard at F#{floor}. All normal shows normal picks on every floor, so it won't match what the run does."}
    end
  end

  def view_warning(_plan_data, _view), do: nil

  def path_candidates({pack, rest}), do: [pack | rest]
  def path_candidates(nil), do: []

  def likely_path(plan_data, theme_packs, floor_count, view) do
    {path, _picked} =
      Enum.map_reduce(1..floor_count, MapSet.new(), fn floor, picked ->
        mode = path_mode(plan_data, floor, view)

        theme_packs
        |> Enum.filter(&(floor in Resolver.eligible_floors(&1, mode) and Resolver.priority_at(plan_data, &1, mode, floor) == "hunt"))
        |> Enum.reject(&MapSet.member?(picked, &1.id))
        |> Resolver.sort_hunt(plan_data, mode, floor)
        |> case do
          [] -> {{floor, nil}, picked}
          [top | rest] -> {{floor, {top, rest}}, MapSet.put(picked, top.id)}
        end
      end)

    Map.new(path)
  end

  def floor_candidates(plan_data, theme_packs, floor, mode) do
    theme_packs
    |> Enum.filter(&(floor in Resolver.eligible_floors(&1, mode) and Resolver.priority_at(plan_data, &1, mode, floor) == "hunt"))
    |> Resolver.sort_hunt(plan_data, mode, floor)
  end

  def path_options(plan_data, theme_packs, floor, mode) do
    Enum.filter(theme_packs, &(floor in Resolver.eligible_floors(&1, mode) and Resolver.status_at(plan_data, &1.id, mode, floor) not in ~w(banned hunt favorite)))
  end

  def path_matches(plan_data, theme_packs, floor, mode, query) do
    needle = query |> String.trim() |> String.downcase()
    name = &String.downcase(&1.name_en || "")

    options = path_options(plan_data, theme_packs, floor, mode)

    if needle == "" do
      options
    else
      {starts, rest} = options |> Enum.filter(&String.contains?(name.(&1), needle)) |> Enum.split_with(&String.starts_with?(name.(&1), needle))
      Enum.take(starts ++ rest, 8)
    end
  end

  defp add_path_pack(socket, nil, _mode, _floor), do: socket

  defp add_path_pack(socket, pack, mode, floor) do
    plan_data =
      if Resolver.priority_at(socket.assigns.plan_data, pack, mode, floor) == "hunt",
        do: socket.assigns.plan_data,
        else: put_status(socket.assigns.plan_data, pack.id, mode, floor, "hunt")

    socket |> assign(:plan_data, plan_data) |> assign(:path_query, "") |> assign(:path_browse, false) |> persist_plan()
  end

  def extreme_disabled?(plan_data), do: not Resolver.extreme?(plan_data)

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

  def row_status?(plan_data, pack_id, mode, floors, status) do
    Enum.all?(floors, &(Resolver.status_at(plan_data, pack_id, mode, &1) == status))
  end

  def cell_status(plan_data, row, cell_floors) do
    statuses = Enum.map(cell_floors, &Resolver.status_at(plan_data, row.pack.id, row.mode, &1))
    hunted = Enum.filter(statuses, &(&1 in @hunted))

    cond do
      hunted != [] and Enum.all?(hunted, &(&1 == "favorite")) -> "favorite"
      hunted != [] -> "hunt"
      "banned" in statuses -> "banned"
      true -> "none"
    end
  end

  def cell_changes(statuses, "hunt") do
    if Enum.all?(statuses, fn {_floor, status} -> status in @hunted end),
      do: for({floor, _status} <- statuses, do: {floor, "none"}),
      else: for({floor, status} <- statuses, status not in @hunted, do: {floor, "hunt"})
  end

  def cell_changes(statuses, "banned") do
    target = if Enum.all?(statuses, fn {_floor, status} -> status == "banned" end), do: "none", else: "banned"
    for {floor, _status} <- statuses, do: {floor, target}
  end

  def cell_changes(statuses, "favorite") do
    hunted = for {floor, status} <- statuses, status in @hunted, do: {floor, status}
    target = if Enum.all?(hunted, fn {_floor, status} -> status == "favorite" end), do: "hunt", else: "favorite"
    for {floor, _status} <- hunted, do: {floor, target}
  end

  defp visible_floors(row, floor_count, overflow?) do
    if overflow?, do: row.floors, else: Enum.filter(row.floors, &(&1 <= floor_count))
  end

  defp column_of(floor, floor_count), do: min(floor, floor_count + 1)

  # --- Private ---

  defp matches_filter?(_pack, ""), do: true
  defp matches_filter?(pack, filter), do: String.contains?(String.downcase(pack.name_en || ""), String.downcase(filter))

  defp refresh_grace_picks(socket) do
    case Teams.get_team(socket.assigns.team_id) do
      %{grace_picks: picks} -> assign(socket, :grace_picks, picks)
      _ -> socket
    end
  end

  def run_odds(plan_data, theme_packs, floor_count, view, grace_picks) do
    floor_modes = Enum.map(1..floor_count, &{&1, path_mode(plan_data, &1, view)})
    Odds.for_run(plan_data, theme_packs, floor_modes, grace_picks)
  end

  def odds_percent(%{probs: probs}, pack_id) do
    case probs[pack_id] do
      nil -> nil
      prob -> Odds.percent(prob)
    end
  end

  def odds_choose({n, k}), do: "C(#{n},#{k})"

  def odds_pct(prob), do: Odds.percent(prob)

  def odds_decimal(prob), do: :erlang.float_to_binary(prob * 1.0, decimals: 4)

  def odds_bar(%{rows: rows, fallback: fallback}) do
    segments =
      Enum.map(rows, &%{label: &1.pack.name_en, kind: &1.kind, rank: &1.rank, prob: &1.final}) ++
        [%{label: "No hunted or backup pack (default or fallback pick)", kind: :rest, rank: 0, prob: fallback}]

    Enum.reject(segments, &(&1.prob <= 0.0))
  end

  def odds_segment_style(%{kind: :wanted, rank: rank}, count), do: "background: color-mix(in oklab, var(--color-warning) #{round(100 - 60 * (rank - 1) / max(count - 1, 1))}%, transparent)"
  def odds_segment_style(%{kind: :backup}, _count), do: "background: color-mix(in oklab, var(--color-info) 55%, transparent)"
  def odds_segment_style(%{kind: :rest}, _count), do: "background: color-mix(in oklab, var(--color-base-content) 20%, transparent)"

  def odds_summary(%{any: any, shown: shown, looks: looks, searching?: searching?}) do
    base = "#{shown} packs shown, #{looks - 1} refreshes"
    if searching?, do: "#{base}, then pack search: top pack guaranteed", else: "#{Odds.percent(any)} chance a hunted pack appears (#{base})"
  end

  defp reset_editor(socket) do
    socket
    |> assign(:editing_id, nil)
    |> assign(:name, "")
    |> assign(:plan_data, blank_plan_data())
    |> assign(:floor_filter, nil)
    |> assign(:filter, "")
    |> assign(:path_floor, nil)
    |> assign(:path_query, "")
    |> assign(:path_browse, false)
  end

  defp load_plan(socket, id, template_id \\ nil) do
    case Plans.for_team(%{pack_plan_id: id, pack_template_id: template_id}, :pack_plans) do
      nil ->
        put_flash(socket, :error, "Plan not found.")

      plan ->
        socket
        |> assign(:editing_id, id)
        |> assign(:template_id, plan.template_id)
        |> assign(:name, plan.name)
        |> assign(:plan_data, normalize_plan_data(plan.data))
        |> assign(:floor_filter, nil)
        |> assign(:filter, "")
        end
  end

  defp persist_plan(%{assigns: %{template_id: template_id}} = socket) when is_integer(template_id), do: socket

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

  defp requested_floors(socket, pack_id, mode, floors) do
    pack = socket.assigns.packs_by_id[pack_id]
    eligible = if pack, do: Resolver.eligible_floors(pack, mode), else: []
    floors |> String.split(",", trim: true) |> Enum.map(&String.to_integer/1) |> Enum.filter(&(&1 in eligible))
  end

  defp put_status(plan_data, pack_id, mode, floor, status) do
    key = Integer.to_string(floor)
    floors = get_in(plan_data, ["packs", pack_id, mode]) || %{}
    floors = if status == "none", do: Map.delete(floors, key), else: Map.put(floors, key, status)
    modes = if floors == %{}, do: Map.delete(get_in(plan_data, ["packs", pack_id]) || %{}, mode), else: Map.put(get_in(plan_data, ["packs", pack_id]) || %{}, mode, floors)
    packs = plan_data["packs"] || %{}
    packs = if modes == %{}, do: Map.delete(packs, pack_id), else: Map.put(packs, pack_id, modes)
    order = Resolver.hunt_order(plan_data, mode, floor)

    order =
      cond do
        status not in @hunted -> List.delete(order, pack_id)
        pack_id in order -> order
        true -> order ++ [pack_id]
      end

    plan_data |> Map.put("packs", packs) |> put_order(mode, key, order)
  end

  defp put_order(plan_data, mode, key, order) do
    floors = plan_data |> get_in(["order", mode]) |> Kernel.||(%{})
    floors = if order == [], do: Map.delete(floors, key), else: Map.put(floors, key, order)
    modes = plan_data |> Map.get("order", %{}) |> then(&if(floors == %{}, do: Map.delete(&1, mode), else: Map.put(&1, mode, floors)))
    if modes == %{}, do: Map.delete(plan_data, "order"), else: Map.put(plan_data, "order", modes)
  end

  defp parse_path_scope(scope) do
    case String.split(scope, ":") do
      [mode, floor, group] when mode in @modes and group in ~w(fav rest) -> {mode, String.to_integer(floor), group == "fav"}
      _ -> :error
    end
  end

  defp reorder_path(socket, mode, floor, ids) do
    plan_data = socket.assigns.plan_data
    current = Resolver.hunt_order(plan_data, mode, floor)

    if ids == Enum.uniq(ids) and Enum.all?(ids, &(&1 in current)) do
      members = MapSet.new(ids)

      {merged, _} =
        Enum.map_reduce(current, ids, fn id, remaining ->
          if MapSet.member?(members, id) do
            [next | rest] = remaining
            {next, rest}
          else
            {id, remaining}
          end
        end)

      assign(socket, :plan_data, put_order(plan_data, mode, Integer.to_string(floor), merged))
    else
      socket
    end
  end
end
