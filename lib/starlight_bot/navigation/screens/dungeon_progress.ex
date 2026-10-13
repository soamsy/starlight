defmodule StarlightBot.Navigation.Screens.DungeonProgress do
  use StarlightBot.Navigation.DSL

  screen :dungeon_progress, identity: :dungeon_progress do
    transition to: :any? do
      [key(:esc), sleep(300)]
    end
  end
end
