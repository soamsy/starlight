defmodule StarlightBot.Navigation.CatalogTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Navigation.Catalog
  alias StarlightBot.Navigation.Transition

  test "every transition and action builds a step list that holds no closures" do
    steps = Enum.flat_map(Catalog.all_transitions() ++ Catalog.all_actions(), & &1.steps)

    assert steps != []
    refute Enum.any?(steps, &contains_function?/1)
  end

  defp contains_function?(term) when is_function(term), do: true
  defp contains_function?(term) when is_tuple(term), do: term |> Tuple.to_list() |> Enum.any?(&contains_function?/1)
  defp contains_function?(term) when is_list(term), do: Enum.any?(term, &contains_function?/1)
  defp contains_function?(_term), do: false

  describe "plan_path/2" do
    test "same screen requires no hops" do
      assert Catalog.plan_path(:home, :home) == {:ok, []}
    end

    test "a direct transition is a single hop" do
      assert {:ok, [%Transition{from: :home_window, to: :home_drive}]} =
               Catalog.plan_path(:home_window, :home_drive)
    end

    test "a refinement inherits its parent's transitions" do
      assert {:ok, [%Transition{from: :home, to: :charge_enkephalin}]} =
               Catalog.plan_path(:home_drive, :charge_enkephalin)
    end

    test "routes through the unknown-refinement bridge when no direct edge exists" do
      assert {:ok, [bridge, last_hop]} = Catalog.plan_path(:home, :home_window)
      assert bridge == %Transition{from: :home, to: :home_unknown, name: :home_unknown, steps: []}
      assert last_hop.to == :home_window
    end

    test "routes through the parent bridge when going from a refinement to its parent" do
      assert Catalog.plan_path(:home_drive, :home) ==
               {:ok, [%Transition{from: :home_drive, to: :home, name: :home, steps: []}]}
    end

    test "returns :no_path for an unreachable or nonexistent screen" do
      assert Catalog.plan_path(:home, :this_screen_does_not_exist) == {:error, :no_path}
    end

    test "a refinement's own transition to the same target wins over the inherited one" do
      assert {:ok, [%Transition{from: :battle_chain, to: :battle_playing, steps: [{:call, {_, :play_chain_turn, []}} | _]}]} =
               Catalog.plan_path(:battle_chain, :battle_playing)

      assert {:ok, [%Transition{from: :battle_focused, to: :battle_playing, steps: [{:call, {_, :play_focused_turn, []}} | _]}]} =
               Catalog.plan_path(:battle_focused, :battle_playing)

      assert {:ok, [%Transition{from: :battle_turn, to: :battle_playing, steps: [{:branch, _, [{:key, :p} | _], _}]}]} =
               Catalog.plan_path(:battle_turn, :battle_playing)
    end
  end

  describe "giving up and defeat" do
    test "any turn screen can leave the battle through the settings popup" do
      assert {:ok, [%Transition{from: :battle, to: :battle_settings_popup}, %Transition{from: :battle_settings_popup, to: :battle_given_up}]} =
               Catalog.plan_path(:battle_chain, :battle_given_up)
    end

    test "any turn screen can retry the battle through the settings popup" do
      assert {:ok, [%Transition{from: :battle, to: :battle_settings_popup}, %Transition{from: :battle_settings_popup, to: :battle_retried}]} =
               Catalog.plan_path(:battle_focused, :battle_retried)
    end

    test "the dungeon graph reaches the window through the dungeon progress popup" do
      assert {:ok, [%Transition{from: :dungeon_graph, to: :dungeon_progress}, %Transition{from: :dungeon_progress, to: :dungeon_given_up}]} =
               Catalog.plan_path(:dungeon_graph, :dungeon_given_up)
    end

    test "the defeat screen is its own battle screen that leaves through retry or stage select" do
      assert %{refines: nil, identity_hook: :battle_defeat_retry} = Catalog.find_screen(:battle_defeat)
      assert StarlightBot.Automation.Engine.in_battle?(:battle_defeat)
      assert {:ok, [%Transition{from: :battle_defeat, to: :battle_retried}]} = Catalog.plan_path(:battle_defeat, :battle_retried)
      assert {:ok, [%Transition{from: :battle_defeat, to: :battle_given_up}]} = Catalog.plan_path(:battle_defeat, :battle_given_up)
    end
  end

  describe "refinements_of/1" do
    test "returns the direct refinements of a screen" do
      names = Catalog.refinements_of(:home) |> Enum.map(& &1.name) |> Enum.sort()
      assert names == [:home_dispense, :home_drive, :home_extract, :home_sinners, :home_theater, :home_unknown, :home_window]
    end

    test "a screen with no refinements returns an empty list" do
      assert Catalog.refinements_of(:home_drive) == []
    end

    test "recurses through a refines chain deeper than one level" do
      modules = StarlightBot.Test.NavFixtureScreens.screen_modules()

      names =
        Catalog.refinements_of(:fixture_root, modules)
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert names == [:fixture_child, :fixture_grandchild]
    end
  end

  describe "actions_for/1 and find_action/2" do
    test "returns actions declared directly on a screen" do
      modules = StarlightBot.Test.NavFixtureScreens.screen_modules()

      assert [%StarlightBot.Navigation.Action{screen: :fixture_root, name: :fixture_root_action}] =
               Catalog.actions_for(:fixture_root, modules)
    end

    test "a refinement inherits its parent's actions" do
      modules = StarlightBot.Test.NavFixtureScreens.screen_modules()

      assert [%StarlightBot.Navigation.Action{screen: :fixture_root, name: :fixture_root_action}] =
               Catalog.actions_for(:fixture_child, modules)
    end

    test "a screen with no actions of its own or inherited returns an empty list" do
      assert Catalog.actions_for(:home) == []
    end

    test "find_action/2 looks up a single action by name, including inherited" do
      modules = StarlightBot.Test.NavFixtureScreens.screen_modules()

      assert %StarlightBot.Navigation.Action{name: :fixture_root_action} =
               Catalog.find_action(:fixture_child, :fixture_root_action, modules)

      assert Catalog.find_action(:fixture_child, :nonexistent_action, modules) == nil
    end
  end

  describe "find_transition/2" do
    test "looks up a single transition by name" do
      assert %Transition{from: :home_window, to: :home_drive, name: :home_drive} =
               Catalog.find_transition(:home_window, :home_drive)
    end

    test "returns nil when no transition with that name exists from that screen" do
      assert Catalog.find_transition(:home_window, :nonexistent_transition) == nil
    end

    test "resolves a name inherited from a refined parent" do
      # home_drive has no transition of its own named :charge_enkephalin, but
      # inherits it from :home the same way transitions_from/1 does.
      assert %Transition{from: :home, to: :charge_enkephalin, name: :charge_enkephalin} =
               Catalog.find_transition(:home_drive, :charge_enkephalin)
    end
  end

  describe "reachable_from/1" do
    test "reports hop counts, preferring the shortest path to each screen" do
      reach = Catalog.reachable_from(:home) |> Map.new()

      # direct transition + the zero-step unknown-bridge both land at hop 1
      assert reach[:charge_enkephalin] == 1
      assert reach[:home_unknown] == 1

      # only reachable via the home_unknown bridge, so hop 2
      assert reach[:home_drive] == 2
      assert reach[:home_window] == 2
    end
  end

  describe "whole-catalog structural invariants" do
    test "every screen name is declared exactly once" do
      names = Catalog.all_screens() |> Enum.map(& &1.name)
      assert Enum.uniq(names) == names
    end

    test "every screen's :refines target names a real screen" do
      screen_names = MapSet.new(Catalog.all_screens(), & &1.name)

      for screen <- Catalog.all_screens(), not is_nil(screen.refines) do
        assert MapSet.member?(screen_names, screen.refines),
               "#{inspect(screen.name)} refines #{inspect(screen.refines)}, which isn't a registered screen"
      end
    end

    test "no transition or action has a step list nested inside its steps" do
      for %{steps: steps} = entry <- Catalog.all_transitions() ++ Catalog.all_actions() do
        refute Enum.any?(steps, &is_list/1), "#{inspect(entry)} has a nested step list (missing ++?)"
      end
    end

    test "every transition's :to target names a real screen" do
      screen_names = MapSet.new(Catalog.all_screens(), & &1.name)

      for transition <- Catalog.all_transitions() do
        assert MapSet.member?(screen_names, transition.to),
               "transition from #{inspect(transition.from)} points to unregistered screen #{inspect(transition.to)}"
      end
    end
  end
end
