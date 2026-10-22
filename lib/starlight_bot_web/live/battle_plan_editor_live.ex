defmodule StarlightBotWeb.Live.BattlePlanEditorLive do
  use StarlightBotWeb, :live_view
  import StarlightBotWeb.Components.ConditionTree
  import StarlightBotWeb.Components.PlanPicker

  alias StarlightBot.{BattlePlans, Conditions, Hooks, Plans, SinnerProfiles, Teams}
  alias StarlightBot.BattlePlans.Resolver

  @collapsed_floors 5
  @sinner_rows [~w(yi_sang faust don_quixote ryoshu meursault hong_lu), ~w(heathcliff ishmael rodion sinclair outis gregor)]

  @impl true
  def mount(_params, session, socket) do
    team = session["team_id"] && Teams.get_team(session["team_id"])

    socket =
      socket
      |> assign(:team_id, team && team.id)
      |> assign(:plans, Plans.list(:battle_plans))
      |> assign(:hook_names, Enum.map(Hooks.list_hooks(), & &1.name))
      |> assign_profiles()
      |> reset_editor()

    {:ok, if(team && team.battle_plan_id, do: load_plan(socket, team.battle_plan_id), else: socket)}
  end

  @impl true
  def handle_event("new_plan", _, socket) do
    attrs = %{name: Plans.new_name(:battle_plans, socket.assigns.team_id), data: BattlePlans.blank()}

    case Plans.save(:battle_plans, attrs) do
      {:ok, id} -> {:noreply, socket |> assign(:plans, Plans.list(:battle_plans)) |> load_plan(id) |> link_team(:battle_plan_id)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("select_plan", %{"id" => id}, socket) do
    {:noreply, socket |> load_plan(String.to_integer(id)) |> link_team(:battle_plan_id)}
  end

  @impl true
  def handle_event("duplicate_plan", %{"id" => id}, socket) do
    case Plans.get(:battle_plans, String.to_integer(id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Plan not found.")}

      plan ->
        case Plans.save(:battle_plans, %{name: "#{plan.name} (copy)", data: plan.data}) do
          {:ok, new_id} ->
            {:noreply, socket |> assign(:plans, Plans.list(:battle_plans)) |> load_plan(new_id) |> link_team(:battle_plan_id)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Duplicate failed: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def handle_event("delete_plan", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Plans.delete(:battle_plans, id) do
      {:ok, _} ->
        socket = if socket.assigns.editing_id == id, do: reset_editor(socket), else: socket

        {:noreply,
         socket
         |> assign(:plans, Plans.list(:battle_plans))
         |> link_team(:battle_plan_id)
         |> put_flash(:info, "Plan deleted.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("rename_plan", %{"value" => name}, socket) do
    case String.trim(name) do
      "" -> {:noreply, socket}
      name -> {:noreply, socket |> assign(:name, name) |> persist() |> link_team(:battle_plan_id)}
    end
  end

  @impl true
  def handle_event("set_max_retries", %{"max_retries" => value}, socket) do
    case Integer.parse(value) do
      {n, _} when n >= 0 -> {:noreply, socket |> assign(:data, Map.put(socket.assigns.data, "max_retries", n)) |> persist()}
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_extreme", _, socket) do
    {:noreply, update(socket, :extreme?, &(not &1))}
  end

  @impl true
  def handle_event("set_paint", %{"id" => "erase"}, socket) do
    {:noreply, assign(socket, :paint, "erase")}
  end

  @impl true
  def handle_event("set_paint", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:paint, id) |> assign(:playbook_id, id)}
  end

  @impl true
  def handle_event("paint_cell", %{"track" => track, "floor" => floor}, socket) do
    floor = String.to_integer(floor)
    paint = socket.assigns.paint
    entries = socket.assigns.data["tracks"][track]

    cond do
      paint == "erase" ->
        {:noreply, put_track(socket, track, BattlePlans.erase(entries, floor))}

      playbook = find_playbook(socket.assigns.data, paint) ->
        if playbook["kind"] == BattlePlans.track_kind(track) do
          {:noreply, put_track(socket, track, BattlePlans.paint(entries, floor, paint))}
        else
          {:noreply, put_flash(socket, :error, "'#{playbook["name"]}' is a #{playbook["kind"]} playbook; it can't go on a #{BattlePlans.track_kind(track)} track.")}
        end

      true ->
        {:noreply, put_flash(socket, :error, "Pick a playbook to paint with first.")}
    end
  end

  @impl true
  def handle_event("paint_lineup", %{"venue" => venue, "floor" => floor}, socket) do
    floor = String.to_integer(floor)
    lineup_id = socket.assigns.lineup_id
    entries = BattlePlans.lineup_track(socket.assigns.data, venue)

    cond do
      socket.assigns.lineup_erase? ->
        {:noreply, put_lineup_track(socket, venue, BattlePlans.erase(entries, floor, "lineup"))}

      BattlePlans.find_lineup(socket.assigns.data, lineup_id) ->
        {:noreply, put_lineup_track(socket, venue, BattlePlans.paint(entries, floor, lineup_id, "lineup"))}

      true ->
        {:noreply, put_flash(socket, :error, "Pick a lineup to paint lineup rows with.")}
    end
  end

  @impl true
  def handle_event("toggle_lineup_erase", _, socket) do
    {:noreply, update(socket, :lineup_erase?, &(not &1))}
  end

  @impl true
  def handle_event("select_playbook", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:playbook_id, id) |> assign(:paint, id)}
  end

  @impl true
  def handle_event("select_lineup", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:lineup_id, id) |> assign(:lineup_erase?, false)}
  end

  @impl true
  def handle_event("new_lineup", _, socket) do
    lineup = BattlePlans.new_lineup("Lineup #{length(BattlePlans.lineups(socket.assigns.data)) + 1}")

    {:noreply,
     socket
     |> assign(:data, Map.put(socket.assigns.data, "lineups", BattlePlans.lineups(socket.assigns.data) ++ [lineup]))
     |> assign(:lineup_id, lineup["id"])
     |> assign(:lineup_erase?, false)
     |> persist()}
  end

  @impl true
  def handle_event("delete_lineup", %{"id" => id}, socket) do
    case BattlePlans.venues_using(socket.assigns.data, id) do
      [] ->
        lineups = Enum.reject(BattlePlans.lineups(socket.assigns.data), &(&1["id"] == id))

        {:noreply,
         socket
         |> assign(:data, Map.put(socket.assigns.data, "lineups", lineups))
         |> assign(:lineup_id, if(socket.assigns.lineup_id == id, do: get_in(List.first(lineups), ["id"]), else: socket.assigns.lineup_id))
         |> persist()}

      venues ->
        {:noreply, put_flash(socket, :error, "Still assigned on: #{Enum.map_join(venues, ", ", &BattlePlans.venue_label/1)}.")}
    end
  end

  @impl true
  def handle_event("start_rename_lineup", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:lineup_id, id) |> assign(:renaming_lineup_id, id)}
  end

  @impl true
  def handle_event("cancel_rename_lineup", _, socket) do
    {:noreply, assign(socket, :renaming_lineup_id, nil)}
  end

  @impl true
  def handle_event("rename_lineup", %{"value" => name}, socket) do
    id = socket.assigns.renaming_lineup_id
    socket = assign(socket, :renaming_lineup_id, nil)

    case {id, String.trim(name)} do
      {nil, _} -> {:noreply, socket}
      {_, ""} -> {:noreply, socket}
      {id, name} -> {:noreply, socket |> assign(:lineup_id, id) |> update_lineup(&Map.put(&1, "name", name))}
    end
  end

  @impl true
  def handle_event("toggle_lineup_sinner", %{"sinner" => sinner}, socket) when is_binary(sinner) do
    {:noreply,
     update_lineup(socket, fn lineup ->
       Map.update!(lineup, "sinners", fn sinners -> if sinner in sinners, do: List.delete(sinners, sinner), else: sinners ++ [sinner] end)
     end)}
  end

  @impl true
  def handle_event("clear_lineup", _, socket) do
    {:noreply, update_lineup(socket, &Map.put(&1, "sinners", []))}
  end

  @impl true
  def handle_event("new_playbook", %{"kind" => kind}, socket) when kind in ~w(chain focused) do
    count = Enum.count(socket.assigns.data["playbooks"], &(&1["kind"] == kind))
    playbook = BattlePlans.new_playbook(kind, "#{String.capitalize(kind)} #{count + 1}")
    {:noreply, socket |> add_playbook(playbook)}
  end

  @impl true
  def handle_event("duplicate_playbook", %{"id" => id}, socket) do
    case find_playbook(socket.assigns.data, id) do
      nil -> {:noreply, socket}
      source -> {:noreply, add_playbook(socket, copy_playbook(source))}
    end
  end

  @impl true
  def handle_event("delete_playbook", %{"id" => id}, socket) do
    case BattlePlans.tracks_using(socket.assigns.data, id) do
      [] ->
        data = Map.update!(socket.assigns.data, "playbooks", fn pbs -> Enum.reject(pbs, &(&1["id"] == id)) end)

        {:noreply,
         socket
         |> assign(:data, data)
         |> assign(:playbook_id, nil)
         |> assign(:paint, if(socket.assigns.paint == id, do: nil, else: socket.assigns.paint))
         |> persist()}

      tracks ->
        {:noreply, put_flash(socket, :error, "Still assigned on: #{Enum.map_join(tracks, ", ", &track_label/1)}.")}
    end
  end

  @impl true
  def handle_event("rename_playbook", %{"value" => name}, socket) do
    case String.trim(name) do
      "" -> {:noreply, socket}
      name -> {:noreply, update_playbook(socket, &Map.put(&1, "name", name))}
    end
  end

  @impl true
  def handle_event("split_phase", %{"turn" => turn}, socket) do
    {:noreply, update_playbook(socket, &BattlePlans.split_phase(&1, String.to_integer(turn)))}
  end

  @impl true
  def handle_event("remove_phase", %{"turn" => turn}, socket) do
    {:noreply, update_playbook(socket, &BattlePlans.remove_phase(&1, String.to_integer(turn)))}
  end

  @impl true
  def handle_event("add_action", %{"turn" => turn, "type" => type, "parent" => parent, "branch" => branch}, socket)
      when type != "" and branch in ["then", "else"] do
    kind = find_playbook(socket.assigns.data, socket.assigns.playbook_id)["kind"]

    {:noreply,
     update_phase(socket, String.to_integer(turn), fn actions ->
       update_list_containing(actions, parent, fn list ->
         Enum.map(list, fn
           %{"id" => ^parent} = block ->
             if type in branch_available_actions(kind, actions, block, branch),
               do: Map.update!(block, branch, &(&1 ++ [BattlePlans.new_action(type)])),
               else: block

           action ->
             action
         end)
       end)
     end)}
  end

  @impl true
  def handle_event("add_action", %{"turn" => turn, "type" => type}, socket) when type != "" do
    playbook = find_playbook(socket.assigns.data, socket.assigns.playbook_id)

    {:noreply,
     update_phase(socket, String.to_integer(turn), fn actions ->
       if type in available_actions(playbook, actions), do: actions ++ [BattlePlans.new_action(type)], else: actions
     end)}
  end

  @impl true
  def handle_event("add_action", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("move_action", %{"turn" => turn, "action" => action_id, "dir" => dir}, socket) do
    offset = if dir == "up", do: -1, else: 1

    {:noreply,
     update_phase(socket, String.to_integer(turn), fn actions ->
       update_list_containing(actions, action_id, fn list ->
         index = Enum.find_index(list, &(&1["id"] == action_id))
         target = index + offset

         if target < 0 or target >= length(list) do
           list
         else
           list |> List.delete_at(index) |> List.insert_at(target, Enum.at(list, index))
         end
       end)
     end)}
  end

  @impl true
  def handle_event("remove_action", %{"turn" => turn, "action" => action_id}, socket) do
    {:noreply,
     update_phase(socket, String.to_integer(turn), fn actions ->
       update_list_containing(actions, action_id, fn list -> Enum.reject(list, &(&1["id"] == action_id)) end)
     end)}
  end

  @impl true
  def handle_event("cond_add", %{"turn" => turn, "action" => action_id, "path" => path, "node" => node}, socket) do
    leaf = BattlePlans.hook_leaf()
    child = if node == "group", do: Conditions.group(leaf), else: leaf
    {:noreply, update_condition(socket, turn, action_id, &Conditions.add(&1, path, child))}
  end

  @impl true
  def handle_event("cond_remove", %{"turn" => turn, "action" => action_id, "path" => path}, socket) do
    {:noreply, update_condition(socket, turn, action_id, &Conditions.remove(&1, path))}
  end

  @impl true
  def handle_event("cond_toggle_op", %{"turn" => turn, "action" => action_id, "path" => path}, socket) do
    {:noreply, update_condition(socket, turn, action_id, &Conditions.toggle_op(&1, path))}
  end

  @impl true
  def handle_event("cond_update", %{"turn" => turn, "action" => action_id, "path" => path} = params, socket) do
    leaf = BattlePlans.condition_leaf(params)
    {:noreply, update_condition(socket, turn, action_id, &Conditions.put_leaf(&1, path, leaf))}
  end

  @impl true
  def handle_event("update_action", %{"turn" => turn, "action" => action_id} = params, socket) do
    {:noreply, update_action(socket, String.to_integer(turn), action_id, &apply_action_params(&1, params))}
  end

  @impl true
  def handle_event("add_pin", %{"turn" => turn, "action" => action_id}, socket) do
    {:noreply, update_action(socket, String.to_integer(turn), action_id, &Map.update!(&1, "pins", fn pins -> pins ++ [BattlePlans.new_pin()] end))}
  end

  @impl true
  def handle_event("remove_sinner", %{"turn" => turn, "action" => action_id, "profile" => profile} = params, socket) do
    profile_id = String.to_integer(profile)
    drop = fn holder -> Map.update(holder, "profile_ids", [], &List.delete(&1, profile_id)) end

    update =
      case parse_id(params["pin"]) do
        nil -> drop
        index -> &Map.update!(&1, "pins", fn pins -> List.update_at(pins, index, drop) end)
      end

    {:noreply, update_action(socket, String.to_integer(turn), action_id, update)}
  end

  @impl true
  def handle_event("reorder_pins", %{"scope" => scope, "ids" => ids}, socket) do
    [turn, action_id] = String.split(scope, "|")
    order = Enum.map(ids, &String.to_integer/1)

    {:noreply,
     update_action(socket, String.to_integer(turn), action_id, fn action ->
       pins = action["pins"]
       if Enum.sort(order) == Enum.to_list(0..(length(pins) - 1)//1), do: Map.put(action, "pins", Enum.map(order, &Enum.at(pins, &1))), else: action
     end)}
  end

  @impl true
  def handle_event("remove_pin", %{"turn" => turn, "action" => action_id, "index" => index}, socket) do
    index = String.to_integer(index)
    {:noreply, update_action(socket, String.to_integer(turn), action_id, &Map.update!(&1, "pins", fn pins -> List.delete_at(pins, index) end))}
  end

  def floors(true), do: Enum.to_list(1..BattlePlans.max_floor())
  def floors(false), do: Enum.to_list(1..@collapsed_floors)

  def track_label("normal_chain"), do: "Normal Chain"
  def track_label("normal_focused"), do: "Normal Focused"
  def track_label("hard_chain"), do: "Hard Chain"
  def track_label("hard_focused"), do: "Hard Focused"
  def track_label("lux_chain"), do: "Lux Chain"
  def track_label("lux_focused"), do: "Lux Focused"

  def sinner_rows, do: @sinner_rows

  def sinner_label(key), do: key |> String.split("_") |> Enum.map_join(" ", &String.capitalize/1)

  def lineup_color(data, id, alpha) do
    index = Enum.find_index(BattlePlans.lineups(data), &(&1["id"] == id)) || 0
    "background-color: hsl(#{rem(index * 67 + 20, 360)} 45% 42% / #{alpha});"
  end

  def lineup_tooltip(data, entries, floor) do
    id = Resolver.lineup_id_at(entries, floor)
    lineup = BattlePlans.find_lineup(data, id)
    sinners = if lineup && lineup["sinners"] != [], do: Enum.map_join(lineup["sinners"], ", ", &sinner_label/1), else: "nobody"
    "Floor #{floor}: #{(lineup && lineup["name"]) || "no lineup"} (#{sinners})"
  end

  def plan_issues(%{data: data}) when is_map(data), do: BattlePlans.lineup_issues(data)
  def plan_issues(_plan), do: []

  def action_label("win_rate"), do: "Win rate (p)"
  def action_label("damage_rate"), do: "Damage rate (p p)"
  def action_label("commit"), do: "Commit (enter)"
  def action_label("clear"), do: "Unchoose all"
  def action_label("dodge"), do: "Dodge"
  def action_label("ego"), do: "EGO"
  def action_label("target"), do: "Target enemy"
  def action_label("if"), do: "If"
  def action_label("retry"), do: "Retry battle"
  def action_label("chain_fast"), do: "Chain fast (no S3)"
  def action_label("chain_a_res"), do: "Chain A-Res"

  def action_tooltip("win_rate"), do: "Press p so Limbus assigns every choice for the best win rate."
  def action_tooltip("damage_rate"),
    do: "Press p until battle_combat_ready, then p again so Limbus assigns every choice for the most damage. If that clears the choices, cycles back around to damage."

  def action_tooltip("commit"), do: "Press enter to start the turn once every skill is chosen."
  def action_tooltip("clear"), do: "Press p until battle_combat_ready stops matching."
  def action_tooltip("dodge"), do: "Click below the chosen skill slot to swap it to dodge."
  def action_tooltip("ego"), do: "Hold below the chosen skill slot to open the EGO menu, then pick the grade's card."
  def action_tooltip("target"),
    do: "Drag the chosen skill onto an enemy target, found by the white icon above a yellow number. Gives up after 3 tries."

  def action_tooltip("retry"),
    do: "Open battle settings and retry the battle. Once the retries per battle are used up, gives up instead."

  def action_tooltip("if"), do: "Check the condition once against a fresh frame, then run the then actions or the else actions."

  def action_tooltip("chain_fast"), do: "Chain without S3, which takes too long to animate. Prefers S2, then S1."
  def action_tooltip("chain_a_res"), do: "Chain for the longest same-sin streaks to maximize clash power."

  def pick_label("first"), do: "first"
  def pick_label("last"), do: "last"
  def pick_label("exact"), do: "exactly #"
  def pick_label("up_to"), do: "up to #"
  def pick_label("all"), do: "all"
  def pick_label("first_with"), do: "first # with"
  def pick_label("percent"), do: "at %"

  def skill_picks(pins?), do: BattlePlans.skill_picks() ++ ["first_with"] ++ if(pins?, do: ["all"], else: [])

  def numbered_pick?(%{"pick" => pick}), do: pick in ~w(exact up_to first_with)

  def playbook_color(data, id, alpha) do
    index = Enum.find_index(data["playbooks"], &(&1["id"] == id)) || 0
    "background-color: hsl(#{rem(index * 67 + 200, 360)} 65% 50% / #{alpha});"
  end

  def playbook_tag(nil), do: "?"

  def playbook_tag(%{"name" => name}) do
    words = String.split(name, ~r/[^A-Za-z0-9]+/, trim: true)

    case words do
      [single] -> single |> String.slice(0, 2) |> String.upcase()
      many -> many |> Enum.take(3) |> Enum.map_join(&String.first/1) |> String.upcase()
    end
  end

  def change_point?(entries, floor), do: Enum.any?(entries, &(&1["from_floor"] == floor))

  def hidden_change_points?(entries), do: Enum.any?(entries, &(&1["from_floor"] > @collapsed_floors + 1))

  def run_tooltip(data, entries, floor) do
    id = Resolver.playbook_id_at(entries, floor)
    start = entries |> Enum.filter(&(&1["from_floor"] <= floor)) |> Enum.map(& &1["from_floor"]) |> Enum.max(fn -> 1 end)
    "Floor #{floor}: #{find_playbook(data, id)["name"]} (from F#{start})"
  end

  def phase_range(phases, phase) do
    next = phases |> Enum.map(& &1["from_turn"]) |> Enum.filter(&(&1 > phase["from_turn"])) |> Enum.min(fn -> nil end)

    cond do
      is_nil(next) -> "Turns #{phase["from_turn"]}+"
      next - 1 == phase["from_turn"] -> "Turn #{phase["from_turn"]}"
      true -> "Turns #{phase["from_turn"]}-#{next - 1}"
    end
  end

  def ruler_turns(playbook) do
    last = playbook["phases"] |> Enum.map(& &1["from_turn"]) |> Enum.max()
    Enum.to_list(1..max(10, last + 2))
  end

  def available_actions(playbook, actions) do
    has_terminal? = Enum.any?(actions, &BattlePlans.terminal?/1)
    Enum.reject(BattlePlans.action_types(playbook["kind"]), &(has_terminal? and BattlePlans.chain_action?(&1)))
  end

  def branch_available_actions(kind, phase_actions, block, branch) do
    blocked? = not BattlePlans.chain_allowed_in?(phase_actions, block["id"], branch)
    Enum.reject(BattlePlans.action_types(kind), &(blocked? and BattlePlans.chain_action?(&1)))
  end

  def ends_with_chain?(actions), do: actions != [] and BattlePlans.terminal?(List.last(actions))

  def branch_label("then"), do: "then"
  def branch_label("else"), do: "else"

  attr :action, :map, required: true
  attr :index, :integer, required: true
  attr :turn, :integer, required: true
  attr :profiles, :list, required: true
  attr :kind, :string, required: true
  attr :phase_actions, :list, required: true

  def action_row(%{action: %{"type" => "if"}} = assigns) do
    ~H"""
    <div class="flex items-start gap-2 bg-base-200 rounded p-1.5 text-xs">
      <span class="text-base-content/50 w-4 pt-1"><%= @index %>.</span>
      <div class="flex flex-col gap-1 flex-1 min-w-0">
        <div class="flex items-center gap-2">
          <span class="font-semibold cursor-help" title={action_tooltip("if")}><%= action_label("if") %></span>
          <span class="text-[11px] text-secondary truncate"><%= BattlePlans.condition_label(@action["condition"], Map.new(@profiles, &{&1.id, &1.name})) %></span>
        </div>
        <%= if @action["condition"] do %>
          <.condition_node node={@action["condition"]} path="" values={%{"turn" => @turn, "action" => @action["id"]}} leaf={&hook_leaf(Map.put(&1, :profiles, @profiles))} />
        <% else %>
          <button type="button" phx-click="cond_add" phx-value-turn={@turn} phx-value-action={@action["id"]} phx-value-path="" phx-value-node="leaf"
                  class="btn btn-2xs btn-ghost self-start">+ Add condition</button>
        <% end %>
        <%= for branch <- BattlePlans.branches() do %>
          <div class="flex flex-col gap-1 pl-3 border-l-2 border-base-300">
            <span class="text-[11px] font-medium text-base-content/70"><%= branch_label(branch) %></span>
            <%= for {child, child_index} <- Enum.with_index(@action[branch], 1) do %>
              <.action_row action={child} index={child_index} turn={@turn} profiles={@profiles} kind={@kind} phase_actions={@phase_actions} />
            <% end %>
            <form id={"add-#{@action["id"]}-#{branch}-#{length(@action[branch])}"} phx-change="add_action" class="flex items-center gap-2">
              <input type="hidden" name="turn" value={@turn} />
              <input type="hidden" name="parent" value={@action["id"]} />
              <input type="hidden" name="branch" value={branch} />
              <select name="type" class="select select-bordered select-xs">
                <option value="" selected>+ action</option>
                <%= for type <- branch_available_actions(@kind, @phase_actions, @action, branch) do %>
                  <option value={type}><%= action_label(type) %></option>
                <% end %>
              </select>
            </form>
          </div>
        <% end %>
      </div>
      <div class="flex gap-0.5">
        <button phx-click="move_action" phx-value-turn={@turn} phx-value-action={@action["id"]} phx-value-dir="up" class="btn btn-2xs btn-ghost">↑</button>
        <button phx-click="move_action" phx-value-turn={@turn} phx-value-action={@action["id"]} phx-value-dir="down" class="btn btn-2xs btn-ghost">↓</button>
        <button phx-click="remove_action" phx-value-turn={@turn} phx-value-action={@action["id"]} class="btn btn-2xs btn-ghost text-error">✕</button>
      </div>
    </div>
    """
  end

  def action_row(assigns) do
    ~H"""
    <div class="flex items-start gap-2 bg-base-200 rounded p-1.5 text-xs">
      <span class="text-base-content/50 w-4 pt-1"><%= @index %>.</span>
      <form phx-change="update_action" class="flex flex-col gap-1 flex-1">
        <input type="hidden" name="turn" value={@turn} />
        <input type="hidden" name="action" value={@action["id"]} />
        <div class="flex items-center gap-2 flex-wrap">
          <span class="font-semibold w-32 cursor-help" title={action_tooltip(@action["type"])}><%= action_label(@action["type"]) %></span>

          <%= if @action["type"] in ~w(dodge ego target) do %>
            <.sinner_picker holder={@action} prefix="" profiles={@profiles} turn={@turn} action_id={@action["id"]} />
            <span class="text-base-content/60">skill</span>
            <select name="pick" class="select select-bordered select-xs">
              <%= for pick <- skill_picks(false) do %>
                <option value={pick} selected={@action["skill"]["pick"] == pick}><%= pick_label(pick) %></option>
              <% end %>
            </select>
            <%= if numbered_pick?(@action["skill"]) do %>
              <input type="number" name="n" min="1" value={@action["skill"]["n"]} class="input input-bordered input-xs w-14" phx-debounce="300" />
            <% end %>
            <.match_picker :if={@action["skill"]["pick"] == "first_with"} name="match" value={@action["skill"]["match"]} />
          <% end %>

          <%= if @action["type"] == "target" do %>
            <span class="text-base-content/60">row</span>
            <.row_picker holder={@action} prefix="" />
            <span class="text-base-content/60">enemy</span>
            <select name="enemy_pick" class="select select-bordered select-xs">
              <%= for pick <- BattlePlans.enemy_picks() do %>
                <option value={pick} selected={@action["enemy"]["pick"] == pick}><%= pick_label(pick) %></option>
              <% end %>
            </select>
            <%= cond do %>
              <% @action["enemy"]["pick"] == "percent" -> %>
                <input type="number" name="enemy_n" min="0" max="100" value={@action["enemy"]["n"]} class="input input-bordered input-xs w-16" phx-debounce="300"
                       title="0 is the leftmost enemy, 100 the rightmost, rounded to the nearest" />
                <span class="text-base-content/60">%</span>
              <% numbered_pick?(@action["enemy"]) -> %>
                <input type="number" name="enemy_n" min="1" value={@action["enemy"]["n"]} class="input input-bordered input-xs w-14" phx-debounce="300" />
              <% true -> %>
            <% end %>
            <span class="text-base-content/60">among</span>
            <select name="enemy_height_dir" class="select select-bordered select-xs" title="Narrow the enemies by how high their icon is on screen before picking">
              <option value="" selected={is_nil(@action["enemy"]["height"])}>all</option>
              <option value="high" selected={@action["enemy"]["height"]["dir"] == "high"}>highest</option>
              <option value="low" selected={@action["enemy"]["height"]["dir"] == "low"}>lowest</option>
            </select>
            <%= if @action["enemy"]["height"] do %>
              <input type="number" name="enemy_height_pct" min="1" max="100" value={@action["enemy"]["height"]["pct"]} class="input input-bordered input-xs w-16" phx-debounce="300"
                     title="Share of detected enemies to keep, rounded up, at least one" />
              <span class="text-base-content/60">% by height</span>
            <% end %>
          <% end %>

          <%= if @action["type"] == "ego" do %>
            <select name="grade" class="select select-bordered select-xs">
              <%= for grade <- BattlePlans.grades() do %>
                <option value={grade} selected={@action["grade"] == grade}><%= String.upcase(grade) %></option>
              <% end %>
            </select>
            <label class="flex items-center gap-1 cursor-pointer">
              <input type="hidden" name="corrode" value="false" />
              <input type="checkbox" name="corrode" value="true" checked={@action["corrode"]} class="checkbox checkbox-xs" />
              corrode
            </label>
          <% end %>
        </div>

        <%= if Map.has_key?(@action, "pins") do %>
          <div id={"pins-#{@turn}-#{@action["id"]}"} phx-hook="SortableList" data-sort-event="reorder_pins"
               data-sort-scope={"#{@turn}|#{@action["id"]}"} class="flex flex-col gap-1"
               title="When pins cover the same slot, the first pin wins. Drag ⠿ to reorder.">
          <%= for {pin, pin_index} <- Enum.with_index(@action["pins"]) do %>
            <div data-sort-id={pin_index} class="flex items-center gap-2 pl-4">
              <span data-sort-handle class="cursor-grab text-base-content/40 select-none">⠿</span>
              <span class="text-base-content/60">pin</span>
              <.sinner_picker holder={pin} prefix={"pins[#{pin_index}]"} profiles={@profiles} turn={@turn} action_id={@action["id"]} pin={pin_index} />
              <span class="text-base-content/60">skill</span>
              <select name={"pins[#{pin_index}][pick]"} class="select select-bordered select-xs">
                <%= for pick <- skill_picks(true) do %>
                  <option value={pick} selected={pin["skill"]["pick"] == pick}><%= pick_label(pick) %></option>
                <% end %>
              </select>
              <%= if numbered_pick?(pin["skill"]) do %>
                <input type="number" name={"pins[#{pin_index}][n]"} min="1" value={pin["skill"]["n"]} class="input input-bordered input-xs w-14" phx-debounce="300" />
              <% end %>
              <.match_picker :if={pin["skill"]["pick"] == "first_with"} name={"pins[#{pin_index}][match]"} value={pin["skill"]["match"]} />
              <span class="text-base-content/60">row</span>
              <.row_picker holder={pin} prefix={"pins[#{pin_index}]"} keep?={true} />
              <button type="button" phx-click="remove_pin" phx-value-turn={@turn} phx-value-action={@action["id"]} phx-value-index={pin_index}
                      class="btn btn-2xs btn-ghost text-error">✕</button>
            </div>
          <% end %>
          </div>
          <span :if={length(@action["pins"]) > 1} class="text-[11px] text-base-content/50 pl-4">When pins cover the same slot, the first pin wins.</span>
          <button type="button" phx-click="add_pin" phx-value-turn={@turn} phx-value-action={@action["id"]}
                  class="btn btn-2xs btn-ghost self-start ml-4">+ pin</button>
        <% end %>
      </form>
      <div class="flex gap-0.5">
        <button phx-click="move_action" phx-value-turn={@turn} phx-value-action={@action["id"]} phx-value-dir="up" class="btn btn-2xs btn-ghost">↑</button>
        <button phx-click="move_action" phx-value-turn={@turn} phx-value-action={@action["id"]} phx-value-dir="down" class="btn btn-2xs btn-ghost">↓</button>
        <button phx-click="remove_action" phx-value-turn={@turn} phx-value-action={@action["id"]} class="btn btn-2xs btn-ghost text-error">✕</button>
      </div>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :value, :string, default: nil

  def match_picker(assigns) do
    ~H"""
    <select name={@name} class="select select-bordered select-xs">
      <%= for {group, values} <- [{"skill", BattlePlans.tiers()}, {"sin", BattlePlans.sins()}] do %>
        <optgroup label={group}>
          <option :for={value <- values} value={value} selected={@value == value}><%= value %></option>
        </optgroup>
      <% end %>
    </select>
    """
  end

  attr :holder, :map, required: true
  attr :prefix, :string, required: true
  attr :profiles, :list, required: true
  attr :turn, :integer, required: true
  attr :action_id, :string, required: true
  attr :pin, :integer, default: nil

  def sinner_picker(assigns) do
    names = Map.new(assigns.profiles, &{&1.id, &1.name})
    chosen = assigns.holder["profile_ids"] || []
    assigns = assign(assigns, names: names, chosen: chosen, addable: Enum.reject(assigns.profiles, &(&1.id in chosen)))

    ~H"""
    <select name={field_name(@prefix, "who")} class="select select-bordered select-xs">
      <%= for {who, label} <- [{"only", "sinners"}, {"except", "all but"}, {"after", "all after"}, {"before", "all before"}, {"everyone", "everyone"}] do %>
        <option value={who} selected={@holder["who"] == who}><%= label %></option>
      <% end %>
    </select>
    <%= if @holder["who"] != "everyone" do %>
      <%= for id <- @chosen do %>
        <input type="hidden" name={field_name(@prefix, "profile_ids") <> "[]"} value={id} />
        <span class="badge badge-sm gap-1">
          <%= Map.get(@names, id, "profile #{id}") %>
          <button type="button" phx-click="remove_sinner" phx-value-turn={@turn} phx-value-action={@action_id} phx-value-pin={@pin} phx-value-profile={id}
                  class="text-error">✕</button>
        </span>
      <% end %>
      <select :if={@addable != []} name={field_name(@prefix, "add_profile")} class="select select-bordered select-xs">
        <option value="" selected>+ sinner</option>
        <option :for={p <- @addable} value={p.id}><%= p.name %></option>
      </select>
    <% end %>
    """
  end

  attr :holder, :map, required: true
  attr :prefix, :string, required: true
  attr :keep?, :boolean, default: false

  def row_picker(assigns) do
    priority = assigns.holder["priority"]
    assigns = assign(assigns, priority: priority, order: priority && priority["order"], values: BattlePlans.priority_values())

    ~H"""
    <select name={field_name(@prefix, "row")} class="select select-bordered select-xs">
      <%= for row <- BattlePlans.rows() do %>
        <option value={row} selected={@holder["row"] == row}><%= row %></option>
      <% end %>
    </select>
    <%= if @holder["row"] == "priority" do %>
      <%= for {chosen, rank} <- Enum.with_index(@order ++ [nil]), rank < length(@values) do %>
        <span :if={rank > 0} class="text-base-content/40">&gt;</span>
        <select name={field_name(@prefix, "priority_order") <> "[]"} class="select select-bordered select-xs">
          <option value="" selected={is_nil(chosen)}>(else bottom)</option>
          <%= for {group, values} <- priority_options(@order, chosen) do %>
            <optgroup label={group}>
              <option :for={value <- values} value={value} selected={value == chosen}><%= value %></option>
            </optgroup>
          <% end %>
        </select>
      <% end %>
      <%= if @keep? do %>
        <span class="text-base-content/60 cursor-help" title="Rank every slot of this pin by the priority list, then keep the best ones in play and dodge the rest. At least pulls slots back from dodge; at most dodges the lowest ranked. Blank means no limit.">keep</span>
        <input type="number" name={field_name(@prefix, "keep_min")} min="0" value={@priority["min"]} placeholder="min"
               phx-debounce="300" class="input input-bordered input-xs w-14" />
        <span class="text-base-content/40">to</span>
        <input type="number" name={field_name(@prefix, "keep_max")} min="0" value={@priority["max"]} placeholder="max"
               phx-debounce="300" class="input input-bordered input-xs w-14" />
      <% end %>
    <% end %>
    """
  end

  defp priority_options(order, chosen) do
    [{"skill", BattlePlans.tiers()}, {"sin", BattlePlans.sins()}, {"other", ["dodge"]}]
    |> Enum.map(fn {group, values} -> {group, Enum.filter(values, &(&1 == chosen or &1 not in order))} end)
    |> Enum.reject(fn {_group, values} -> values == [] end)
  end

  defp field_name("", field), do: field
  defp field_name(prefix, field), do: "#{prefix}[#{field}]"

  def hook_leaf(assigns) do
    ~H"""
    <select name="op" class="select select-bordered select-xs">
      <option value="hook_on" selected={@node["op"] == "hook_on"}>hook on</option>
      <option value="hook_off" selected={@node["op"] == "hook_off"}>hook off</option>
      <option value="sinners_eq" selected={@node["op"] == "sinners_eq"}>sinners =</option>
      <option value="sinners_gte" selected={@node["op"] == "sinners_gte"}>sinners at least</option>
      <option value="sinners_lte" selected={@node["op"] == "sinners_lte"}>sinners at most</option>
      <option value="tray_count" selected={@node["op"] == "tray_count"}>tray slots</option>
      <option value="sinner_position" selected={@node["op"] == "sinner_position"}>sinner position</option>
      <option value="boss_fight" selected={@node["op"] == "boss_fight"}>boss fight</option>
      <option value="not_boss_fight" selected={@node["op"] == "not_boss_fight"}>not boss fight</option>
    </select>
    <%= cond do %>
    <% BattlePlans.sinner_leaf?(@node) -> %>
      <input type="number" name="value" min="1" value={@node["value"]} phx-debounce="300" class="input input-bordered input-xs w-16" />
    <% BattlePlans.tray_leaf?(@node) -> %>
      <select name="profile_id" class="select select-bordered select-xs" title="Only count this sinner's slots">
        <option value="" selected={is_nil(@node["profile_id"])}>(anyone)</option>
        <%= for p <- @profiles do %>
          <option value={p.id} selected={@node["profile_id"] == p.id}><%= p.name %></option>
        <% end %>
      </select>
      <select name="match" class="select select-bordered select-xs">
        <%= for {group, values} <- [{"skill", BattlePlans.tiers()}, {"sin", BattlePlans.sins()}] do %>
          <optgroup label={group}>
            <option :for={value <- values} value={value} selected={@node["match"] == value}><%= value %></option>
          </optgroup>
        <% end %>
      </select>
      <select name="cmp" class="select select-bordered select-xs">
        <option value="gte" selected={@node["cmp"] == "gte"}>at least</option>
        <option value="eq" selected={@node["cmp"] == "eq"}>exactly</option>
        <option value="lte" selected={@node["cmp"] == "lte"}>at most</option>
      </select>
      <input type="number" name="value" min="0" value={@node["value"]} phx-debounce="300" class="input input-bordered input-xs w-16" />
    <% BattlePlans.fight_leaf?(@node) -> %>
    <% BattlePlans.position_leaf?(@node) -> %>
      <select name="profile_id" class="select select-bordered select-xs">
        <option value="" selected={is_nil(@node["profile_id"])}>(pick sinner)</option>
        <%= for p <- @profiles do %>
          <option value={p.id} selected={@node["profile_id"] == p.id}><%= p.name %></option>
        <% end %>
      </select>
      <select name="cmp" class="select select-bordered select-xs">
        <option value="is" selected={@node["cmp"] == "is"}>is</option>
        <option value="is_not" selected={@node["cmp"] == "is_not"}>is not</option>
        <option value="gt" selected={@node["cmp"] == "gt"} title="Further right in the skill tray">greater than</option>
        <option value="lt" selected={@node["cmp"] == "lt"} title="Further left in the skill tray">less than</option>
      </select>
      <select name="pos" class="select select-bordered select-xs">
        <option value="first" selected={@node["pos"] == "first"}>first</option>
        <option value="last" selected={@node["pos"] == "last"}>last</option>
        <option value="exact" selected={@node["pos"] == "exact"}>at position</option>
      </select>
      <input :if={@node["pos"] == "exact"} type="number" name="value" min="1" value={@node["value"]} phx-debounce="300"
             class="input input-bordered input-xs w-16" title="1 is the leftmost sinner in the skill tray" />
    <% true -> %>
      <input type="text" name="hook" value={@node["hook"]} list="hook-names" phx-debounce="blur"
             placeholder="hook name" class="input input-bordered input-xs flex-1 min-w-0 font-mono" />
    <% end %>
    """
  end

  def find_playbook(data, id), do: Enum.find(data["playbooks"], &(&1["id"] == id))


  defp reset_editor(socket) do
    socket
    |> assign(:editing_id, nil)
    |> assign(:name, "")
    |> assign(:data, nil)
    |> assign(:playbook_id, nil)
    |> assign(:lineup_id, nil)
    |> assign(:lineup_erase?, false)
    |> assign(:renaming_lineup_id, nil)
    |> assign(:paint, nil)
    |> assign(:extreme?, false)
  end

  defp load_plan(socket, id) do
    case Plans.get(:battle_plans, id) do
      %{data: %{"version" => 3} = data} = plan ->
        first_playbook = List.first(data["playbooks"])

        socket
        |> assign(:editing_id, plan.id)
        |> assign(:name, plan.name)
        |> assign(:data, data)
        |> assign(:playbook_id, first_playbook["id"])
        |> assign(:lineup_id, get_in(List.first(BattlePlans.lineups(data)), ["id"]))
        |> assign(:lineup_erase?, false)
        |> assign(:paint, first_playbook["id"])
        |> assign(:extreme?, Enum.any?(Map.values(data["tracks"]) ++ Map.values(data["lineup_tracks"] || %{}), &hidden_change_points?/1))

      nil ->
        put_flash(socket, :error, "Plan not found.")

      _ ->
        put_flash(socket, :error, "Plan data is not version 3. Run mix db.migrate.")
    end
  end

  defp persist(socket) do
    attrs = %{id: socket.assigns.editing_id, name: socket.assigns.name, data: socket.assigns.data}

    case Plans.save(:battle_plans, attrs) do
      {:ok, _id} -> assign(socket, :plans, Plans.list(:battle_plans))
      {:error, reason} -> put_flash(socket, :error, "Save failed: #{inspect(reason)}")
    end
  end

  defp assign_profiles(socket), do: assign(socket, :profiles, SinnerProfiles.list())

  defp put_track(socket, track, entries) do
    socket |> assign(:data, put_in(socket.assigns.data, ["tracks", track], entries)) |> persist()
  end

  defp put_lineup_track(socket, venue, entries) do
    tracks = Map.put(socket.assigns.data["lineup_tracks"] || %{}, venue, entries)
    socket |> assign(:data, Map.put(socket.assigns.data, "lineup_tracks", tracks)) |> persist()
  end

  defp update_lineup(socket, fun) do
    id = socket.assigns.lineup_id
    lineups = Enum.map(BattlePlans.lineups(socket.assigns.data), fn lineup -> if lineup["id"] == id, do: fun.(lineup), else: lineup end)
    socket |> assign(:data, Map.put(socket.assigns.data, "lineups", lineups)) |> persist()
  end

  defp add_playbook(socket, playbook) do
    socket
    |> assign(:data, Map.update!(socket.assigns.data, "playbooks", &(&1 ++ [playbook])))
    |> assign(:playbook_id, playbook["id"])
    |> assign(:paint, playbook["id"])
    |> persist()
  end

  defp copy_playbook(source) do
    phases =
      Enum.map(source["phases"], fn phase ->
        Map.update!(phase, "actions", fn actions -> Enum.map(actions, &BattlePlans.refresh_ids/1) end)
      end)

    %{source | "id" => StarlightBot.GiftPlans.new_id("pb"), "name" => source["name"] <> " copy", "phases" => phases}
  end

  defp update_playbook(socket, fun) do
    id = socket.assigns.playbook_id
    playbooks = Enum.map(socket.assigns.data["playbooks"], fn pb -> if pb["id"] == id, do: fun.(pb), else: pb end)
    socket |> assign(:data, Map.put(socket.assigns.data, "playbooks", playbooks)) |> persist()
  end

  defp update_phase(socket, turn, fun) do
    update_playbook(socket, fn playbook ->
      Map.update!(playbook, "phases", fn phases ->
        Enum.map(phases, fn phase ->
          if phase["from_turn"] == turn, do: Map.update!(phase, "actions", &BattlePlans.chain_last(fun.(&1))), else: phase
        end)
      end)
    end)
  end

  defp update_action(socket, turn, action_id, fun) do
    update_phase(socket, turn, fn actions ->
      update_list_containing(actions, action_id, fn list -> Enum.map(list, &if(&1["id"] == action_id, do: fun.(&1), else: &1)) end)
    end)
  end

  defp update_list_containing(actions, id, fun) do
    if Enum.any?(actions, &(&1["id"] == id)) do
      fun.(actions)
    else
      Enum.map(actions, fn
        %{"type" => "if"} = block ->
          Enum.reduce(BattlePlans.branches(), block, fn branch, acc -> Map.update!(acc, branch, &update_list_containing(&1, id, fun)) end)

        action ->
          action
      end)
    end
  end

  defp update_condition(socket, turn, action_id, fun) do
    update_action(socket, String.to_integer(turn), action_id, fn action ->
      Map.put(action, "condition", action["condition"] |> fun.() |> Conditions.prune())
    end)
  end

  defp apply_action_params(%{"type" => "target"} = action, params) do
    action
    |> put_sinners(params)
    |> Map.put("skill", parse_skill(params["pick"], params["n"], params["match"]))
    |> BattlePlans.put_row(params["row"], params["priority_order"])
    |> Map.put("enemy", params["enemy_pick"] |> parse_skill(params["enemy_n"]) |> put_height(params["enemy_height_dir"], params["enemy_height_pct"]))
  end

  defp apply_action_params(%{"type" => type} = action, params) when type in ~w(dodge ego) do
    action
    |> put_sinners(params)
    |> Map.put("skill", parse_skill(params["pick"], params["n"], params["match"]))
    |> then(fn action ->
      if type == "ego" do
        action
        |> Map.put("grade", if(params["grade"] in BattlePlans.grades(), do: params["grade"], else: "zayin"))
        |> Map.put("corrode", params["corrode"] == "true")
      else
        action
      end
    end)
  end

  defp apply_action_params(%{"pins" => _} = action, params) do
    pins =
      (params["pins"] || %{})
      |> Enum.sort_by(fn {index, _} -> String.to_integer(index) end)
      |> Enum.zip(action["pins"])
      |> Enum.map(fn {{_index, params}, pin} ->
        pin
        |> put_sinners(params)
        |> Map.put("skill", parse_skill(params["pick"], params["n"], params["match"]))
        |> BattlePlans.put_row(params["row"], params["priority_order"])
        |> BattlePlans.put_keep(params["keep_min"], params["keep_max"])
      end)

    Map.put(action, "pins", pins)
  end

  defp apply_action_params(action, _params), do: action

  defp put_sinners(holder, %{"who" => "everyone"}), do: Map.put(holder, "who", "everyone")

  defp put_sinners(holder, params) do
    kept = if holder["who"] == "everyone", do: holder["profile_ids"] || [], else: Enum.map(params["profile_ids"] || [], &parse_id/1)

    ids =
      (kept ++ [parse_id(params["add_profile"])])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    holder
    |> Map.put("who", if(params["who"] in ["except", "after", "before"], do: params["who"], else: "only"))
    |> Map.put("profile_ids", ids)
  end

  defp parse_skill("first_with", n, match) do
    %{
      "pick" => "first_with",
      "n" => max(parse_id(n) || 1, 1),
      "match" => if(match in BattlePlans.tiers() ++ BattlePlans.sins(), do: match, else: "wrath")
    }
  end

  defp parse_skill(pick, n, _match), do: parse_skill(pick, n)

  defp parse_skill("percent", n), do: %{"pick" => "percent", "n" => (parse_id(n) || 50) |> max(0) |> min(100)}
  defp parse_skill(pick, n) when pick in ~w(exact up_to), do: %{"pick" => pick, "n" => max(parse_id(n) || 1, 1)}
  defp parse_skill(pick, _n) when pick in ~w(first last all), do: %{"pick" => pick}
  defp parse_skill(_pick, _n), do: %{"pick" => "first"}

  defp put_height(enemy, dir, pct) when dir in ["high", "low"],
    do: Map.put(enemy, "height", %{"dir" => dir, "pct" => (parse_id(pct) || 30) |> max(1) |> min(100)})

  defp put_height(enemy, _dir, _pct), do: enemy

  defp parse_id(nil), do: nil
  defp parse_id(""), do: nil

  defp parse_id(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end
end
