defmodule StarlightBotWeb.Live.BattlePlanEditorLive do
  use StarlightBotWeb, :live_view
  import StarlightBotWeb.Components.ConditionTree
  import StarlightBotWeb.Components.PlanPicker
  import StarlightBotWeb.Components.PlanTemplates

  alias StarlightBot.{PlanClipboard, PlanCounts, BattlePlans, Conditions, Hooks, Plans, SinnerProfiles, Teams}
  alias StarlightBot.BattlePlans.Resolver

  @collapsed_floors 5
  @read_only_events ~w(restore_view select_playbook select_lineup set_paint select_schedule_tab open_editor close_editor copy_playbook toggle_extreme toggle_help copy_plan clipboard_status plan_clipboard_failed)

  def read_only_events, do: @read_only_events

  @sinner_rows [~w(yi_sang faust don_quixote ryoshu meursault hong_lu), ~w(heathcliff ishmael rodion sinclair outis gregor)]

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: PlanCounts.subscribe()

    team = session["team_id"] && Teams.get_team(session["team_id"])

    socket =
      socket
      |> assign(:team_id, team && team.id)
      |> assign(:paste_status, :unknown)
      |> assign(:show_help, false)
      |> assign(:template_id, nil)
      |> read_only_guard(@read_only_events)
      |> assign_templates(:battle_plans)
      |> assign(:tab_counts, PlanCounts.for_team(team && team.id))
      |> assign(:hook_names, Enum.map(Hooks.list_hooks(), & &1.name))
      |> assign_profiles()
      |> reset_editor()

    {:ok, if(team && team.battle_plan_id, do: load_plan(socket, team.battle_plan_id, team.battle_template_id), else: socket)}
  end

  @impl true
  def handle_info({:plan_count, team_id, table, count}, %{assigns: %{team_id: team_id}} = socket), do: {:noreply, update(socket, :tab_counts, &Map.put(&1, table, count))}

  @impl true
  def handle_info({:plan_count, _team_id, _table, _count}, socket), do: {:noreply, socket}

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("new_plan", _, socket) do
    attrs = %{name: Plans.new_name(:battle_plans, socket.assigns.team_id), data: BattlePlans.blank(), team_id: socket.assigns.team_id}

    case Plans.save(:battle_plans, attrs) do
      {:ok, id} -> {:noreply, socket |> load_plan(id) |> link_team(:battle_plan_id)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("copy_plan", _, socket), do: {:noreply, copy_plan(socket, :battle_plans)}

  @impl true
  def handle_event("paste_plan", %{"text" => text}, socket), do: {:noreply, paste_plan(socket, :battle_plans, :battle_plan_id, text, &load_plan/2)}

  @impl true
  def handle_event("plan_clipboard_failed", %{"message" => message}, socket), do: {:noreply, put_flash(socket, :error, message)}

  @impl true
  def handle_event("template_" <> action, params, socket), do: {:noreply, template_event(socket, action, params, :battle_plans, :battle_plan_id, &load_plan/3)}

  @impl true
  def handle_event("clipboard_status", %{"text" => text}, socket), do: {:noreply, paste_status(socket, :battle_plans, text)}

  @impl true
  def handle_event("set_max_retries", %{"max_retries" => value}, socket) do
    case Integer.parse(value) do
      {n, _} when n >= 0 -> {:noreply, update_playbook(socket, &Map.put(&1, "max_retries", n))}
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_help", _, socket), do: {:noreply, update(socket, :show_help, &(!&1))}

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
  def handle_event("erase_cell", %{"track" => track, "floor" => floor}, socket) do
    entries = socket.assigns.data["tracks"][track]
    {:noreply, put_track(socket, track, BattlePlans.erase(entries, String.to_integer(floor)))}
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
  def handle_event("restore_view", params, %{assigns: %{data: data}} = socket) when is_map(data) do
    playbook_id = if find_playbook(data, params["playbook"]), do: params["playbook"], else: socket.assigns.playbook_id
    lineup_id = if BattlePlans.find_lineup(data, params["lineup"]), do: params["lineup"], else: socket.assigns.lineup_id
    paint = if params["paint"] == "erase", do: "erase", else: playbook_id

    {:noreply, socket |> assign(:playbook_id, playbook_id) |> assign(:lineup_id, lineup_id) |> assign(:paint, paint)}
  end

  @impl true
  def handle_event("restore_view", _params, socket), do: {:noreply, socket}

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
     |> assign(:renaming_lineup_id, lineup["id"])
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
  def handle_event("copy_lineup", %{"id" => id}, socket) do
    case BattlePlans.find_lineup(socket.assigns.data, id) do
      nil -> {:noreply, socket}
      lineup -> {:noreply, socket |> push_event("copy_json", %{text: PlanClipboard.encode_lineup(lineup)}) |> put_flash(:info, "Lineup '#{lineup["name"]}' copied to the clipboard.")}
    end
  end

  @impl true
  def handle_event("paste_lineup", %{"text" => text}, socket) do
    case PlanClipboard.decode_lineup(text) do
      {:ok, source} ->
        {data, lineup} = BattlePlans.import_lineup(socket.assigns.data, source)
        {:noreply, socket |> assign(:data, data) |> assign(:lineup_id, lineup["id"]) |> assign(:lineup_erase?, false) |> persist() |> put_flash(:info, "Pasted lineup '#{lineup["name"]}'.")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_event("reorder_lineups", %{"ids" => ids}, socket) do
    socket = assign(socket, :data, Map.put(socket.assigns.data, "lineups", BattlePlans.reorder_lineups(BattlePlans.lineups(socket.assigns.data), ids)))
    {:noreply, socket |> persist() |> update(:reorder_rev, &(&1 + 1))}
  end

  @impl true
  def handle_event("toggle_lineup_sinner", %{"sinner" => sinner}, socket) when is_binary(sinner) do
    {:noreply,
     update_lineup(socket, fn lineup ->
       Map.update!(lineup, "sinners", fn sinners -> if sinner in sinners, do: List.delete(sinners, sinner), else: sinners ++ [sinner] end)
     end)}
  end

  @impl true
  def handle_event("set_sinner_profile", %{"sinner" => sinner} = params, socket) do
    if sinner in SinnerProfiles.sinners() do
      data = BattlePlans.put_profile(socket.assigns.data, sinner, parse_ids(params["profile_ids"]))
      {:noreply, socket |> assign(:data, data) |> persist()}
    else
      {:noreply, socket}
    end
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
  def handle_event("copy_playbook", %{"id" => id}, socket) do
    case find_playbook(socket.assigns.data, id) do
      nil -> {:noreply, socket}
      playbook -> {:noreply, socket |> push_event("copy_json", %{text: PlanClipboard.encode_playbook(playbook)}) |> put_flash(:info, "Playbook '#{playbook["name"]}' copied to the clipboard.")}
    end
  end

  @impl true
  def handle_event("paste_playbook", %{"text" => text, "kind" => kind}, socket) when kind in ~w(chain focused) do
    case PlanClipboard.decode_playbook(text, kind) do
      {:ok, source} ->
        {data, playbook} = BattlePlans.import_playbook(socket.assigns.data, source)
        socket = socket |> assign(:data, data) |> assign(:playbook_id, playbook["id"]) |> assign(:paint, playbook["id"]) |> persist() |> put_flash(:info, "Pasted playbook '#{playbook["name"]}'.")
        {:noreply, warn_unknown_hooks(socket, playbook)}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
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
  def handle_event("start_rename_playbook", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:playbook_id, id) |> assign(:paint, id) |> assign(:renaming_playbook_id, id)}
  end

  @impl true
  def handle_event("cancel_rename_playbook", _, socket) do
    {:noreply, assign(socket, :renaming_playbook_id, nil)}
  end

  @impl true
  def handle_event("rename_playbook", %{"value" => name}, socket) do
    socket = socket |> assign(:playbook_id, socket.assigns.renaming_playbook_id || socket.assigns.playbook_id) |> assign(:renaming_playbook_id, nil)

    case String.trim(name) do
      "" -> {:noreply, socket}
      name -> {:noreply, update_playbook(socket, &Map.put(&1, "name", name))}
    end
  end

  @impl true
  def handle_event("add_schedule", %{"action" => action_id}, socket) do
    {:noreply, update_items(socket, &BattlePlans.wrap_in_schedule(&1, action_id))}
  end

  @impl true
  def handle_event("select_schedule_tab", %{"schedule" => schedule_id, "from" => from}, socket) do
    {:noreply, put_schedule_tab(socket, schedule_id, String.to_integer(from))}
  end

  @impl true
  def handle_event("split_schedule", %{"schedule" => schedule_id, "turn" => turn}, socket) when turn != "" do
    turn = String.to_integer(turn)
    socket = update_items(socket, &BattlePlans.update_schedule(&1, schedule_id, fn schedule -> BattlePlans.split_segment(schedule, turn) end))
    {:noreply, put_schedule_tab(socket, schedule_id, turn)}
  end

  @impl true
  def handle_event("split_schedule", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("move_schedule_segment", %{"schedule" => schedule_id, "from" => from, "to" => to}, socket) do
    to = String.to_integer(to)
    socket = update_items(socket, &BattlePlans.update_schedule(&1, schedule_id, fn schedule -> BattlePlans.move_segment(schedule, String.to_integer(from), to) end))
    {:noreply, put_schedule_tab(socket, schedule_id, to)}
  end

  @impl true
  def handle_event("remove_schedule_segment", %{"schedule" => schedule_id, "from" => from}, socket) do
    socket = update_items(socket, &BattlePlans.update_schedule(&1, schedule_id, fn schedule -> BattlePlans.remove_segment(schedule, String.to_integer(from)) end))
    {:noreply, put_schedule_tab(socket, schedule_id, 1)}
  end

  @impl true
  def handle_event("add_intro_tab", %{"schedule" => schedule_id, "turn" => turn}, socket) do
    socket = update_items(socket, &BattlePlans.update_schedule(&1, schedule_id, fn schedule -> BattlePlans.add_intro_segment(schedule) end))
    {:noreply, put_schedule_tab(socket, schedule_id, String.to_integer(turn))}
  end

  @impl true
  def handle_event("set_schedule_loop", %{"schedule" => schedule_id, "turn" => turn}, socket) do
    turn = if turn == "", do: nil, else: String.to_integer(turn)
    socket = update_items(socket, &BattlePlans.update_schedule(&1, schedule_id, fn schedule -> BattlePlans.set_loop(schedule, turn) end))
    {:noreply, put_schedule_tab(socket, schedule_id, turn || 1)}
  end

  @impl true
  def handle_event("remove_schedule", %{"schedule" => schedule_id}, socket) do
    {:noreply, update_items(socket, &BattlePlans.unwrap_schedule(&1, schedule_id))}
  end

  @impl true
  def handle_event("reorder_playbooks", %{"scope" => kind, "ids" => ids}, socket) do
    socket = assign(socket, :data, Map.update!(socket.assigns.data, "playbooks", &BattlePlans.reorder_playbooks(&1, kind, ids)))
    {:noreply, socket |> persist() |> update(:reorder_rev, &(&1 + 1))}
  end

  @impl true
  def handle_event("reorder_actions", %{"scope" => scope, "ids" => ids}, socket) do
    {:noreply, socket |> update_items(&BattlePlans.reorder_container(&1, scope, ids)) |> update(:reorder_rev, &(&1 + 1))}
  end

  @impl true
  def handle_event("move_action_to", %{"scope" => scope, "from" => from, "id" => id, "ids" => ids}, socket) do
    {:noreply, socket |> update_items(&BattlePlans.move_to_container(&1, from, scope, id, ids)) |> update(:reorder_rev, &(&1 + 1))}
  end

  @impl true
  def handle_event("add_action", %{"type" => type, "parent" => parent, "branch" => branch}, socket)
      when type != "" and is_binary(branch) do
    kind = find_playbook(socket.assigns.data, socket.assigns.playbook_id)["kind"]

    new = type |> BattlePlans.new_action() |> BattlePlans.seed_sinner(first_profiled_sinner(socket))

    socket =
      update_items(socket, fn items ->
        BattlePlans.update_list_containing(items, parent, fn list ->
          Enum.map(list, fn
            %{"id" => ^parent} = block ->
              if type in branch_available_actions(kind, block, branch),
                do: BattlePlans.update_branch_actions(block, branch, &(&1 ++ [new])),
                else: block

            action ->
              action
          end)
        end)
      end)

    {:noreply, if(type in ~w(dodge ego target nothing), do: assign(socket, :open_editor_id, new["id"]), else: socket)}
  end

  @impl true
  def handle_event("add_action", %{"type" => type, "container" => container}, socket) when type != "" do
    playbook = find_playbook(socket.assigns.data, socket.assigns.playbook_id)
    new = type |> BattlePlans.new_action() |> BattlePlans.seed_sinner(first_profiled_sinner(socket))

    socket =
      update_items(socket, fn items ->
        if type in available_actions(playbook, BattlePlans.scope_actions(items, container)),
          do: BattlePlans.update_container(items, container, &(&1 ++ [new])),
          else: items
      end)

    {:noreply, if(type in ~w(dodge ego target nothing), do: assign(socket, :open_editor_id, new["id"]), else: socket)}
  end

  @impl true
  def handle_event("add_action", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("add_else", %{"parent" => parent}, socket) do
    {:noreply, update_items(socket, &BattlePlans.add_else(&1, parent))}
  end

  @impl true
  def handle_event("remove_else", %{"parent" => parent}, socket) do
    {:noreply, update_items(socket, &BattlePlans.remove_else(&1, parent))}
  end

  @impl true
  def handle_event("add_elif", %{"parent" => parent, "after" => after_branch}, socket) do
    {:noreply, update_items(socket, &BattlePlans.add_elif(&1, parent, after_branch))}
  end

  @impl true
  def handle_event("remove_elif", %{"elif" => elif_id}, socket) do
    {:noreply, update_items(socket, &BattlePlans.remove_elif(&1, elif_id))}
  end

  @impl true
  def handle_event("dup_action", %{"action" => action_id}, socket) do
    {:noreply, update_items(socket, &BattlePlans.duplicate_action(&1, action_id))}
  end

  @impl true
  def handle_event("remove_action", %{"action" => action_id}, socket) do
    {:noreply,
     update_items(socket, fn items ->
       BattlePlans.update_list_containing(items, action_id, fn list -> Enum.reject(list, &(&1["id"] == action_id)) end)
     end)}
  end

  @impl true
  def handle_event("cond_add", %{"action" => action_id, "path" => path, "node" => node}, socket) do
    leaf = BattlePlans.default_leaf()
    child = if node == "group", do: Conditions.group(leaf), else: leaf
    {:noreply, socket |> assign(:open_editor_id, action_id) |> update_condition(action_id, &Conditions.add(&1, path, child))}
  end

  @impl true
  def handle_event("open_editor", %{"action" => action_id}, socket) do
    {:noreply, assign(socket, :open_editor_id, action_id)}
  end

  @impl true
  def handle_event("close_editor", _params, socket) do
    {:noreply, assign(socket, :open_editor_id, nil)}
  end

  @impl true
  def handle_event("cond_remove", %{"action" => action_id, "path" => path}, socket) do
    {:noreply, update_condition(socket, action_id, &Conditions.remove(&1, path))}
  end

  @impl true
  def handle_event("cond_toggle_op", %{"action" => action_id, "path" => path}, socket) do
    {:noreply, update_condition(socket, action_id, &Conditions.toggle_op(&1, path))}
  end

  @impl true
  def handle_event("cond_update", %{"action" => action_id, "path" => path} = params, socket) do
    leaf = BattlePlans.condition_leaf(params)
    {:noreply, update_condition(socket, action_id, &Conditions.put_leaf(&1, path, leaf))}
  end

  @impl true
  def handle_event("update_action", %{"action" => action_id} = params, socket) do
    {:noreply, update_action(socket, action_id, &(&1 |> BattlePlans.convert_action(params["kind"]) |> apply_action_params(params)))}
  end

  @impl true
  def handle_event("set_chain_mode", %{"action" => action_id, "mode" => mode}, socket) when mode in ~w(fast a_res) do
    {:noreply, update_action(socket, action_id, &Map.put(&1, "mode", mode))}
  end

  @impl true
  def handle_event("add_pin", %{"action" => action_id}, socket) do
    socket = update_action(socket, action_id, &Map.update!(&1, "pins", fn pins -> if pins == [], do: [BattlePlans.seed_sinner(BattlePlans.new_pin(), first_profiled_sinner(socket))], else: pins end))
    {:noreply, assign(socket, :open_editor_id, "#{action_id}|pins[0]")}
  end

  @impl true
  def handle_event("remove_ignore", %{"action" => action_id, "path" => path, "index" => index}, socket) do
    index = String.to_integer(index)
    {:noreply, update_action(socket, action_id, &update_at_path(&1, String.split(path, ["[", "]"], trim: true), fn holder -> Map.update!(holder, "enemy", fn enemy -> BattlePlans.remove_ignore(enemy, index) end) end))}
  end

  @impl true
  def handle_event("add_slot_chip", %{"action" => action_id} = params, socket) do
    add = fn holder -> Map.update(holder, "skill", BattlePlans.first_slot(), &BattlePlans.add_skill_chip/1) end
    {:noreply, update_action(socket, action_id, at_path(params, add))}
  end

  @impl true
  def handle_event("step_slot_chip", %{"action" => action_id, "index" => index, "delta" => delta} = params, socket) do
    step = fn holder -> Map.update(holder, "skill", BattlePlans.first_slot(), &BattlePlans.step_skill_chip(&1, String.to_integer(index), String.to_integer(delta))) end
    {:noreply, update_action(socket, action_id, at_path(params, step))}
  end

  @impl true
  def handle_event("cond_add_chip", %{"action" => action_id, "path" => path}, socket) do
    {:noreply, update_condition(socket, action_id, &Conditions.update_leaf(&1, path, fn leaf -> Map.update!(leaf, "position", fn skill -> BattlePlans.add_skill_chip(skill) end) end))}
  end

  @impl true
  def handle_event("cond_step_chip", %{"action" => action_id, "path" => path, "index" => index, "delta" => delta}, socket) do
    step = fn skill -> BattlePlans.step_skill_chip(skill, String.to_integer(index), String.to_integer(delta)) end
    {:noreply, update_condition(socket, action_id, &Conditions.update_leaf(&1, path, fn leaf -> Map.update!(leaf, "position", step) end))}
  end

  @impl true
  def handle_event("add_chosen", %{"action" => action_id} = params, socket) do
    add = fn holder ->
      filter = holder["where"] || BattlePlans.new_chosen_filter(pin_path?(params))
      Map.put(holder, "where", Map.update!(filter, "conditions", &(&1 ++ [BattlePlans.new_chosen_condition(pin_path?(params))])))
    end

    {:noreply, update_action(socket, action_id, at_path(params, add))}
  end

  @impl true
  def handle_event("remove_chosen", %{"action" => action_id, "index" => index} = params, socket) do
    drop = fn holder -> Map.update!(holder, "where", fn filter -> Map.update!(filter, "conditions", &List.delete_at(&1, String.to_integer(index))) end) end
    {:noreply, update_action(socket, action_id, at_path(params, drop))}
  end

  @impl true
  def handle_event("add_rest", %{"action" => action_id} = params, socket) do
    {:noreply, update_action(socket, action_id, at_path(params, &BattlePlans.put_rest(&1, "true")))}
  end

  @impl true
  def handle_event("remove_rest", %{"action" => action_id} = params, socket) do
    {:noreply, update_action(socket, action_id, at_path(params, &BattlePlans.put_rest(&1, "false")))}
  end

  @impl true
  def handle_event("add_where", %{"action" => action_id} = params, socket) do
    {:noreply, update_action(socket, action_id, at_path(params, &Map.put(&1, "where", BattlePlans.new_chosen_filter(pin_path?(params)))))}
  end

  @impl true
  def handle_event("remove_where", %{"action" => action_id} = params, socket) do
    {:noreply, update_action(socket, action_id, at_path(params, &Map.delete(&1, "where")))}
  end

  @impl true
  def handle_event("reorder_rows", %{"scope" => scope, "ids" => ids}, socket) do
    [action_id, path] = String.split(scope, "|", parts: 2)
    order = Enum.map(ids, &String.to_integer/1)
    reorder = &update_at_path(&1, String.split(path, ["[", "]"], trim: true), fn holder -> BattlePlans.reorder_rows(holder, order) end)
    {:noreply, socket |> update_action(action_id, reorder) |> update(:reorder_rev, &(&1 + 1))}
  end

  @impl true
  def handle_event("remove_pin", %{"action" => action_id, "index" => index}, socket) do
    index = String.to_integer(index)
    {:noreply, update_action(socket, action_id, &Map.update!(&1, "pins", fn pins -> List.delete_at(pins, index) end))}
  end

  def floors(true), do: Enum.to_list(1..BattlePlans.max_floor())
  def floors(false), do: Enum.to_list(1..@collapsed_floors)

  def track_label("normal_chain"), do: "Normal Chain"
  def track_label("normal_focused"), do: "Normal Focused"
  def track_label("hard_chain"), do: "Hard Chain"
  def track_label("hard_focused"), do: "Hard Focused"
  def track_label("lux_chain"), do: "Lux Chain"
  def track_label("lux_focused"), do: "Lux Focused"

  attr :data, :map, required: true
  attr :lineup_id, :string, default: nil
  attr :renaming_lineup_id, :string, default: nil
  attr :reorder_rev, :integer, required: true

  def lineup_list(assigns) do
    ~H"""
    <div id="lineup-clipboard" phx-hook="ItemClipboard" class="flex w-0 min-w-full flex-col gap-0.5">
      <div class="flex min-h-8 items-center text-sm font-semibold text-base-content/70">
        Lineups
        <button type="button" data-paste-event="paste_lineup" title="Paste a lineup from the clipboard" class="btn btn-xs btn-ghost ml-auto">Paste</button>
        <button phx-click="new_lineup" class="btn btn-xs btn-ghost">+ lineup</button>
      </div>
      <div id={"lineups-#{@reorder_rev}"} phx-hook="SortableList" data-sort-event="reorder_lineups" class="flex flex-col gap-0.5">
        <%= for lineup <- StarlightBot.BattlePlans.lineups(@data) do %>
          <% used = StarlightBot.BattlePlans.venues_using(@data, lineup["id"]) %>
          <div id={"lineup-row-#{lineup["id"]}"} data-sort-id={lineup["id"]} phx-hook="DblClickEvent" data-event="start_rename_lineup" data-id={lineup["id"]}
               title={"Double-click to rename. Used on: " <> if(used == [], do: "nothing", else: Enum.map_join(used, ", ", &StarlightBot.BattlePlans.venue_label/1))}
               class="group flex items-center">
            <span data-sort-handle class="cursor-grab text-base-content/40 select-none px-0.5">⠿</span>
            <%= if @renaming_lineup_id == lineup["id"] do %>
              <form phx-submit="rename_lineup" class="flex flex-1 min-w-0">
                <input type="text" id={"rename-lineup-#{lineup["id"]}"} name="value" value={lineup["name"]} phx-blur="rename_lineup"
                       phx-keydown="cancel_rename_lineup" phx-key="Escape" phx-hook="FocusSelect"
                       class="input input-bordered input-xs w-full font-semibold" />
              </form>
            <% else %>
              <button phx-click="select_lineup" phx-value-id={lineup["id"]}
                      class={"flex flex-1 min-w-0 items-center gap-1.5 text-left text-xs rounded px-1.5 py-1 hover:bg-base-200 " <> if(@lineup_id == lineup["id"], do: "bg-primary/10 border-l-2 border-primary", else: "")}>
                <span class="inline-block w-5 text-center rounded-full text-[10px] font-semibold text-white" style={lineup_color(@data, lineup["id"], 0.9)}><%= playbook_tag(lineup) %></span>
                <span class="flex-1 truncate"><%= lineup["name"] %></span>
                <span class={"text-[10px] " <> if(lineup["sinners"] == [], do: "text-warning", else: "text-base-content/40")}><%= length(lineup["sinners"]) %>/12</span>
              </button>
            <% end %>
            <div class="flex shrink-0 items-center opacity-40 group-hover:opacity-100">
              <button phx-click="copy_lineup" phx-value-id={lineup["id"]} title="Copy this lineup to the clipboard as JSON" class="btn btn-2xs btn-ghost">Copy</button>
              <button phx-click="delete_lineup" phx-value-id={lineup["id"]} data-confirm={"Delete lineup '#{lineup["name"]}'?"} title="Delete this lineup" class="btn btn-2xs btn-ghost text-error">✕</button>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def sinner_rows, do: @sinner_rows

  defp first_profiled_sinner(socket) do
    assigns = socket.assigns
    assigns.data |> sinner_options(assigns.profiles_by_id, assigns.locator_thumbs) |> Enum.find_value(&(&1.profiled? && &1.id))
  end

  def sinner_options(data, profiles_by_id, locator_thumbs) do
    assigned = BattlePlans.profiles(data)

    Enum.map(SinnerProfiles.sinners(), fn sinner ->
      profile = Enum.find_value(Map.get(assigned, sinner, []), &profiles_by_id[&1])
      %{id: sinner, name: sinner_label(sinner), profiled?: not is_nil(profile), thumb: profile_thumb(profile, locator_thumbs)}
    end)
  end

  defp profile_thumb(%{locator_hook: hook}, locator_thumbs) when is_binary(hook) do
    case locator_thumbs do
      %{^hook => version} -> ~p"/hooks/#{hook}/thumb.png?#{[v: version]}"
      _ -> nil
    end
  end

  defp profile_thumb(_profile, _locator_thumbs), do: nil

  def sinner_label(key), do: key |> String.split("_") |> Enum.map_join(" ", &String.capitalize/1)

  def sinner_slot_style(nil), do: nil

  def sinner_slot_style(pos) do
    front = BattlePlans.front_line_size()
    {color, index, total} = if pos < front, do: {"error", pos, front}, else: {"info", pos - front, 5}
    strength = 1.0 - 0.65 * index / max(total - 1, 1)
    border = round(strength * 100)
    fill = round(strength * 50)

    "background-color: color-mix(in oklab, var(--color-#{color}) #{fill}%, transparent); " <>
      "border: 2px solid color-mix(in oklab, var(--color-#{color}) #{border}%, transparent); color: white;"
  end

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

  attr :type, :string, required: true

  def add_icon(%{type: type} = assigns) when type == "chain" do
    ~H"""
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="size-3.5 shrink-0" aria-hidden="true">
      <path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71" />
      <path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71" />
    </svg>
    """
  end

  def add_icon(%{type: "target"} = assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="size-3.5 shrink-0" aria-hidden="true">
      <circle cx="12" cy="12" r="10" />
      <circle cx="12" cy="12" r="6" />
      <circle cx="12" cy="12" r="2" />
    </svg>
    """
  end

  def add_icon(assigns), do: ~H""

  def add_label("chain"), do: "chain"
  def add_label("win_rate"), do: "win rate"
  def add_label("damage_rate"), do: "damage rate"
  def add_label(type), do: type

  def action_label("win_rate"), do: "Win rate (p)"
  def action_label("damage_rate"), do: "Damage rate (p p)"
  def action_label("commit"), do: "Commit (enter)"
  def action_label("dodge"), do: "Dodge"
  def action_label("ego"), do: "EGO"
  def action_label("target"), do: "Target enemy"
  def action_label("if"), do: "If"
  def action_label("retry"), do: "Retry battle"
  def action_label("chain"), do: "Chain"

  def action_tooltip("win_rate"), do: "Press p so Limbus assigns every choice for the best win rate."
  def action_tooltip("damage_rate"),
    do: "Press p until battle_combat_ready, then p again so Limbus assigns every choice for the most damage. If that clears the choices, cycles back around to damage."

  def action_tooltip("commit"), do: "Press enter to start the turn once every skill is chosen."
  def action_tooltip("dodge"), do: "Click below the chosen skill slot to swap it to dodge. With a target, drags the slot onto an enemy instead."
  def action_tooltip("ego"), do: "Hold below the chosen skill slot to open the EGO menu, then pick the grade's card. With a target, then drags the slot onto an enemy."
  def action_tooltip("nothing"), do: "Leave the chosen slots exactly as they are. They still count as handled, so later rows and rest don't touch them."
  def action_tooltip("target"),
    do: "Drag the chosen skill onto an enemy target, found by the white icon above a yellow number. Gives up after 3 tries."

  def action_tooltip("retry"),
    do: "Open battle settings and retry the battle. Once the retries per battle are used up, gives up instead."

  def action_tooltip("if"), do: "Check the condition once against a fresh frame, then run the then actions or the else actions."

  def action_tooltip("chain"), do: "Drag a chain across the skill tray. Fast skips S3, which takes too long to animate, and prefers S2, then S1. A-Res chains the longest same-sin streaks to maximize clash power."

  def chain_mode_tooltip("fast"), do: "Chain without S3, which takes too long to animate. Prefers S2, then S1."
  def chain_mode_tooltip("a_res"), do: "Chain for the longest same-sin streaks to maximize clash power."

  def pick_label("all"), do: "all slots"
  def pick_label("first"), do: "first slots"
  def pick_label("last"), do: "last slots"

  def skill_picks, do: ~w(all first last)

  def playbook_color(data, id, alpha) do
    index = Enum.find_index(data["playbooks"], &(&1["id"] == id)) || 0
    "background-color: hsl(#{rem(index * 67 + 200, 360)} 65% 50% / #{alpha});"
  end

  def paint_style(data, paint) do
    cond do
      paint == "erase" -> "--paint: hsl(0 75% 50% / 0.85);"
      find_playbook(data, paint) -> String.replace(playbook_color(data, paint, 0.85), "background-color:", "--paint:")
      true -> "--paint: hsl(0 0% 50% / 0.4);"
    end
  end

  def paintable_track?(data, paint, track) do
    case find_playbook(data, paint) do
      %{"kind" => kind} -> kind == BattlePlans.track_kind(track)
      _ -> true
    end
  end

  def lineup_paint_style(data, lineup_id, erase?) do
    cond do
      erase? -> "--paint: hsl(0 75% 50% / 0.85);"
      BattlePlans.find_lineup(data, lineup_id) -> String.replace(lineup_color(data, lineup_id, 0.85), "background-color:", "--paint:")
      true -> "--paint: hsl(0 0% 50% / 0.4);"
    end
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

  def available_actions(playbook, actions) do
    has_terminal? = Enum.any?(actions, &BattlePlans.terminal?/1)
    Enum.reject(BattlePlans.action_types(playbook["kind"]), &(has_terminal? and BattlePlans.chain_action?(&1)))
  end

  def branch_available_actions(kind, block, branch) do
    blocked? = Enum.any?(BattlePlans.branch_actions(block, branch), &BattlePlans.terminal?/1)
    Enum.reject(BattlePlans.action_types(kind), &(blocked? and BattlePlans.chain_action?(&1)))
  end

  def ends_with_chain?(actions), do: actions != [] and BattlePlans.terminal?(List.last(actions))

  attr :label, :string, required: true
  attr :title, :string, default: nil
  attr :id, :string, required: true
  attr :condition, :map, default: nil
  attr :open_editor_id, :string, default: nil
  attr :sinner_options, :list, required: true

  def condition_header(assigns) do
    ~H"""
    <div class="flex flex-1 min-w-0 items-start gap-2 rounded bg-teal-700 p-1">
      <span class="flex h-6 shrink-0 items-center pl-1 text-[11px] font-bold tracking-wide text-white cursor-help" title={@title}><%= @label %></span>
      <div class="flex-1 min-w-0">
        <.if_condition id={@id} condition={@condition} open_editor_id={@open_editor_id} sinner_options={@sinner_options} />
      </div>
    </div>
    """
  end

  attr :title, :string, default: nil
  slot :inner_block, required: true

  def keyword_badge(assigns) do
    ~H"""
    <span class="inline-flex shrink-0 items-center rounded bg-teal-700 px-2 py-0.5 text-[11px] font-bold tracking-wide text-white cursor-help" title={@title}><%= render_slot(@inner_block) %></span>
    """
  end

  def depth_bg(0), do: "bg-base-200"
  def depth_bg(1), do: "bg-[color-mix(in_oklab,var(--color-base-200),var(--color-base-content)_6%)]"
  def depth_bg(2), do: "bg-[color-mix(in_oklab,var(--color-base-200),var(--color-base-content)_12%)]"
  def depth_bg(3), do: "bg-[color-mix(in_oklab,var(--color-base-200),var(--color-base-content)_18%)]"
  def depth_bg(_depth), do: "bg-[color-mix(in_oklab,var(--color-base-200),var(--color-base-content)_24%)]"

  def elif_condition(block, elif_id), do: Enum.find_value(BattlePlans.elifs(block), &if(&1["id"] == elif_id, do: &1["condition"]))

  attr :container, :string, required: true
  attr :playbook, :map, required: true
  attr :sinner_options, :list, required: true
  attr :open_editor_id, :string, default: nil
  attr :schedule_tabs, :map, required: true
  attr :reorder_rev, :integer, required: true

  def action_list(assigns) do
    items = BattlePlans.container_actions(assigns.playbook["actions"], assigns.container)
    scope = BattlePlans.scope_actions(assigns.playbook["actions"], assigns.container)
    assigns = assign(assigns, items: items, scope: scope, dom_key: String.replace(assigns.container, "|", "-"))

    ~H"""
    <div class="flex flex-col gap-1">
      <div id={"actions-#{@playbook["id"]}-#{@dom_key}-#{@reorder_rev}"} phx-hook="SortableList" data-sort-event="reorder_actions" data-sort-move-event="move_action_to"
           data-sort-shared={@playbook["id"]} data-sort-scope={@container} data-sort-highlight class="flex flex-col gap-1 min-h-6 rounded">
        <div :for={{item, index} <- Enum.with_index(@items, 1)} data-sort-id={item["id"]} data-sort-handle data-sort-stay={BattlePlans.schedule?(item)}>
          <%= if BattlePlans.schedule?(item) do %>
            <.schedule_block schedule={item} playbook={@playbook} sinner_options={@sinner_options} open_editor_id={@open_editor_id}
                             schedule_tabs={@schedule_tabs} reorder_rev={@reorder_rev} />
          <% else %>
            <.action_row action={item} index={index} sinner_options={@sinner_options} kind={@playbook["kind"]} container={@container}
                         open_editor_id={@open_editor_id} handle?={true} schedulable?={@container == "root"}
                         playbook_id={@playbook["id"]} reorder_rev={@reorder_rev} />
          <% end %>
        </div>
      </div>
      <div class="flex flex-wrap items-center gap-2">
        <div class="join">
          <span class="join-item btn btn-xs pointer-events-none cursor-default bg-primary/15 font-bold text-primary/70" aria-hidden="true" tabindex="-1">+</span>
          <button :for={type <- available_actions(@playbook, @scope)} type="button" phx-click="add_action" phx-value-type={type} phx-value-container={@container}
                  title={action_tooltip(type)} class="join-item btn btn-xs"><.add_icon type={type} /><%= add_label(type) %></button>
        </div>
        <span class="text-[11px] text-base-content/50 italic">
          <%= if ends_with_chain?(@items) do %>
            then: fallback (p + enter if turn didn't start)
          <% else %>
            then: fallback (enter, then p + enter if the turn didn't start)
          <% end %>
        </span>
      </div>
    </div>
    """
  end

  attr :schedule, :map, required: true
  attr :playbook, :map, required: true
  attr :sinner_options, :list, required: true
  attr :open_editor_id, :string, default: nil
  attr :schedule_tabs, :map, required: true
  attr :reorder_rev, :integer, required: true

  def schedule_block(assigns) do
    froms = BattlePlans.segment_froms(assigns.schedule)
    wanted = Map.get(assigns.schedule_tabs, assigns.schedule["id"], 1)
    assigns = assign(assigns, froms: froms, active: if(wanted in froms, do: wanted, else: 1), max_turn: BattlePlans.max_turn())

    ~H"""
    <div class="flex flex-col">
      <div class="flex items-end gap-0.5">
        <span data-sort-handle class="cursor-grab text-base-content/40 select-none px-1 leading-6">⠿</span>
        <%= for from <- @froms do %>
        <%= if BattlePlans.loop_from(@schedule) == from do %>
          <button type="button" phx-click="add_intro_tab" phx-value-schedule={@schedule["id"]} phx-value-turn={from}
                  disabled={Enum.max(@froms) >= @max_turn} title="New tab before the loop"
                  class="rounded-t-lg border border-b-0 border-dashed border-primary/60 px-2 py-0.5 text-[11px] text-primary hover:bg-primary/20 disabled:opacity-30">+</button>
          <span class="px-1 text-[11px] text-primary leading-6" title="Everything from here repeats forever">↻</span>
        <% end %>
        <div class={"flex items-center gap-0.5 rounded-t-lg border border-b-0 px-2 py-0.5 text-[11px] " <>
               if(from == @active, do: "border-primary bg-primary text-primary-content font-semibold", else: "border-primary/40 bg-primary/25 hover:bg-primary/40")}>
          <button type="button" phx-click="select_schedule_tab" phx-value-schedule={@schedule["id"]} phx-value-from={from}
                  title={if BattlePlans.loop_segment?(@schedule, from), do: BattlePlans.loop_turns_label(@schedule, from)}><%= BattlePlans.segment_label(@schedule, from) %></button>
          <div :if={from != 1 and not BattlePlans.loop_segment?(@schedule, from)} class="dropdown">
            <div tabindex="0" role="button" class="cursor-pointer opacity-60 hover:opacity-100" title="Change the turn this starts on">
              <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" class="w-3 h-3"><path d="m6 9 6 6 6-6" /></svg>
            </div>
            <div tabindex="0" class="dropdown-content z-30 mt-1 w-56 rounded-lg border border-base-300 bg-base-100 p-1.5 shadow-lg">
              <div class="grid grid-cols-5 gap-0.5">
                <button :for={turn <- 2..@max_turn} type="button" phx-click="move_schedule_segment" phx-value-schedule={@schedule["id"]} phx-value-from={from} phx-value-to={turn}
                        disabled={(turn != from and turn in @froms) or BattlePlans.loop_segment?(@schedule, turn)} class={"btn btn-xs " <> if(turn == from, do: "btn-primary", else: "btn-ghost")}>T<%= turn %></button>
              </div>
            </div>
          </div>
          <%= cond do %>
            <% BattlePlans.loop_segment?(@schedule, from) and from == BattlePlans.loop_from(@schedule) and Enum.count(@froms, &(&1 >= from)) == 1 -> %>
              <button type="button" phx-click="set_schedule_loop" phx-value-schedule={@schedule["id"]} phx-value-turn="" class="opacity-60 hover:opacity-100" title="Remove the loop, keeping its tab">✕</button>
            <% BattlePlans.loop_segment?(@schedule, from) and from == Enum.max(@froms) -> %>
              <button type="button" phx-click="remove_schedule_segment" phx-value-schedule={@schedule["id"]} phx-value-from={from} class="opacity-60 hover:opacity-100" title="Close this loop tab">✕</button>
            <% BattlePlans.loop_segment?(@schedule, from) -> %>
            <% from != 1 -> %>
              <button type="button" phx-click="remove_schedule_segment" phx-value-schedule={@schedule["id"]} phx-value-from={from} class="opacity-60 hover:opacity-100"
                      title={"Close this tab; #{BattlePlans.segment_label(@schedule, from)} use the earlier tab's actions"}>✕</button>
            <% length(@froms) == 1 -> %>
              <button type="button" phx-click="remove_schedule" phx-value-schedule={@schedule["id"]} class="opacity-60 hover:opacity-100"
                      title="Remove the schedule, keeping its actions">✕</button>
            <% true -> %>
          <% end %>
        </div>
        <% end %>
        <button type="button" phx-click="split_schedule" phx-value-schedule={@schedule["id"]} phx-value-turn={Enum.max(@froms) + 1}
                disabled={Enum.max(@froms) >= @max_turn} title={if BattlePlans.looping?(@schedule), do: "New loop tab", else: "New tab"}
                class="rounded-t-lg border border-b-0 border-dashed border-primary/60 px-2 py-0.5 text-[11px] text-primary hover:bg-primary/20 disabled:opacity-30">+</button>
        <div class="dropdown ml-auto">
          <div tabindex="0" role="button" title="Repeat the tabs from a turn onward, starting over once the last one is done"
               class={"rounded-t-lg border border-b-0 px-2 py-0.5 text-[11px] cursor-pointer " <> if(BattlePlans.looping?(@schedule), do: "border-primary bg-primary text-primary-content font-semibold", else: "border-primary/40 hover:bg-primary/20")}>
            <%= if BattlePlans.looping?(@schedule), do: "Loop from T#{BattlePlans.loop_from(@schedule)}", else: "Loop" %>
          </div>
          <div tabindex="0" class="dropdown-content z-30 mt-1 w-56 rounded-lg border border-base-300 bg-base-100 p-1.5 shadow-lg right-0">
            <div class="grid grid-cols-5 gap-0.5">
              <button :for={turn <- 1..@max_turn} type="button" phx-click="set_schedule_loop" phx-value-schedule={@schedule["id"]} phx-value-turn={turn}
                      class={"btn btn-xs " <> if(turn == BattlePlans.loop_from(@schedule), do: "btn-primary", else: "btn-ghost")}>T<%= turn %></button>
            </div>
            <button :if={BattlePlans.looping?(@schedule)} type="button" phx-click="set_schedule_loop" phx-value-schedule={@schedule["id"]} phx-value-turn="" class="btn btn-xs btn-ghost mt-1 w-full">No loop</button>
          </div>
        </div>
      </div>
      <div class="p-1 border-2 border-primary rounded-b-lg rounded-tr-lg">
        <.action_list container={@schedule["id"] <> "|" <> to_string(@active)} playbook={@playbook} sinner_options={@sinner_options}
                      open_editor_id={@open_editor_id} schedule_tabs={@schedule_tabs} reorder_rev={@reorder_rev} />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :condition, :map, default: nil
  attr :open_editor_id, :string, default: nil
  attr :sinner_options, :list, required: true

  def if_condition(assigns) do
    ~H"""
    <%= if @condition do %>
      <%= if @open_editor_id == @id do %>
        <div phx-click-away="close_editor" class="flex items-start gap-1 rounded bg-base-100 p-1">
          <button type="button" phx-click="close_editor" title="Close the condition editor" class="btn btn-ghost btn-xs h-6 min-h-6 px-1">▾</button>
          <div class="flex-1 min-w-0">
            <.condition_node node={@condition} path="" values={%{"action" => @id}} removable={not is_map_key(@condition, "children")}
                             leaf={&hook_leaf(Map.put(&1, :sinner_options, @sinner_options))} />
          </div>
        </div>
      <% else %>
        <button type="button" phx-click="open_editor" phx-value-action={@id}
                class="btn btn-outline btn-xs bg-base-100 h-6 min-h-6 w-full justify-start font-normal normal-case">
          <span class="text-base-content/50">▸</span><span class="truncate"><%= BattlePlans.condition_label(@condition, Map.new(@sinner_options, &{&1.id, &1.name})) %></span>
        </button>
      <% end %>
    <% else %>
      <button type="button" phx-click="cond_add" phx-value-action={@id} phx-value-path="" phx-value-node="leaf"
              class="btn btn-2xs btn-ghost self-start">+ Add condition</button>
    <% end %>
    """
  end

  attr :action, :map, required: true
  attr :index, :integer, required: true
  attr :sinner_options, :list, required: true
  attr :kind, :string, required: true
  attr :container, :string, default: "root"
  attr :handle?, :boolean, default: false
  attr :schedulable?, :boolean, default: false
  attr :open_editor_id, :string, default: nil
  attr :playbook_id, :string, default: nil
  attr :reorder_rev, :integer, default: 0
  attr :depth, :integer, default: 0

  def action_row(%{action: %{"type" => "if"}} = assigns) do
    ~H"""
    <div class={"flex items-start gap-2 rounded-lg border border-base-300 p-2 text-xs " <> depth_bg(@depth)}>
      <span :if={@handle?} data-sort-handle class="cursor-grab text-base-content/40 select-none pt-1">⠿</span>
      <span class="text-base-content/50 w-4 pt-1"><%= @index %>.</span>
      <div class="flex flex-col gap-1 flex-1 min-w-0">
        <div class="flex items-start gap-2">
          <.condition_header label="IF" title={action_tooltip("if")} id={@action["id"]} condition={@action["condition"]} open_editor_id={@open_editor_id} sinner_options={@sinner_options} />
          <div class="flex gap-0.5 shrink-0">
            <button :if={@schedulable?} type="button" phx-click="add_schedule" phx-value-action={@action["id"]} title="Change this action across turns"
                    class="btn btn-2xs btn-ghost">Add Schedule</button>
            <button phx-click="dup_action" phx-value-action={@action["id"]} title="Duplicate this block" class="btn btn-2xs btn-ghost">Dup</button>
            <button phx-click="remove_action" phx-value-action={@action["id"]} class="btn btn-2xs btn-ghost text-error">✕</button>
          </div>
        </div>
        <%= for branch <- BattlePlans.branches(@action) do %>
          <div class="flex flex-col gap-1 pl-3 border-l-2 border-base-300">
            <div :if={branch not in ["then", "else"]} class="flex items-start gap-2">
              <.condition_header label="ELSE IF" id={branch} condition={elif_condition(@action, branch)} open_editor_id={@open_editor_id} sinner_options={@sinner_options} />
              <button type="button" phx-click="remove_elif" phx-value-elif={branch} title="Remove this else if" class="btn btn-2xs btn-ghost text-error shrink-0">✕</button>
            </div>
            <div :if={branch == "else"} class="flex items-center gap-1">
              <.keyword_badge>ELSE</.keyword_badge>
              <button type="button" phx-click="remove_else" phx-value-parent={@action["id"]} title="Remove the else branch" class="btn btn-2xs btn-ghost text-error">✕</button>
            </div>
            <% actions = BattlePlans.branch_actions(@action, branch) %>
            <div id={"branch-#{@playbook_id}-#{@action["id"]}-#{branch}-#{@reorder_rev}"} phx-hook="SortableList" data-sort-event="reorder_actions" data-sort-move-event="move_action_to"
                 data-sort-shared={@playbook_id} data-sort-scope={@action["id"] <> "~" <> branch} data-sort-highlight
                 class={"flex flex-col gap-1 rounded " <> if(actions == [], do: "min-h-12 items-center justify-center border-2 border-dashed border-primary/60 bg-primary/10 text-xs font-semibold text-primary before:content-['Empty,_add_an_action_below']", else: "min-h-6")}>
              <div :for={{child, child_index} <- Enum.with_index(actions, 1)} data-sort-id={child["id"]} data-sort-handle>
                <.action_row action={child} index={child_index} sinner_options={@sinner_options} kind={@kind} container={@container} open_editor_id={@open_editor_id}
                             handle?={true} playbook_id={@playbook_id} reorder_rev={@reorder_rev} depth={@depth + 1} />
              </div>
            </div>
            <div class="flex flex-wrap items-center gap-2">
              <button :if={branch != "else"} type="button" phx-click="add_elif"
                      phx-value-parent={@action["id"]} phx-value-after={branch} title="Add an else if after this branch" class="btn btn-xs btn-ghost">+ else if</button>
              <button :if={branch != "else" and not BattlePlans.has_else?(@action) and branch == List.last(BattlePlans.branches(@action))} type="button" phx-click="add_else"
                      phx-value-parent={@action["id"]} title="Add an else branch" class="btn btn-xs btn-ghost">+ else</button>
              <div class="join self-start">
                <span class="join-item btn btn-xs pointer-events-none cursor-default bg-primary/15 font-bold text-primary/70" aria-hidden="true" tabindex="-1">+</span>
                <button :for={type <- branch_available_actions(@kind, @action, branch)} type="button" phx-click="add_action"
                        phx-value-type={type} phx-value-container={@container} phx-value-parent={@action["id"]} phx-value-branch={branch}
                        title={action_tooltip(type)} class="join-item btn btn-xs"><.add_icon type={type} /><%= add_label(type) %></button>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def action_row(assigns) do
    ~H"""
    <div class={"flex items-start gap-2 rounded-lg border border-base-300 p-2 text-xs " <> depth_bg(@depth)}>
      <span :if={@handle?} data-sort-handle class="cursor-grab text-base-content/40 select-none pt-1">⠿</span>
      <span class="text-base-content/50 w-4 pt-1"><%= @index %>.</span>
      <form phx-change="update_action" class="flex flex-col gap-1 flex-1 min-w-0">
        <input type="hidden" name="action" value={@action["id"]} />
        <%= if @action["type"] in ~w(dodge ego target nothing) and @open_editor_id != @action["id"] do %>
          <.row_summary key={@action["id"]} lines={BattlePlans.rows_parts(@action)} sinner_options={@sinner_options} />
        <% end %>
        <%= if @action["type"] in ~w(dodge ego target nothing) and @open_editor_id == @action["id"] do %>
          <div phx-click-away="close_editor" class="flex items-start gap-1">
            <button type="button" phx-click="close_editor" title="Collapse this row" class="btn btn-ghost btn-xs h-6 min-h-6 px-1">▾</button>
            <div class="flex flex-col gap-1 flex-1 min-w-0">
          <div id={"rows-#{@action["id"]}-#{@reorder_rev}"} phx-hook="SortableList" data-sort-event="reorder_rows" data-sort-scope={"#{@action["id"]}|"} class="flex flex-col gap-1">
            <div data-sort-id="0" data-sort-handle={is_map(@action["rest"]) || nil} class="flex flex-wrap items-stretch gap-2">
              <span :if={is_map(@action["rest"])} data-sort-handle class="cursor-grab text-base-content/40 select-none self-center">⠿</span>
              <.slot_selector holder={@action} prefix="" sinner_options={@sinner_options} action_id={@action["id"]} />
              <.rule_boxes holder={@action} prefix="" ego_only?={@kind == "chain" and @action["type"] in ~w(ego dodge)} chain?={@kind == "chain"} nothing?={@kind != "chain"} owner={@action["id"]} />
              <.target_box :if={@kind != "chain" or @action["type"] not in ~w(ego dodge)} holder={@action} prefix="" owner={@action["id"]} />
            </div>
            <.rest_stack :if={not (@kind == "chain" and @action["type"] in ~w(ego dodge))} holder={@action} prefix="" enemy?={true} chain?={@kind == "chain"} nothing?={@kind != "chain"} owner={@action["id"]} sinner_options={@sinner_options} />
          </div>
          <.add_rest :if={not (@kind == "chain" and @action["type"] in ~w(ego dodge))} holder={@action} prefix="" owner={@action["id"]} label={if @kind == "chain", do: "+ Pin remaining skills", else: "+ Target remaining skills"} />
            </div>
          </div>
        <% end %>
        <%= if @action["type"] not in ~w(dodge ego target nothing) do %>
          <div class="flex items-center gap-2 min-h-6">
            <%= case @action["type"] do %>
              <% type when type in ~w(win_rate damage_rate) -> %>
                <span class="inline-flex items-center gap-1.5 rounded bg-red-800 px-2 py-0.5 font-semibold whitespace-nowrap text-yellow-300 cursor-help" title={action_tooltip(type)}>
                  <%= if type == "win_rate", do: "Win Rate", else: "Damage Rate" %>
                  <span class="[text-shadow:0_0_6px_#fde047,0_0_12px_#facc15]">▲</span>
                  <%= if type == "win_rate", do: "(p)", else: "(p p)" %>
                </span>
              <% "commit" -> %>
                <span class="inline-flex items-center rounded bg-base-content/20 px-2 py-0.5 font-semibold whitespace-nowrap cursor-help" title={action_tooltip("commit")}>Commit (enter)</span>
              <% type -> %>
                <span class="font-semibold whitespace-nowrap cursor-help" title={action_tooltip(type)}><%= action_label(type) %></span>
            <% end %>
            <div :if={@action["type"] == "chain"} class="join">
              <button :for={{mode, label} <- [{"fast", "fast"}, {"a_res", "a-res"}]} type="button" phx-click="set_chain_mode" phx-value-action={@action["id"]} phx-value-mode={mode}
                      title={chain_mode_tooltip(mode)} class={["join-item btn btn-xs", (@action["mode"] || "fast") == mode && "btn-primary"]}><%= label %></button>
            </div>
          </div>
        <% end %>

        <%= if Map.has_key?(@action, "pins") do %>
          <div id={"pins-#{@action["id"]}"} class="flex flex-col gap-1">
          <%= for {pin, pin_index} <- Enum.with_index(@action["pins"]) do %>
            <%= if @open_editor_id != pin_key(@action, pin_index) do %>
              <div class="flex items-start gap-2 pl-4">
                <.row_summary key={pin_key(@action, pin_index)} lines={BattlePlans.rows_parts(pin, false)} sinner_options={@sinner_options} />
                <button type="button" phx-click="remove_pin" phx-value-action={@action["id"]} phx-value-index={pin_index}
                        class="btn btn-xs btn-ghost text-error self-center">✕</button>
              </div>
            <% else %>
            <div phx-click-away="close_editor" class="flex items-start gap-2 pl-4">
              <button type="button" phx-click="close_editor" title="Collapse this pin" class="btn btn-ghost btn-xs h-6 min-h-6 px-1">▾</button>
              <div id={"rows-#{@action["id"]}-pin-#{pin_index}-#{@reorder_rev}"} phx-hook="SortableList" data-sort-event="reorder_rows"
                   data-sort-scope={"#{@action["id"]}|pins[#{pin_index}]"} class="flex flex-col gap-1 flex-1 min-w-0">
                <div data-sort-id="0" data-sort-handle={is_map(pin["rest"]) || nil} class="flex flex-wrap items-stretch gap-2">
                  <span :if={is_map(pin["rest"])} data-sort-handle class="cursor-grab text-base-content/40 select-none self-center">⠿</span>
                  <.slot_selector holder={pin} prefix={"pins[#{pin_index}]"} sinner_options={@sinner_options} action_id={@action["id"]} pin?={true} />
                  <.rule_boxes holder={pin} prefix={"pins[#{pin_index}]"} chain?={@kind == "chain"} owner={@action["id"]} />
                  <button type="button" phx-click="remove_pin" phx-value-action={@action["id"]} phx-value-index={pin_index}
                          class="btn btn-xs btn-ghost text-error self-center">✕</button>
                </div>
                <.rest_stack holder={pin} prefix={"pins[#{pin_index}]"} enemy?={false} chain?={@kind == "chain"} owner={@action["id"]} sinner_options={@sinner_options} />
                <.add_rest holder={pin} prefix={"pins[#{pin_index}]"} owner={@action["id"]} />
              </div>
            </div>
            <% end %>
          <% end %>
          </div>
          <button :if={@action["pins"] == []} type="button" phx-click="add_pin" phx-value-action={@action["id"]}
                  class="btn btn-xs btn-ghost self-start ml-4">+ pin</button>
        <% end %>
      </form>
      <div class="flex gap-0.5">
        <button :if={@schedulable?} type="button" phx-click="add_schedule" phx-value-action={@action["id"]} title="Change this action across turns"
                class="btn btn-2xs btn-ghost">Add Schedule</button>
        <button :if={BattlePlans.duplicable?(@action)} phx-click="dup_action" phx-value-action={@action["id"]} title="Duplicate this row" class="btn btn-2xs btn-ghost">Dup</button>
        <button phx-click="remove_action" phx-value-action={@action["id"]} class="btn btn-2xs btn-ghost text-error">✕</button>
      </div>
    </div>
    """
  end

  attr :key, :string, required: true
  attr :lines, :list, required: true
  attr :sinner_options, :list, required: true

  def row_summary(assigns) do
    assigns = assign(assigns, options_by_id: Map.new(assigns.sinner_options, &{&1.id, &1}))

    ~H"""
    <button type="button" phx-click="open_editor" phx-value-action={@key}
            class="btn btn-outline btn-xs bg-base-100 h-auto min-h-6 flex-1 min-w-0 flex-col items-start justify-start gap-0 py-0.5 text-left font-normal normal-case">
      <span :for={{line, index} <- Enum.with_index(@lines)} class="block w-full whitespace-normal leading-6"><span class="text-base-content/50"><%= if index == 0, do: "▸ ", else: "↳ " %></span><%= for part <- line do %><.summary_part part={part} options_by_id={@options_by_id} /><% end %></span>
    </button>
    """
  end

  attr :part, :any, required: true
  attr :options_by_id, :map, required: true

  def summary_part(%{part: {:sinner, id}} = assigns) do
    assigns = assign(assigns, option: Map.get(assigns.options_by_id, id, %{id: id, name: id}))

    ~H"""
    <img src={@option[:thumb] || StarlightBot.SinnerProfiles.icon(@option.id)} title={@option.name} alt={@option.name} class="inline-block h-[1.15em] w-auto rounded align-text-bottom" />
    """
  end

  def summary_part(%{part: {:term, value}} = assigns) do
    assigns = assign(assigns, value: value)

    ~H"""
    <.priority_chip value={@value} name="" static />
    """
  end

  def summary_part(%{part: {:slot, name}} = assigns) do
    assigns = assign(assigns, name: name)

    ~H"""
    <span class="inline-flex items-center h-5 px-1.5 rounded border border-primary bg-primary align-baseline text-[11px] font-semibold text-primary-content"><%= @name %></span>
    """
  end

  def summary_part(%{part: :not} = assigns) do
    ~H"""
    <span class="inline-flex items-center h-5 px-1.5 rounded bg-error align-baseline text-[11px] font-semibold text-error-content">NOT</span>
    """
  end

  def summary_part(assigns), do: ~H"<%= @part %>"

  def pin_key(action, pin_index), do: "#{action["id"]}|pins[#{pin_index}]"

  attr :holder, :map, required: true
  attr :prefix, :string, required: true
  attr :enemy?, :boolean, required: true
  attr :nothing?, :boolean, default: false
  attr :chain?, :boolean, default: false
  attr :owner, :string, required: true
  attr :sinner_options, :list, required: true
  attr :index, :integer, default: 1

  def rest_stack(assigns) do
    ~H"""
    <%= if @holder["rest"] do %>
      <div data-sort-id={@index} data-sort-handle class="flex flex-wrap items-stretch gap-2 border-l-2 border-primary/50 pl-2">
        <span data-sort-handle class="cursor-grab text-base-content/40 select-none self-center">⠿</span>
        <div class="flex flex-col gap-1.5 rounded bg-base-100 p-1.5">
          <span class="badge badge-primary badge-soft badge-sm w-fit cursor-help font-semibold" title="Rules for every slot the actions above didn't capture">↳ Remaining skills</span>
          <.slot_selector holder={@holder["rest"]} prefix={field_name(@prefix, "rest")} sinner_options={@sinner_options} action_id={@owner} pin?={@chain?} />
        </div>
        <.rule_boxes holder={@holder["rest"]} prefix={field_name(@prefix, "rest")} chain?={@chain?} nothing?={@nothing?} owner={@owner} />
        <.target_box :if={@enemy? and not (@chain? and @holder["rest"]["type"] == "dodge")} holder={@holder["rest"]} prefix={field_name(@prefix, "rest")} owner={@owner} continue?={true} />
        <button type="button" phx-click="remove_rest" phx-value-action={@owner} phx-value-path={@prefix} title="Remove this rest and any below it"
                class="btn btn-xs btn-ghost text-error self-center">✕</button>
      </div>
      <.rest_stack holder={@holder["rest"]} prefix={field_name(@prefix, "rest")} enemy?={@enemy?} chain?={@chain?} nothing?={@nothing?} owner={@owner} sinner_options={@sinner_options} index={@index + 1} />
    <% end %>
    """
  end

  attr :holder, :map, required: true
  attr :prefix, :string, required: true
  attr :owner, :string, required: true
  attr :label, :string, default: "+ Pin remaining skills"

  def add_rest(assigns) do
    {_tail, prefix} = rest_tail(assigns.holder, assigns.prefix)
    assigns = assign(assigns, tail_prefix: prefix)

    ~H"""
    <button type="button" phx-click="add_rest" phx-value-action={@owner} phx-value-path={@tail_prefix}
            title="Define rules for every slot the rows above don't capture"
            class="btn btn-ghost h-4 min-h-4 px-1 text-[11px] text-base-content/60 self-start"><%= @label %></button>
    """
  end

  defp rest_tail(%{"rest" => rest}, prefix) when is_map(rest), do: rest_tail(rest, field_name(prefix, "rest"))
  defp rest_tail(holder, prefix), do: {holder, prefix}

  attr :holder, :map, required: true
  attr :prefix, :string, required: true
  attr :sinner_options, :list, required: true
  attr :action_id, :string, required: true
  attr :pin?, :boolean, default: false

  def slot_selector(assigns) do
    assigns = assign(assigns, skill: assigns.holder["skill"] || BattlePlans.first_slot())

    ~H"""
    <div class="flex flex-col gap-1.5 rounded bg-base-100 p-1.5">
      <.sinner_picker holder={@holder} prefix={@prefix} sinner_options={@sinner_options} action_id={@action_id} pin?={@pin?} />
      <div class="flex flex-wrap items-center gap-1">
        <select name={field_name(@prefix, "pick")} class="select select-bordered select-xs w-auto" title="Which of the selected slots to act on, counted across all of them together (everyone's slots in tray order, not per sinner)">
          <option :for={pick <- skill_picks()} value={pick} selected={@skill["pick"] == pick}><%= pick_label(pick) %></option>
        </select>
      </div>
      <.slot_chips :if={@skill["pick"] != "all"} skill={@skill} prefix={@prefix} action_id={@action_id} />
    </div>
    """
  end

  attr :skill, :map, required: true
  attr :prefix, :string, required: true
  attr :action_id, :string, required: true
  attr :path, :string, default: nil
  attr :step_event, :string, default: "step_slot_chip"
  attr :add_event, :string, default: "add_slot_chip"

  def slot_chips(assigns) do
    skill = BattlePlans.normalize_skill(assigns.skill)
    view = BattlePlans.skill_view(skill)
    assigns = assign(assigns, pick: skill["pick"], view: if(skill["pick"] == "last", do: Enum.reverse(view), else: view))

    ~H"""
    <div class="flex flex-wrap items-center gap-1">
      <.slot_add :if={@pick == "last"} action_id={@action_id} path={@path || @prefix} event={@add_event} />
      <%= for item <- @view do %>
        <%= case item do %>
          <% {:chip, index, at, on} -> %>
            <span class="join">
              <input type="hidden" name={field_name(@prefix, "chip") <> "[#{index}][on]"} value="false" />
              <input type="hidden" name={field_name(@prefix, "chip") <> "[#{index}][at]"} value={at} />
              <button type="button" phx-click={@step_event} phx-value-action={@action_id} phx-value-path={@path || @prefix} phx-value-index={index} phx-value-delta={left_delta(@pick)}
                      disabled={at == 0 and left_delta(@pick) == "-1"} title={left_title(@pick)} class="join-item btn btn-xs px-1.5 text-[9px]">◀</button>
              <label class="join-item relative cursor-pointer">
                <input type="checkbox" name={field_name(@prefix, "chip") <> "[#{index}][on]"} value="true" checked={on} class="peer sr-only" />
                <span class={chip_toggle_class(true)}><%= BattlePlans.chip_name(@pick, at) %></span>
              </label>
              <button type="button" phx-click={@step_event} phx-value-action={@action_id} phx-value-path={@path || @prefix} phx-value-index={index} phx-value-delta={right_delta(@pick)}
                      disabled={at == 0 and right_delta(@pick) == "-1"} title={right_title(@pick)} class="join-item btn btn-xs px-1.5 text-[9px]">▶</button>
            </span>
          <% {:gap, key, on, lo, hi} -> %>
            <span class="inline-flex items-center" title={gap_title(@pick, lo, hi)}>
              <input type="hidden" name={gap_field(@prefix, key)} value="false" />
              <label class="relative cursor-pointer">
                <input type="checkbox" name={gap_field(@prefix, key)} value="true" checked={on} class="peer sr-only" />
                <span class={chip_toggle_class()}>...</span>
              </label>
            </span>
        <% end %>
      <% end %>
      <.slot_add :if={@pick == "first"} action_id={@action_id} path={@path || @prefix} event={@add_event} />
    </div>
    """
  end

  attr :action_id, :string, required: true
  attr :path, :string, required: true
  attr :event, :string, required: true

  def slot_add(assigns) do
    ~H"""
    <button type="button" phx-click={@event} phx-value-action={@action_id} phx-value-path={@path} title="Add another slot position"
            class="btn btn-outline h-6 min-h-6 px-2">+</button>
    """
  end

  defp chip_toggle_class(fused? \\ false),
    do: "inline-flex items-center h-6 px-1.5 border border-dashed border-base-content/30 text-[11px] font-semibold text-base-content/40 select-none peer-checked:border-solid peer-checked:border-primary peer-checked:bg-primary peer-checked:text-primary-content " <> if(fused?, do: "rounded-none", else: "rounded")

  defp left_delta("last"), do: "1"
  defp left_delta(_pick), do: "-1"
  defp right_delta("last"), do: "-1"
  defp right_delta(_pick), do: "1"

  defp left_title("last"), do: "Move this position further from the last"
  defp left_title(_pick), do: "Move this position closer to the first"
  defp right_title("last"), do: "Move this position closer to the last"
  defp right_title(_pick), do: "Move this position further from the first"

  defp gap_field(prefix, :lead), do: field_name(prefix, "gap_lead")
  defp gap_field(prefix, :trail), do: field_name(prefix, "gap_trail")
  defp gap_field(prefix, {:mid, index}), do: field_name(prefix, "gap_mid") <> "[#{index}]"

  defp gap_title(pick, lo, :inf), do: "Every slot past #{BattlePlans.chip_name(pick, lo - 1)}"
  defp gap_title(pick, lo, hi) when lo == hi, do: "The slot at #{BattlePlans.chip_name(pick, lo)}"
  defp gap_title(pick, lo, hi), do: "The slots from #{BattlePlans.chip_name(pick, lo)} to #{BattlePlans.chip_name(pick, hi)}"

  attr :holder, :map, required: true
  attr :prefix, :string, required: true
  attr :owner, :string, required: true
  attr :ego_only?, :boolean, default: false
  attr :chain?, :boolean, default: false
  attr :nothing?, :boolean, default: false

  def rule_boxes(assigns) do
    holder = if assigns.ego_only?, do: assigns.holder, else: BattlePlans.normalize_dodge(assigns.holder)
    assigns = assign(assigns, holder: holder, type: holder["type"] || "target")

    ~H"""
    <div class="flex flex-col gap-1.5 rounded bg-base-100 p-1.5 shrink-0">
      <.radio_group :if={@ego_only?} name={field_name(@prefix, "kind")} value={@type} options={[{"ego", "EGO"}, {"dodge", "Dodge"}]} />
      <.radio_group :if={not @ego_only?} name={field_name(@prefix, "kind")} value={action_kind(@holder)} options={[{"priority", "Priority"}, {"ego", "EGO"}] ++ if(@nothing?, do: [{"nothing", "Nothing"}], else: [])} />
      <%= if @holder["row"] == "priority" do %>
        <div class="flex flex-wrap items-center gap-1">
          <.row_picker holder={@holder} prefix={@prefix} select?={false} owner={@owner} />
        </div>
      <% end %>
      <%= if @type == "ego" do %>
        <div class="flex flex-wrap items-center gap-2">
          <.radio_group name={field_name(@prefix, "grade")} value={@holder["grade"]} options={Enum.map(BattlePlans.grades(), &{&1, String.upcase(&1)})} />
          <label class="flex items-center gap-1 cursor-pointer">
            <input type="hidden" name={field_name(@prefix, "corrode")} value="false" />
            <input type="checkbox" name={field_name(@prefix, "corrode")} value="true" checked={@holder["corrode"]} class="checkbox checkbox-xs" />
            corrode
          </label>
        </div>
      <% end %>
    </div>
    """
  end

  attr :holder, :map, required: true
  attr :prefix, :string, required: true
  attr :owner, :string, required: true
  attr :continue?, :boolean, default: false

  def target_box(assigns) do
    default = if assigns.continue?, do: %{"pick" => "continue"}, else: %{"pick" => "none"}
    assigns = assign(assigns, enemy: assigns.holder["enemy"] || default, type: assigns.holder["type"] || "target")

    ~H"""
    <div class="flex flex-col gap-1.5 rounded bg-base-100 p-1.5 shrink-0">
      <span class="font-semibold cursor-help" title={action_tooltip("target")}>Target</span>
      <%= if @type in ~w(target ego dodge) do %>
        <.radio_group name={field_name(@prefix, "enemy_pick")} value={enemy_pick_value(@enemy)} options={[{"none", "none"}, {"first", "from first"}, {"last", "from last"}] ++ if(@continue?, do: [{"continue", "continue"}], else: [])} />
        <%= if enemy_pick_value(@enemy) not in ~w(none continue) do %>
          <div class="flex items-center gap-1" title="The target slot the first sinner slot goes to, counted from that end. Past the last target, it uses the last target.">
            <span class="text-base-content/60">slot</span>
            <input type="number" name={field_name(@prefix, "enemy_n")} min="1" value={@enemy["n"] || 1} class="input input-bordered input-xs w-14" phx-debounce="300" />
          </div>
          <div class="flex items-center gap-1" title="With several sinner slots, each next one goes one target further this way. Once the targets run out, the rest all use the last one.">
            <span class="text-base-content/60">then</span>
            <.radio_group name={field_name(@prefix, "enemy_step")} value={@enemy["step"] || "same"} options={[{"left", "← left"}, {"same", "same"}, {"right", "right →"}]} />
          </div>
        <% end %>
        <label :if={enemy_pick_value(@enemy) != "none"} class="flex items-center gap-1 cursor-pointer" title="If the slot is already using the skill this picks (top or bottom), leave its target alone instead of dragging it onto an enemy again. Dodge and EGO count as bottom.">
          <input type="hidden" name={field_name(@prefix, "skip_bottom_target")} value="false" />
          <input type="checkbox" name={field_name(@prefix, "skip_bottom_target")} value="true" checked={Map.get(@holder, "skip_bottom_target", true)} class="checkbox checkbox-xs" />
          don't retarget if possible
        </label>
        <%= if enemy_pick_value(@enemy) not in ~w(none continue) do %>
          <div class="flex flex-col gap-1" title="Applied in order before picking. Each step cuts that many enemies from one side, but always leaves at least one.">
            <div :for={{ignore, index} <- Enum.with_index(@enemy["ignore"] || [])} class="flex items-center gap-1">
              <span class="text-base-content/60">ignore</span>
              <select name={field_name(@prefix, "enemy_ignore") <> "[#{index}][side]"} class="select select-bordered select-xs w-auto">
                <option :for={side <- BattlePlans.ignore_sides()} value={side} selected={ignore["side"] == side}><%= side %></option>
              </select>
              <input type="number" name={field_name(@prefix, "enemy_ignore") <> "[#{index}][n]"} min="1" max="99" value={ignore["n"]} class="input input-bordered input-xs w-14" phx-debounce="300" />
              <span class="text-base-content/60">slots</span>
              <button type="button" phx-click="remove_ignore" phx-value-action={@owner} phx-value-path={@prefix} phx-value-index={index}
                      class="btn btn-ghost text-error h-6 min-h-6 px-1">✕</button>
            </div>
            <select id={"ignore-add-#{@owner}-#{@prefix}-#{length(@enemy["ignore"] || [])}"} name={field_name(@prefix, "enemy_ignore_add")} class="select select-bordered select-xs w-auto self-start">
              <option value="" selected>+ ignore</option>
              <option :for={side <- BattlePlans.ignore_sides()} value={side}><%= side %></option>
            </select>
          </div>
        <% end %>
      <% else %>
        <span class="text-base-content/50">none</span>
      <% end %>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :value, :string, default: nil
  attr :options, :list, required: true

  def radio_group(assigns) do
    ~H"""
    <div class="join">
      <input :for={{value, label} <- @options} type="radio" name={@name} value={value} aria-label={label}
             checked={@value == value} class="join-item btn btn-xs" />
    </div>
    """
  end

  def enemy_pick_value(%{"pick" => pick}) when pick in ~w(none first last continue), do: pick
  def enemy_pick_value(_enemy), do: "first"

  def action_kind(%{"type" => "target", "row" => row}), do: row
  def action_kind(%{"type" => type}), do: type
  def action_kind(%{"row" => row}), do: row

  attr :holder, :map, required: true
  attr :prefix, :string, required: true
  attr :sinner_options, :list, required: true
  attr :action_id, :string, required: true
  attr :pin?, :boolean, default: false

  def sinner_picker(assigns) do
    chosen = assigns.holder["sinners"] || []
    assigns = assign(assigns, chosen: chosen)

    ~H"""
    <div class="flex flex-col items-start gap-1">
      <.radio_group name={field_name(@prefix, "who_mode")} value={if @holder["who"] == "everyone", do: "everyone", else: "sinners"} options={[{"everyone", "everyone"}, {"sinners", "sinners"}]} />
      <.radio_group :if={@holder["who"] != "everyone"} name={field_name(@prefix, "who")} value={@holder["who"] || "only"}
                    options={[{"only", "all of"}, {"except", "all but"}, {"before", "all before"}, {"after", "all after"}]} />
    </div>
    <%= if @holder["who"] != "everyone" do %>
      <.sinner_multi name={field_name(@prefix, "sinners_csv")} chosen={@chosen} sinner_options={@sinner_options} empty_label="(none selected)" />
    <% end %>
    <%= if is_map(@holder["where"]) do %>
      <div class="flex items-start gap-1">
        <span class="text-base-content/60 cursor-help" title="Narrow the selection to slots that also match these conditions">where</span>
        <.chosen_picker holder={@holder} prefix={@prefix} action_id={@action_id} pin?={@pin?} />
        <button type="button" phx-click="remove_where" phx-value-action={@action_id} phx-value-path={@prefix} title="Remove the filter"
                class="btn btn-ghost text-error h-6 min-h-6 px-1">✕</button>
      </div>
    <% else %>
      <button type="button" phx-click="add_where" phx-value-action={@action_id} phx-value-path={@prefix}
              title="Narrow the selection to slots matching conditions, like using top" class="btn btn-outline h-6 min-h-6 px-2 self-start">+ where</button>
    <% end %>
    """
  end

  attr :name, :string, required: true
  attr :chosen, :list, required: true
  attr :sinner_options, :list, required: true
  attr :empty_label, :string, required: true

  def sinner_multi(assigns) do
    choices = Enum.filter(assigns.sinner_options, &(&1.profiled? or &1.id in assigns.chosen))
    assigns = assign(assigns, choices: choices, options_by_id: Map.new(assigns.sinner_options, &{&1.id, &1}))

    ~H"""
    <div class="dropdown min-w-28">
      <input type="hidden" name={@name} value={Enum.join(@chosen, ",")} />
      <div tabindex="0" role="button" title="Pick sinners"
           class="btn btn-outline btn-xs w-full min-w-0 flex-nowrap justify-start gap-0.5 px-1 font-normal overflow-hidden">
        <span :if={@chosen == []} class="truncate text-base-content/40"><%= @empty_label %></span>
        <%= for id <- @chosen do %>
            <% option = Map.get(@options_by_id, id, %{id: id, name: id, profiled?: false}) %>
            <img src={option[:thumb] || StarlightBot.SinnerProfiles.icon(id)} title={if(option.profiled?, do: option.name, else: "#{option.name} has no profile in this plan's lineups, so this never matches them")}
                 class={"h-5 w-auto rounded shrink-0 " <> if(option.profiled?, do: "", else: "ring-1 ring-warning")} />
        <% end %>
        <span class="ml-auto min-w-0 truncate pl-1 text-base-content/40">+ add</span>
      </div>
      <div tabindex="0" class="dropdown-content z-30 mt-1 w-48 rounded-lg border border-base-300 bg-base-100 p-1 shadow-lg">
        <div class="flex flex-col gap-0.5">
          <button :for={p <- @choices} type="button" data-value={p.id}
                  onclick="const i = this.closest('.dropdown').querySelector('input'); const v = this.dataset.value; const ids = i.value.split(',').filter(Boolean); const at = ids.indexOf(v); if (at >= 0) ids.splice(at, 1); else ids.push(v); i.value = ids.join(','); i.dispatchEvent(new Event('input', {bubbles: true}))"
                  class={"btn btn-xs h-auto min-h-7 w-full flex-nowrap justify-start gap-1.5 py-0.5 " <> if(p.id in @chosen, do: "btn-primary", else: "btn-ghost")}>
            <img src={p[:thumb] || StarlightBot.SinnerProfiles.icon(p.id)} class="h-6 w-auto rounded shrink-0" />
            <span class="truncate"><%= if p.profiled?, do: p.name, else: "⚠ " <> p.name %></span>
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :holder, :map, required: true
  attr :prefix, :string, required: true
  attr :action_id, :string, required: true
  attr :pin?, :boolean, default: false

  def chosen_picker(assigns) do
    filter = BattlePlans.normalize_chosen_filter(assigns.holder["where"] || BattlePlans.new_chosen_filter(assigns.pin?))
    assigns = assign(assigns, filter: filter, conditions: Enum.with_index(filter["conditions"]), kinds: BattlePlans.chosen_kinds(assigns.pin?))

    ~H"""
    <div class="flex flex-col items-start gap-1">
      <select :if={length(@conditions) > 1} name={field_name(@prefix, "where_join")} class="select select-bordered select-xs w-auto" title="Slots must meet all of the conditions, or any one of them">
        <option value="and" selected={@filter["join"] == "and"}>all of</option>
        <option value="or" selected={@filter["join"] == "or"}>any of</option>
      </select>
      <div :for={{condition, index} <- @conditions} class="flex flex-col gap-1 rounded border border-base-content/10 p-1">
        <div class="flex items-center gap-1">
          <input type="hidden" name={field_name(@prefix, "where_c") <> "[#{index}][not]"} value="false" />
          <label title="Negate this condition" class="relative cursor-pointer">
            <input type="checkbox" name={field_name(@prefix, "where_c") <> "[#{index}][not]"} value="true" checked={condition["not"] == true} class="peer sr-only" />
            <span class="inline-flex items-center justify-center h-6 w-6 rounded border border-dashed border-base-content/20 text-sm text-base-content/25 select-none peer-checked:hidden">≠</span>
            <span class="hidden items-center h-6 px-1.5 rounded bg-error text-[11px] font-semibold text-error-content select-none peer-checked:inline-flex">NOT</span>
          </label>
          <select name={field_name(@prefix, "where_c") <> "[#{index}][kind]"} class="select select-bordered select-xs w-auto">
            <option :for={{value, label} <- @kinds} value={value} selected={condition["kind"] == value}><%= label %></option>
          </select>
          <button :if={length(@conditions) > 1} type="button" phx-click="remove_chosen" phx-value-action={@action_id} phx-value-path={@prefix} phx-value-index={index}
                  class="btn btn-ghost text-error h-6 min-h-6 px-1">✕</button>
        </div>
        <.skill_chips :if={condition["kind"] in BattlePlans.chosen_value_kinds()} values={condition["values"] || []}
                      extras={if condition["kind"] == "using", do: BattlePlans.where_extras(), else: []}
                      name={field_name(@prefix, "where_c") <> "[#{index}][values][]"}
                      anchor={field_name(@prefix, "where_c") <> "[#{index}][edit]"}
                      id={"chips-where-#{@action_id}-#{@prefix}-#{index}"} />
      </div>
      <button type="button" phx-click="add_chosen" phx-value-action={@action_id} phx-value-path={@prefix} title="Add a condition" class="btn btn-outline h-6 min-h-6 px-2">+</button>
    </div>
    """
  end

  attr :values, :list, required: true
  attr :name, :string, required: true
  attr :anchor, :string, required: true
  attr :id, :string, required: true
  attr :extras, :list, default: []

  def skill_chips(assigns) do
    assigns = assign(assigns, unused: (BattlePlans.chip_values() ++ assigns.extras) -- assigns.values)

    ~H"""
    <div id={@id} phx-hook="PriorityChips" class="flex flex-col gap-1">
      <input type="hidden" name={@anchor} value="1" data-chip-anchor />
      <div data-chip-strip class="flex flex-wrap items-center gap-1 min-h-7 min-w-10 rounded border border-dashed border-base-content/25 p-0.5">
        <.priority_chip :for={value <- @values} value={value} name={@name} />
      </div>
      <div data-chip-palette class="grid grid-rows-2 grid-flow-col auto-cols-max justify-start gap-1 opacity-60 hover:opacity-100">
        <.priority_chip :for={value <- @unused} value={value} name={@name} disabled />
      </div>
    </div>
    """
  end

  attr :holder, :map, required: true
  attr :prefix, :string, required: true
  attr :select?, :boolean, default: true
  attr :owner, :string, default: nil

  def row_picker(assigns) do
    priority = assigns.holder["priority"]
    order = priority && priority["order"]

    assigns =
      assign(assigns,
        order: order,
        unused: BattlePlans.priority_values() -- (order || []),
        input_name: field_name(assigns.prefix, "priority_order") <> "[]",
        chips_id: "chips-#{assigns.owner}-#{assigns.prefix}"
      )

    ~H"""
    <select :if={@select?} name={field_name(@prefix, "row")} class="select select-bordered select-xs">
      <%= for row <- BattlePlans.rows() do %>
        <option value={row} selected={@holder["row"] == row}><%= row %></option>
      <% end %>
    </select>
    <%= if @holder["row"] == "priority" do %>
      <div id={@chips_id} phx-hook="PriorityChips" class="flex flex-col gap-1">
        <input type="hidden" name={field_name(@prefix, "priority_edit")} value="1" data-chip-anchor />
        <div data-chip-strip class="flex flex-wrap items-center gap-1 min-h-7 min-w-10 rounded border border-dashed border-base-content/25 p-0.5">
          <.priority_chip :for={value <- @order} value={value} name={@input_name} />
        </div>
        <div data-chip-palette class="grid grid-rows-2 grid-flow-col auto-cols-max justify-start gap-1 opacity-60 hover:opacity-100">
          <.priority_chip :for={value <- @unused} value={value} name={@input_name} disabled />
        </div>
      </div>
    <% end %>
    """
  end

  attr :value, :string, required: true
  attr :name, :string, required: true
  attr :disabled, :boolean, default: false
  attr :static, :boolean, default: false

  def priority_chip(assigns) do
    kind = chip_kind(assigns.value)
    [base | rest] = String.split(assigns.value, "+")

    assigns =
      assign(assigns,
        canon: Enum.find_index(BattlePlans.priority_values(), &(&1 == base)),
        kind: kind,
        tier: if(kind == :tier, do: base),
        sin: if(kind == :sin, do: base, else: List.first(rest))
      )

    ~H"""
    <span data-chip={!@static || nil} data-canon={@canon} data-tier={@tier} data-sin={@sin} draggable={!@static && "true"} title={@value}
          class={["inline-flex items-center justify-center min-w-6 px-1 rounded border select-none text-[11px] font-semibold", chip_class(@kind, @tier || @value), if(@static, do: ["h-5", if(@kind == :sin, do: "align-middle", else: "align-baseline")], else: "h-6 cursor-grab")]}>
      <input :if={!@static} type="hidden" name={@name} value={@value} disabled={@disabled} />
      <%= cond do %>
        <% @kind == :sin -> %>
          <img src={"/images/sin/#{@sin}.webp"} alt={@sin} class="size-4 pointer-events-none" draggable="false" />
        <% true -> %>
          <span class={@tier && "uppercase"}><%= @tier || @value %></span>
          <span :if={@sin} data-chip-sin class="ml-1 inline-flex rounded bg-base-200 p-px">
            <img src={"/images/sin/#{@sin}.webp"} alt={@sin} class="size-4 pointer-events-none" draggable="false" />
          </span>
      <% end %>
    </span>
    """
  end

  defp chip_kind(value) do
    cond do
      value in BattlePlans.sins() -> :sin
      value in BattlePlans.tiers() or String.contains?(value, "+") -> :tier
      true -> :other
    end
  end

  defp chip_class(:sin, _value), do: "border-base-content/20 bg-base-200"
  defp chip_class(:tier, "s3"), do: "border-primary/60 bg-primary/30"
  defp chip_class(:tier, "s2"), do: "border-primary/50 bg-primary/20"
  defp chip_class(:tier, _value), do: "border-primary/40 bg-primary/10"
  defp chip_class(:other, _value), do: "border-dashed border-base-content/40 bg-base-100"

  defp field_name("", field), do: field
  defp field_name(prefix, field), do: "#{prefix}[#{field}]"

  def hook_leaf(assigns) do
    ~H"""
    <input type="hidden" name="not" value="false" />
    <label title="Negate this condition" class="relative cursor-pointer">
      <input type="checkbox" name="not" value="true" checked={@node["not"] == true} class="peer sr-only" />
      <span class="inline-flex items-center justify-center h-6 w-6 rounded border border-dashed border-base-content/20 text-sm text-base-content/25 select-none peer-checked:hidden">≠</span>
      <span class="hidden items-center h-6 px-1.5 rounded bg-error text-[11px] font-semibold text-error-content select-none peer-checked:inline-flex">NOT</span>
    </label>
    <.radio_group name="op" value={@node["op"]} options={[{"tray_count", "tray slots"}, {"sinner_count", "sinner count"}, {"sinner_position", "sinner position"}, {"boss_fight", "boss"}, {"hook", "hook"}]} />
    <%= cond do %>
    <% BattlePlans.sinner_leaf?(@node) -> %>
      <.radio_group name="cmp" value={@node["cmp"]} options={[{"eq", "="}, {"gte", "≥"}, {"lte", "≤"}]} />
      <input type="number" name="value" min="1" value={@node["value"]} phx-debounce="300" class="input input-bordered input-xs w-16" />
    <% BattlePlans.tray_leaf?(@node) -> %>
      <.sinner_multi name="sinners_csv" chosen={@node["sinners"] || []} sinner_options={@sinner_options} empty_label="(anyone)" />
      <.skill_chips values={@node["matches"] || []} extras={BattlePlans.where_extras()} name="matches[]" anchor="matches_edit" id={"chips-cond-#{@values["action"]}-#{String.replace(@path, ~r/[^a-z0-9]+/i, "-")}"} />
      <.radio_group name="cmp" value={@node["cmp"]} options={[{"eq", "="}, {"gte", "≥"}, {"lte", "≤"}]} />
      <input type="number" name="value" min="0" value={@node["value"]} phx-debounce="300" class="input input-bordered input-xs w-16" />
    <% BattlePlans.fight_leaf?(@node) -> %>
    <% BattlePlans.position_leaf?(@node) -> %>
      <.sinner_multi name="sinners_csv" chosen={@node["sinners"] || []} sinner_options={@sinner_options} empty_label="(pick a sinner)" />
      <select name="pick" class="select select-bordered select-xs w-auto" title="Count positions from the first sinner or from the last">
        <option :for={pick <- ~w(first last)} value={pick} selected={@node["position"]["pick"] == pick}><%= pick_label(pick) %></option>
      </select>
      <.slot_chips skill={@node["position"]} prefix="" action_id={@values["action"]} path={@path} step_event="cond_step_chip" add_event="cond_add_chip" />
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
    |> assign(:renaming_playbook_id, nil)
    |> assign(:open_editor_id, nil)
    |> assign(:schedule_tabs, %{})
    |> assign(:reorder_rev, 0)
    |> assign(:paint, nil)
    |> assign(:extreme?, false)
  end

  defp load_plan(socket, id, template_id \\ nil) do
    case Plans.for_team(%{battle_plan_id: id, battle_template_id: template_id}, :battle_plans) do
      %{data: %{"version" => 4} = data} = plan ->
        first_playbook = List.first(data["playbooks"])

        socket
        |> assign(:editing_id, id)
        |> assign(:template_id, plan.template_id)
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
        put_flash(socket, :error, "Plan data is not version 4. Run mix db.migrate.")
    end
  end

  defp persist(%{assigns: %{template_id: template_id}} = socket) when is_integer(template_id), do: socket

  defp persist(socket) do
    attrs = %{id: socket.assigns.editing_id, name: socket.assigns.name, data: socket.assigns.data}

    case Plans.save(:battle_plans, attrs) do
      {:ok, _id} -> broadcast_count(socket, :battle_plans, socket.assigns.data)
      {:error, reason} -> put_flash(socket, :error, "Save failed: #{inspect(reason)}")
    end
  end

  defp assign_profiles(socket) do
    profiles = SinnerProfiles.list()

    socket
    |> assign(:profiles, profiles)
    |> assign(:profiles_by_id, Map.new(profiles, &{&1.id, &1}))
    |> assign(:profiles_by_sinner, Enum.group_by(profiles, & &1.sinner))
    |> assign(:locator_thumbs, Hooks.hook_thumbnails("locator"))
  end

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

  defp warn_unknown_hooks(socket, playbook) do
    case Enum.reject(BattlePlans.hook_names(playbook), &(&1 in socket.assigns.hook_names)) do
      [] -> socket
      unknown -> put_flash(socket, :error, "Unknown hooks in this playbook's conditions: #{Enum.join(unknown, ", ")}.")
    end
  end

  defp copy_playbook(source) do
    %{source | "id" => StarlightBot.GiftPlans.new_id("pb"), "name" => source["name"] <> " copy", "actions" => Enum.map(source["actions"], &BattlePlans.refresh_ids/1)}
  end

  defp update_playbook(socket, fun) do
    id = socket.assigns.playbook_id
    playbooks = Enum.map(socket.assigns.data["playbooks"], fn pb -> if pb["id"] == id, do: fun.(pb), else: pb end)
    socket |> assign(:data, Map.put(socket.assigns.data, "playbooks", playbooks)) |> persist()
  end

  defp update_items(socket, fun) do
    update_playbook(socket, fn playbook -> Map.update!(playbook, "actions", &BattlePlans.normalize_items(fun.(&1))) end)
  end

  defp update_action(socket, action_id, fun) do
    update_items(socket, fn items ->
      BattlePlans.update_list_containing(items, action_id, fn list -> Enum.map(list, &if(&1["id"] == action_id, do: fun.(&1), else: &1)) end)
    end)
  end

  defp put_schedule_tab(socket, schedule_id, from), do: update(socket, :schedule_tabs, &Map.put(&1, schedule_id, from))

  defp update_condition(socket, action_id, fun) do
    prune = &(&1 |> fun.() |> Conditions.prune())

    update_items(socket, fn items ->
      items
      |> BattlePlans.update_list_containing(action_id, fn list -> Enum.map(list, &if(&1["id"] == action_id, do: Map.update!(&1, "condition", prune), else: &1)) end)
      |> BattlePlans.update_elif_condition(action_id, prune)
    end)
  end

  defp apply_action_params(%{"type" => type} = action, params) when type in ~w(target ego dodge nothing), do: apply_holder(action, params, true)

  defp apply_action_params(%{"pins" => _} = action, params) do
    pins =
      (params["pins"] || %{})
      |> Enum.sort_by(fn {index, _} -> String.to_integer(index) end)
      |> Enum.zip(action["pins"])
      |> Enum.map(fn {{_index, params}, pin} -> apply_holder(pin, params, false) end)

    Map.put(action, "pins", pins)
  end

  defp apply_action_params(action, _params), do: action

  defp update_at_path(holder, [], fun), do: fun.(holder)

  defp update_at_path(holder, ["pins", index | tail], fun),
    do: Map.update!(holder, "pins", fn pins -> List.update_at(pins, String.to_integer(index), &update_at_path(&1, tail, fun)) end)

  defp update_at_path(holder, ["rest" | tail], fun), do: Map.update!(holder, "rest", &update_at_path(&1, tail, fun))

  defp apply_holder(holder, params, enemy?) do
    holder
    |> put_sinners(params)
    |> put_where(params)
    |> Map.put("skill", BattlePlans.parse_skill(params))
    |> apply_rule(params, enemy?)
  end

  defp apply_rule(holder, params, enemy?) do
    holder
    |> Map.put_new("type", "target")
    |> BattlePlans.convert_action(params["kind"])
    |> apply_rule_fields(params, enemy?)
    |> apply_rest(params, enemy?)
  end

  defp apply_rule_fields(%{"type" => "target"} = holder, params, enemy?) do
    holder
    |> BattlePlans.put_row(params["kind"] || params["row"], params["priority_order"])
    |> put_enemy(params, enemy?, "first")
    |> put_skip_bottom_target(params)
  end

  defp apply_rule_fields(%{"type" => "ego"} = holder, params, enemy?) do
    holder
    |> Map.put("grade", if(params["grade"] in BattlePlans.grades(), do: params["grade"], else: "zayin"))
    |> Map.put("corrode", params["corrode"] == "true")
    |> put_enemy(params, enemy?, "none")
    |> put_skip_bottom_target(params)
  end

  defp apply_rule_fields(%{"type" => "nothing"} = holder, _params, _enemy?), do: holder

  defp apply_rule_fields(%{"type" => "dodge"} = holder, params, enemy?) do
    holder
    |> Map.put("skip_bottom_target", params["skip_bottom_target"] != "false")
    |> put_enemy(params, enemy?, "none")
  end

  defp put_skip_bottom_target(holder, %{"skip_bottom_target" => value}), do: Map.put(holder, "skip_bottom_target", value == "true")
  defp put_skip_bottom_target(holder, _params), do: holder

  defp put_enemy(holder, _params, false, _default), do: holder

  defp put_enemy(holder, params, true, default) do
    pick = params["enemy_pick"] || default
    step = if get_in(holder, ["enemy", "pick"]) == pick, do: params["enemy_step"]

    Map.put(holder, "enemy", pick |> BattlePlans.parse_enemy(params["enemy_n"], step) |> BattlePlans.put_ignores(params["enemy_ignore"], params["enemy_ignore_add"]))
  end

  defp apply_rest(%{"rest" => rest} = holder, %{"rest" => rest_params}, enemy?), do: Map.put(holder, "rest", apply_holder(rest, rest_params, enemy?))
  defp apply_rest(holder, _params, _enemy?), do: holder

  defp pin_path?(params), do: String.starts_with?(params["path"] || "", "pins[")

  defp at_path(params, fun), do: &update_at_path(&1, String.split(params["path"] || "", ["[", "]"], trim: true), fun)

  defp put_where(holder, %{"where_c" => _} = params), do: Map.put(holder, "where", BattlePlans.parse_chosen_filter(params))
  defp put_where(holder, _params), do: holder

  defp put_sinners(holder, %{"who" => "everyone"}), do: holder |> Map.put("who", "everyone")
  defp put_sinners(holder, %{"who_mode" => "everyone"}), do: holder |> Map.put("who", "everyone")

  defp put_sinners(holder, params) do
    kept =
      cond do
        is_binary(params["sinners_csv"]) -> String.split(params["sinners_csv"], ",", trim: true)
        holder["who"] == "everyone" -> holder["sinners"] || []
        true -> params["sinners"] || []
      end

    sinners =
      (kept ++ [params["add_sinner"]])
      |> Enum.filter(&(&1 in SinnerProfiles.sinners()))
      |> Enum.uniq()

    holder
    |> Map.put("who", if(params["who"] in ["except", "after", "before"], do: params["who"], else: "only"))
    |> Map.put("sinners", sinners)
  end

  defp parse_ids(str) when is_binary(str), do: str |> String.split(",", trim: true) |> Enum.flat_map(&List.wrap(parse_id(&1)))
  defp parse_ids(_), do: []

  defp parse_id(nil), do: nil
  defp parse_id(""), do: nil

  defp parse_id(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end
end
