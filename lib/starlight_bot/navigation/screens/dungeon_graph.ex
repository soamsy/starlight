defmodule StarlightBot.Navigation.Screens.DungeonGraph do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.DungeonPathPlanner

  screen :dungeon_graph, identity: :dungeon_graph do
    action :reset_view, do: [key(:d), sleep(200), key(:a), sleep(200)]

    transition to: :dungeon_graph_node do
      [call(DungeonPathPlanner, :navigate_to_next_node)]
    end

    transition to: :dungeon_progress do
      [retry_until(:dungeon_progress, [click(:dungeon_graph_settings_gear)], every: 1_000, tries: 3)]
    end
  end

  screen :dungeon_graph_superposition_popup, identity: :dungeon_graph_superposition_popup_confirm, refines: :dungeon_graph do
    transition to: :dungeon_graph_superposition_entered do
      confirm(:dungeon_graph_superposition_popup_confirm)
    end

    transition to: :exploration_reward do
      confirm(:dungeon_graph_superposition_popup_cancel)
    end
  end

  screen :dungeon_graph_danger_zone_skip, identity: :dungeon_graph_danger_zone_skip, refines: :dungeon_graph do
    transition to: :dungeon_graph_danger_zone_skipped do
      confirm(:dungeon_graph_danger_zone_skip)
    end
  end

  screen :dungeon_graph_danger_zone_skipped, identity: nil, catch_all: true
  screen :dungeon_graph_superposition_entered, identity: nil, catch_all: true
  screen :dungeon_graph_node, identity: nil, catch_all: true
end
