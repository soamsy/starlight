defmodule StarlightBot.Navigation.Screens.DungeonGraph do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.DungeonPathPlanner

  screen :dungeon_graph, identity: :dungeon_graph do
    action :reset_view, do: [key(:d), sleep(200), key(:a), sleep(200)]

    transition to: :dungeon_graph_node do
      [
        custom(&DungeonPathPlanner.navigate_to_next_node/2),
        key(:d),
        await(:dungeon_graph_enter, timeout: 3_000),
        key(:enter),
        await_any([:event, :team_selector, :team_selector_tall, :team_selector_gone, :shop, :shop_super], timeout: 3_000),
      ]
    end
  end

  screen :dungeon_graph_node, identity: nil, catch_all: true
end
