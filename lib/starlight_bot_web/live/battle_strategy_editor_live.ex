defmodule StarlightBotWeb.Live.BattleStrategyEditorLive do
  use StarlightBotWeb, :live_view

  alias StarlightBot.{BattleStrategies, Hooks, SinnerProfiles, Strategies}
  alias StarlightBot.BattleStrategies.Resolver
  alias StarlightBot.Vision.{Capture, Matcher, SkillTray}

  @collapsed_floors 5

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:tab, "strategies")
     |> assign(:strategies, Strategies.list(:battle_strategies))
     |> assign(:hook_names, Enum.map(Hooks.list_hooks(), & &1.name))
     |> assign(:profile_tests, %{})
     |> assign_profiles()
     |> reset_editor()}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Integer.parse(id) do
      {int_id, _} -> {:noreply, load_strategy(socket, int_id)}
      :error -> {:noreply, socket}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) when tab in ~w(strategies profiles) do
    {:noreply, assign(socket, :tab, tab)}
  end

  @impl true
  def handle_event("new_strategy", _, socket) do
    attrs = %{name: "New Strategy #{length(socket.assigns.strategies) + 1}", data: BattleStrategies.blank()}

    case Strategies.save(:battle_strategies, attrs) do
      {:ok, id} -> {:noreply, socket |> assign(:strategies, Strategies.list(:battle_strategies)) |> load_strategy(id)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("select_strategy", %{"id" => id}, socket) do
    {:noreply, load_strategy(socket, String.to_integer(id))}
  end

  @impl true
  def handle_event("delete_strategy", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Strategies.delete(:battle_strategies, id) do
      {:ok, _} ->
        socket = if socket.assigns.editing_id == id, do: reset_editor(socket), else: socket

        {:noreply,
         socket
         |> assign(:strategies, Strategies.list(:battle_strategies))
         |> assign_profiles()
         |> put_flash(:info, "Strategy deleted.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("rename_strategy", %{"value" => name}, socket) do
    case String.trim(name) do
      "" -> {:noreply, socket}
      name -> {:noreply, socket |> assign(:name, name) |> persist()}
    end
  end

  @impl true
  def handle_event("toggle_extreme", _, socket) do
    {:noreply, update(socket, :extreme?, &(not &1))}
  end

  @impl true
  def handle_event("set_paint", %{"id" => id}, socket) do
    {:noreply, assign(socket, :paint, id)}
  end

  @impl true
  def handle_event("paint_cell", %{"track" => track, "floor" => floor}, socket) do
    floor = String.to_integer(floor)
    paint = socket.assigns.paint
    entries = socket.assigns.data["tracks"][track]

    cond do
      paint == "erase" ->
        {:noreply, put_track(socket, track, BattleStrategies.erase(entries, floor))}

      playbook = find_playbook(socket.assigns.data, paint) ->
        if playbook["kind"] == BattleStrategies.track_kind(track) do
          {:noreply, put_track(socket, track, BattleStrategies.paint(entries, floor, paint))}
        else
          {:noreply, put_flash(socket, :error, "'#{playbook["name"]}' is a #{playbook["kind"]} playbook; it can't go on a #{BattleStrategies.track_kind(track)} track.")}
        end

      true ->
        {:noreply, put_flash(socket, :error, "Pick a playbook to paint with first.")}
    end
  end

  @impl true
  def handle_event("select_playbook", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:playbook_id, id) |> assign(:paint, id)}
  end

  @impl true
  def handle_event("new_playbook", %{"kind" => kind}, socket) when kind in ~w(chain focused) do
    count = Enum.count(socket.assigns.data["playbooks"], &(&1["kind"] == kind))
    playbook = BattleStrategies.new_playbook(kind, "#{String.capitalize(kind)} #{count + 1}")
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
    case BattleStrategies.tracks_using(socket.assigns.data, id) do
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
    {:noreply, update_playbook(socket, &BattleStrategies.split_phase(&1, String.to_integer(turn)))}
  end

  @impl true
  def handle_event("remove_phase", %{"turn" => turn}, socket) do
    {:noreply, update_playbook(socket, &BattleStrategies.remove_phase(&1, String.to_integer(turn)))}
  end

  @impl true
  def handle_event("add_action", %{"turn" => turn, "type" => type}, socket) when type != "" do
    {:noreply,
     update_phase(socket, String.to_integer(turn), fn actions ->
       if BattleStrategies.chain_action?(type) and Enum.any?(actions, &BattleStrategies.chain_action?(&1["type"])) do
         actions
       else
         actions ++ [BattleStrategies.new_action(type)]
       end
     end)}
  end

  @impl true
  def handle_event("add_action", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("move_action", %{"turn" => turn, "action" => action_id, "dir" => dir}, socket) do
    offset = if dir == "up", do: -1, else: 1

    {:noreply,
     update_phase(socket, String.to_integer(turn), fn actions ->
       index = Enum.find_index(actions, &(&1["id"] == action_id))
       target = index + offset

       if target < 0 or target >= length(actions) do
         actions
       else
         actions |> List.delete_at(index) |> List.insert_at(target, Enum.at(actions, index))
       end
     end)}
  end

  @impl true
  def handle_event("remove_action", %{"turn" => turn, "action" => action_id}, socket) do
    {:noreply, update_phase(socket, String.to_integer(turn), fn actions -> Enum.reject(actions, &(&1["id"] == action_id)) end)}
  end

  @impl true
  def handle_event("update_action", %{"turn" => turn, "action" => action_id} = params, socket) do
    {:noreply, update_action(socket, String.to_integer(turn), action_id, &apply_action_params(&1, params))}
  end

  @impl true
  def handle_event("add_pin", %{"turn" => turn, "action" => action_id}, socket) do
    {:noreply, update_action(socket, String.to_integer(turn), action_id, &Map.update!(&1, "pins", fn pins -> pins ++ [BattleStrategies.new_pin()] end))}
  end

  @impl true
  def handle_event("remove_pin", %{"turn" => turn, "action" => action_id, "index" => index}, socket) do
    index = String.to_integer(index)
    {:noreply, update_action(socket, String.to_integer(turn), action_id, &Map.update!(&1, "pins", fn pins -> List.delete_at(pins, index) end))}
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


  def floors(true), do: Enum.to_list(1..BattleStrategies.max_floor())
  def floors(false), do: Enum.to_list(1..@collapsed_floors)

  def track_label("normal_chain"), do: "Normal Chain"
  def track_label("normal_focused"), do: "Normal Focused"
  def track_label("hard_chain"), do: "Hard Chain"
  def track_label("hard_focused"), do: "Hard Focused"
  def track_label("lux_chain"), do: "Lux Chain"
  def track_label("lux_focused"), do: "Lux Focused"

  def action_label("win_rate"), do: "Win rate (p)"
  def action_label("commit"), do: "Commit (enter)"
  def action_label("clear"), do: "Unchoose all"
  def action_label("dodge"), do: "Dodge"
  def action_label("ego"), do: "EGO"
  def action_label("chain_fast"), do: "Chain fast (no S3)"
  def action_label("chain_a_res"), do: "Chain A-Res"

  def action_tooltip("win_rate"), do: "Press p so Limbus assigns every choice for the best win rate."
  def action_tooltip("commit"), do: "Press enter to start the turn once every skill is chosen."
  def action_tooltip("clear"), do: "Press p until battle_combat_ready stops matching."
  def action_tooltip("dodge"), do: "Click below the chosen skill slot to swap it to dodge."
  def action_tooltip("ego"), do: "Hold below the chosen skill slot to open the EGO menu, then pick the grade's card."
  def action_tooltip("chain_fast"), do: "Chain without S3, which takes too long to animate. Prefers S2, then S1."
  def action_tooltip("chain_a_res"), do: "Chain for the longest same-sin streaks to maximize clash power."

  def pick_label("first"), do: "first"
  def pick_label("last"), do: "last"
  def pick_label("exact"), do: "exactly #"
  def pick_label("up_to"), do: "up to #"
  def pick_label("all"), do: "all"

  def skill_picks(pins?), do: BattleStrategies.skill_picks() ++ if(pins?, do: ["all"], else: [])

  def numbered_pick?(%{"pick" => pick}), do: pick in ~w(exact up_to)

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
    has_chain? = Enum.any?(actions, &BattleStrategies.chain_action?(&1["type"]))
    Enum.reject(BattleStrategies.action_types(playbook["kind"]), &(has_chain? and BattleStrategies.chain_action?(&1)))
  end

  def ends_with_chain?(actions), do: actions != [] and BattleStrategies.chain_action?(List.last(actions)["type"])

  def find_playbook(data, id), do: Enum.find(data["playbooks"], &(&1["id"] == id))


  defp reset_editor(socket) do
    socket
    |> assign(:editing_id, nil)
    |> assign(:name, "")
    |> assign(:data, nil)
    |> assign(:playbook_id, nil)
    |> assign(:paint, nil)
    |> assign(:extreme?, false)
  end

  defp load_strategy(socket, id) do
    case Strategies.get(:battle_strategies, id) do
      %{data: %{"version" => 3} = data} = strategy ->
        first_playbook = List.first(data["playbooks"])

        socket
        |> assign(:editing_id, strategy.id)
        |> assign(:name, strategy.name)
        |> assign(:data, data)
        |> assign(:playbook_id, first_playbook["id"])
        |> assign(:paint, first_playbook["id"])
        |> assign(:extreme?, Enum.any?(Map.values(data["tracks"]), &hidden_change_points?/1))

      nil ->
        put_flash(socket, :error, "Strategy not found.")

      _ ->
        put_flash(socket, :error, "Strategy data is not version 3. Run mix db.migrate.")
    end
  end

  defp persist(socket) do
    attrs = %{id: socket.assigns.editing_id, name: socket.assigns.name, data: socket.assigns.data}

    case Strategies.save(:battle_strategies, attrs) do
      {:ok, _id} -> socket |> assign(:strategies, Strategies.list(:battle_strategies)) |> assign_profiles()
      {:error, reason} -> put_flash(socket, :error, "Save failed: #{inspect(reason)}")
    end
  end

  defp assign_profiles(socket) do
    profiles = SinnerProfiles.list()

    usage =
      socket.assigns.strategies
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

  defp put_track(socket, track, entries) do
    socket |> assign(:data, put_in(socket.assigns.data, ["tracks", track], entries)) |> persist()
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
        Map.update!(phase, "actions", fn actions -> Enum.map(actions, &Map.put(&1, "id", StarlightBot.GiftPlans.new_id("ac"))) end)
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
          if phase["from_turn"] == turn, do: Map.update!(phase, "actions", &chain_last(fun.(&1))), else: phase
        end)
      end)
    end)
  end

  defp update_action(socket, turn, action_id, fun) do
    update_phase(socket, turn, fn actions -> Enum.map(actions, &if(&1["id"] == action_id, do: fun.(&1), else: &1)) end)
  end

  defp chain_last(actions) do
    {chain, other} = Enum.split_with(actions, &BattleStrategies.chain_action?(&1["type"]))
    other ++ chain
  end

  defp apply_action_params(%{"type" => type} = action, params) when type in ~w(dodge ego) do
    action
    |> Map.put("profile_id", parse_id(params["profile_id"]))
    |> Map.put("skill", parse_skill(params["pick"], params["n"]))
    |> then(fn action ->
      if type == "ego" do
        action
        |> Map.put("grade", if(params["grade"] in BattleStrategies.grades(), do: params["grade"], else: "zayin"))
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
      |> Enum.map(fn {_index, pin} ->
        %{
          "profile_id" => parse_id(pin["profile_id"]),
          "skill" => parse_skill(pin["pick"], pin["n"]),
          "row" => if(pin["row"] == "top", do: "top", else: "bottom")
        }
      end)

    Map.put(action, "pins", pins)
  end

  defp apply_action_params(action, _params), do: action

  defp parse_skill(pick, n) when pick in ~w(exact up_to), do: %{"pick" => pick, "n" => max(parse_id(n) || 1, 1)}
  defp parse_skill(pick, _n) when pick in ~w(first last all), do: %{"pick" => pick}
  defp parse_skill(_pick, _n), do: %{"pick" => "first"}

  defp parse_id(nil), do: nil
  defp parse_id(""), do: nil

  defp parse_id(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
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
