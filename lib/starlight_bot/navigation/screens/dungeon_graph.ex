defmodule StarlightBot.Navigation.Screens.DungeonGraph do
  use StarlightBot.Navigation.DSL

  screen :dungeon_graph, identity: :dungeon_graph do
    action :reset_view, do: [key(:d), sleep(150), key(:a)]

    transition to: :dungeon_graph_node do
      [
        key(:d),
        await(:dungeon_graph_enter, timeout: 3_000),
        key(:enter),
        await_any([:event, :team_selector, :team_selector_tall, :team_selector_gone, :shop, :shop_super], timeout: 3_000),
      ]
    end
  end

  screen :dungeon_graph_node, identity: nil, catch_all: true
end
