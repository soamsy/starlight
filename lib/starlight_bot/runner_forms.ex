defmodule StarlightBot.RunnerForms do
  import Ecto.Query
  alias StarlightBot.{Repo, Teams}
  alias StarlightBot.Automation.EnkephalinCharger

  @topic "runner_forms"
  @runners ~w(mirror_dungeon luxcavation)
  @max_lux_consecutive 10

  def subscribe, do: Phoenix.PubSub.subscribe(StarlightBot.PubSub, @topic)

  def max_lux_consecutive, do: @max_lux_consecutive

  def get(runner) when runner in @runners do
    case Repo.one(from f in "runner_forms", where: f.runner == ^runner, select: f.params) do
      nil -> nil
      json -> Jason.decode!(json)
    end
  end

  def put(runner, params) when runner in @runners and is_map(params) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all("runner_forms", [%{runner: runner, params: Jason.encode!(params), updated_at: now}],
      on_conflict: {:replace, [:params, :updated_at]},
      conflict_target: :runner
    )

    Phoenix.PubSub.broadcast(StarlightBot.PubSub, @topic, {:runner_form, runner})
    :ok
  end

  def schedulable_teams, do: Teams.list_teams() |> Enum.reject(&(&1.hooks == []))

  def mirror_dungeon_action do
    with %{} = params <- get("mirror_dungeon"),
         {:ok, action} <- mirror_dungeon_action(params, schedulable_teams()) do
      action
    else
      _ -> nil
    end
  end

  def luxcavation_action do
    with %{} = params <- get("luxcavation"),
         {:ok, action} <- luxcavation_action(params) do
      action
    else
      _ -> nil
    end
  end

  def mirror_dungeon_action(params, teams) do
    picks = parse_team_picks(params["team_ids"], params["team_hooks"], teams)
    start = parse_start_index(params["start_index"], picks)
    picks = Enum.drop(picks, start) ++ Enum.take(picks, start)

    with [_ | _] <- picks,
         {run_count, ""} <- Integer.parse(to_string(params["run_count"])),
         true <- run_count >= 0,
         {convert_count, ""} <- Integer.parse(to_string(params["enkephalin_convert_count"] || "0")),
         true <- convert_count in 0..EnkephalinCharger.max_convert_count() do
      config = %{
        weekly_bonus?: Map.get(params, "weekly_bonus") == "true",
        collect_enkephalin?: Map.get(params, "collect_enkephalin") == "true",
        collect_xp?: Map.get(params, "collect_xp") == "true",
        capture_ego_gifts?: Map.get(params, "capture_ego_gifts") == "true",
        enkephalin_convert_count: convert_count
      }

      {:ok, {:run_mirror_dungeon, picks, run_count, config}}
    else
      _ -> :error
    end
  end

  def advance_mirror_dungeon_start do
    with %{"team_ids" => [_ | _] = ids} = params <- get("mirror_dungeon") do
      start = parse_start_index(params["start_index"], ids)
      put("mirror_dungeon", Map.put(params, "start_index", to_string(rem(start + 1, length(ids)))))
    end
  end

  def luxcavation_action(params) do
    with {team_id, ""} <- Integer.parse(to_string(params["team_id"])),
         {exp_consecutive, ""} <- Integer.parse(to_string(params["exp_consecutive"])),
         {exp_repeats, ""} <- Integer.parse(to_string(params["exp_repeats"])),
         {thread_consecutive, ""} <- Integer.parse(to_string(params["thread_consecutive"])),
         {thread_repeats, ""} <- Integer.parse(to_string(params["thread_repeats"])),
         {enkephalin_convert_count, ""} <- Integer.parse(to_string(params["enkephalin_convert_count"] || "0")),
         true <- exp_consecutive in 0..@max_lux_consecutive and thread_consecutive in 0..@max_lux_consecutive,
         true <- exp_repeats >= 0 and thread_repeats >= 0,
         true <- enkephalin_convert_count in 0..4 do
      {:ok,
       {:run_luxcavation, %{id: team_id, hook: blank_to_nil(params["team_hook"])}, exp_consecutive, exp_repeats, thread_consecutive, thread_repeats,
        Map.get(params, "collect_xp") == "true", Map.get(params, "collect_enkephalin") == "true", enkephalin_convert_count}}
    else
      _ -> :error
    end
  end

  def parse_start_index(value, team_ids) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n >= 0 and n < length(team_ids) -> n
      _ -> 0
    end
  end

  def parse_team_picks(ids, hooks, teams, fallback \\ []) do
    ids = List.wrap(ids)
    hooks = List.wrap(hooks) ++ List.duplicate(nil, length(ids))

    ids
    |> Enum.zip(hooks)
    |> Enum.flat_map(fn {value, hook} ->
      with {id, ""} <- Integer.parse(to_string(value)),
           %{} = team <- Enum.find(teams, &(&1.id == id)) do
        [%{id: id, hook: Teams.pick_hook(team, hook)}]
      else
        _ -> []
      end
    end)
    |> case do
      [] -> fallback
      picks -> picks
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
