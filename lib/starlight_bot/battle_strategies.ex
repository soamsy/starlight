defmodule StarlightBot.BattleStrategies do
  alias StarlightBot.BattleStrategies.Resolver
  alias StarlightBot.GiftPlans

  @tracks ~w(normal_chain normal_focused hard_chain hard_focused lux_chain lux_focused)
  @max_floor 15
  @chain_actions ~w(chain_fast chain_a_res)
  @common_actions ~w(win_rate commit clear dodge ego)
  @skill_picks ~w(first last exact up_to)
  @grades ~w(zayin teth he waw)

  def tracks, do: @tracks
  def max_floor, do: @max_floor
  def skill_picks, do: @skill_picks
  def grades, do: @grades

  def lux_track?(track), do: String.starts_with?(track, "lux_")

  def track_kind(track) do
    if String.ends_with?(track, "_chain"), do: "chain", else: "focused"
  end

  def action_types("chain"), do: @common_actions ++ @chain_actions
  def action_types("focused"), do: @common_actions

  def chain_action?(type), do: type in @chain_actions

  def blank do
    chain = new_playbook("chain", "Chain fast")
    focused = new_playbook("focused", "Win rate")

    %{
      "version" => 3,
      "playbooks" => [chain, focused],
      "tracks" =>
        Map.new(@tracks, fn track ->
          playbook = if track_kind(track) == "chain", do: chain, else: focused
          {track, [%{"from_floor" => 1, "playbook" => playbook["id"]}]}
        end)
    }
  end

  def new_playbook(kind, name) do
    %{
      "id" => GiftPlans.new_id("pb"),
      "name" => name,
      "kind" => kind,
      "phases" => [%{"from_turn" => 1, "actions" => default_actions(kind)}]
    }
  end

  defp default_actions("chain"), do: [new_action("chain_fast")]
  defp default_actions("focused"), do: [new_action("win_rate"), new_action("commit")]

  def new_action(type) when type in ~w(win_rate commit clear), do: %{"id" => GiftPlans.new_id("ac"), "type" => type}

  def new_action("dodge"),
    do: %{"id" => GiftPlans.new_id("ac"), "type" => "dodge", "profile_id" => nil, "skill" => %{"pick" => "first"}}

  def new_action("ego") do
    %{
      "id" => GiftPlans.new_id("ac"),
      "type" => "ego",
      "profile_id" => nil,
      "skill" => %{"pick" => "first"},
      "grade" => "zayin",
      "corrode" => false
    }
  end

  def new_action(type) when type in @chain_actions, do: %{"id" => GiftPlans.new_id("ac"), "type" => type, "pins" => []}

  def new_pin, do: %{"profile_id" => nil, "skill" => %{"pick" => "first"}, "row" => "bottom"}

  def paint(entries, floor, playbook_id) do
    entries
    |> Enum.reject(&(&1["from_floor"] == floor))
    |> Kernel.++([%{"from_floor" => floor, "playbook" => playbook_id}])
    |> normalize_track()
  end

  def erase(entries, 1), do: entries

  def erase(entries, floor) do
    entries
    |> Enum.reject(&(&1["from_floor"] == floor))
    |> normalize_track()
  end

  def normalize_track(entries) do
    entries
    |> Enum.sort_by(& &1["from_floor"])
    |> Enum.dedup_by(& &1["playbook"])
  end

  def split_phase(playbook, turn) when turn > 1 do
    if Enum.any?(playbook["phases"], &(&1["from_turn"] == turn)) do
      playbook
    else
      source = Resolver.phase_for(playbook, turn)
      actions = Enum.map(source["actions"], &Map.put(&1, "id", GiftPlans.new_id("ac")))
      phases = Enum.sort_by(playbook["phases"] ++ [%{"from_turn" => turn, "actions" => actions}], & &1["from_turn"])
      Map.put(playbook, "phases", phases)
    end
  end

  def remove_phase(playbook, 1), do: playbook

  def remove_phase(playbook, turn) do
    Map.update!(playbook, "phases", fn phases -> Enum.reject(phases, &(&1["from_turn"] == turn)) end)
  end

  def tracks_using(data, playbook_id) do
    Enum.filter(@tracks, fn track ->
      Enum.any?(get_in(data, ["tracks", track]) || [], &(&1["playbook"] == playbook_id))
    end)
  end

  def profile_ids_used(data) do
    for playbook <- data["playbooks"] || [],
        phase <- playbook["phases"],
        action <- phase["actions"],
        id <- [action["profile_id"] | Enum.map(action["pins"] || [], & &1["profile_id"])],
        is_integer(id),
        into: MapSet.new(),
        do: id
  end
end
