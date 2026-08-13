defmodule StarlightBot.Navigation.Catalog do
  @moduledoc """
  Registry of all known screens and transitions.
  Provides BFS path planning between any two screens.
  """

  alias StarlightBot.Navigation.{Screen, Transition}

  @doc """
  Order matters. Screens at the top will be detected before screens at the bottom.
  In scenarios where both screens might match, put the one we can actually work with
  above.

  The :refines property can be used to specify a screen as a subscreen as another, but that
  implies that we want to inherit all navigation from the parent screen, which isn't always the case.
  """
  @screen_modules [
    StarlightBot.Navigation.Screens.EgoGiftGet,
    StarlightBot.Navigation.Screens.Enkephalin,
    StarlightBot.Navigation.Screens.TeamSelect,
    StarlightBot.Navigation.Screens.CabinetEgoGifts,
    StarlightBot.Navigation.Screens.GiftSearch,
    StarlightBot.Navigation.Screens.ThemePack,
    StarlightBot.Navigation.Screens.DungeonGraph,
    StarlightBot.Navigation.Screens.Event,
    StarlightBot.Navigation.Screens.Shop,
    StarlightBot.Navigation.Screens.Home,
    StarlightBot.Navigation.Screens.ExplorationReward,
    StarlightBot.Navigation.Screens.Battle,
    StarlightBot.Navigation.Screens.SeasonPass,
    StarlightBot.Navigation.Screens.MdDoor,
    StarlightBot.Navigation.Screens.Lux,
    StarlightBot.Navigation.Screens.BackAvailable,
    StarlightBot.Navigation.Screens.Grace,
  ]

  def all_screens(screen_modules \\ @screen_modules) do
    Enum.flat_map(screen_modules, & &1.__nav_screens__())
  end

  def all_transitions(screen_modules \\ @screen_modules) do
    Enum.flat_map(screen_modules, & &1.__nav_transitions__())
  end

  def all_actions(screen_modules \\ @screen_modules) do
    Enum.flat_map(screen_modules, & &1.__nav_actions__())
  end

  def find_screen(name, screen_modules \\ @screen_modules) do
    Enum.find(all_screens(screen_modules), &(&1.name == name))
  end

  def transitions_from(screen_name, screen_modules \\ @screen_modules) do
    inherited_via_refines(screen_name, screen_modules, fn name ->
      all_transitions(screen_modules) |> Enum.filter(&(&1.from == name))
    end)
  end

  def actions_for(screen_name, screen_modules \\ @screen_modules) do
    inherited_via_refines(screen_name, screen_modules, fn name ->
      all_actions(screen_modules) |> Enum.filter(&(&1.screen == name))
    end)
  end

  def find_action(screen_name, action_name, screen_modules \\ @screen_modules) do
    Enum.find(actions_for(screen_name, screen_modules), &(&1.name == action_name))
  end

  def find_transition(screen_name, transition_name, screen_modules \\ @screen_modules) do
    Enum.find(transitions_from(screen_name, screen_modules), &(&1.name == transition_name))
  end

  defp inherited_via_refines(screen_name, screen_modules, own_fun),
    do: inherited_via_refines(screen_name, MapSet.new(), screen_modules, own_fun)

  defp inherited_via_refines(screen_name, visited, screen_modules, own_fun) do
    if MapSet.member?(visited, screen_name) do
      []
    else
      own = own_fun.(screen_name)

      case find_screen(screen_name, screen_modules) do
        %Screen{refines: parent} when not is_nil(parent) ->
          own ++ inherited_via_refines(parent, MapSet.put(visited, screen_name), screen_modules, own_fun)

        _ ->
          own
      end
    end
  end

  def refinements_of(screen_name, screen_modules \\ @screen_modules),
    do: refinements_of(screen_name, MapSet.new(), screen_modules)

  defp refinements_of(screen_name, visited, screen_modules) do
    if MapSet.member?(visited, screen_name) do
      []
    else
      visited = MapSet.put(visited, screen_name)

      all_screens(screen_modules)
      |> Enum.filter(&(&1.refines == screen_name))
      |> Enum.flat_map(fn s -> [s | refinements_of(s.name, visited, screen_modules)] end)
    end
  end

  def plan_path(from, to, screen_modules \\ @screen_modules)
  def plan_path(from, to, _screen_modules) when from == to, do: {:ok, []}

  def plan_path(from, to, screen_modules) do
    bfs([[from]], to, MapSet.new([from]), graph(screen_modules))
  end

  defp bfs([], _goal, _visited, _graph), do: {:error, :no_path}

  defp bfs([path | rest_queue], goal, visited, graph) do
    current = List.last(path)
    neighbors = Map.get(graph, current, [])

    # Check if goal is directly reachable from current
    case Enum.find(neighbors, &(&1.to == goal)) do
      %Transition{} ->
        full_path = path ++ [goal]
        {:ok, path_to_transitions(full_path, graph)}

      nil ->
        {new_queue, new_visited} =
          Enum.reduce(neighbors, {rest_queue, visited}, fn t, {q, v} ->
            if MapSet.member?(v, t.to) do
              {q, v}
            else
              {q ++ [path ++ [t.to]], MapSet.put(v, t.to)}
            end
          end)

        bfs(new_queue, goal, new_visited, graph)
    end
  end

  defp path_to_transitions([_single], _graph), do: []

  defp path_to_transitions([from | [to | _] = rest], graph) do
    t = graph |> Map.get(from, []) |> Enum.find(&(&1.to == to))
    [t | path_to_transitions(rest, graph)]
  end

  def reachable_from(from, screen_modules \\ @screen_modules) do
    bfs_reachable([{from, 0}], MapSet.new([from]), graph(screen_modules), [])
  end

  defp graph(screen_modules) do
    Map.new(all_screens(screen_modules), fn screen ->
      {screen.name,
       transitions_from(screen.name, screen_modules) ++
         unknown_bridge_edge(screen.name, screen_modules) ++ parent_bridge_edge(screen)}
    end)
  end

  defp unknown_bridge_edge(screen_name, screen_modules) do
    case Enum.find(all_screens(screen_modules), &(&1.refines == screen_name and is_nil(&1.identity_hook))) do
      nil -> []
      unknown -> [%Transition{from: screen_name, to: unknown.name, name: unknown.name, steps: []}]
    end
  end

  defp parent_bridge_edge(%Screen{refines: nil}), do: []

  defp parent_bridge_edge(%Screen{name: name, refines: parent}) do
    [%Transition{from: name, to: parent, name: parent, steps: []}]
  end

  defp bfs_reachable([], _visited, _graph, acc), do: Enum.reverse(acc)

  defp bfs_reachable([{current, hops} | rest], visited, graph, acc) do
    neighbors = Map.get(graph, current, [])

    {new_queue, new_visited, new_acc} =
      Enum.reduce(neighbors, {rest, visited, acc}, fn t, {q, v, a} ->
        if MapSet.member?(v, t.to) do
          {q, v, a}
        else
          {q ++ [{t.to, hops + 1}], MapSet.put(v, t.to), [{t.to, hops + 1} | a]}
        end
      end)

    bfs_reachable(new_queue, new_visited, graph, new_acc)
  end
end
