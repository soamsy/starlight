defmodule StarlightBot.Navigation.Screens.DungeonProgress do
  use StarlightBot.Navigation.DSL

  screen :dungeon_progress, identity: :dungeon_progress do
    transition to: :any? do
      [key(:esc), sleep(300)]
    end

    transition to: :dungeon_given_up do
      [
        retry_until(:dungeon_progress_to_window_confirm, [click(:dungeon_progress_to_window)], every: 800, tries: 3),
        reclick_until_gone(:dungeon_progress_to_window_confirm, every: 800, tries: 3)
      ] ++ loading()
    end
  end

  screen :dungeon_given_up, identity: nil, catch_all: true
end
