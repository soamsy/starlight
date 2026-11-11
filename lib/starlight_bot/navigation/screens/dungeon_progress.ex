defmodule StarlightBot.Navigation.Screens.DungeonProgress do
  use StarlightBot.Navigation.DSL

  screen :dungeon_progress, identity: :dungeon_progress do
    transition to: :any? do
      [key(:esc), sleep(300)]
    end

    transition to: :dungeon_forfeited do
      [click(:dungeon_progress_forfeit)] ++
        confirm_enter(:dungeon_progress_forfeit_confirm) ++
        [await(:battle_over_black_confirm, timeout: 30_000)] ++
        confirm(:battle_over_black_confirm) ++
        [await_any([:exploration_reward, :exploration_complete], timeout: 30_000)]
    end

    transition to: :dungeon_given_up, do: leave_to_window()

    transition to: :home, do: leave_to_window()
  end

  screen :dungeon_forfeited, identity: nil, catch_all: true
  screen :dungeon_given_up, identity: nil, catch_all: true

  defp leave_to_window do
    [click(:dungeon_progress_to_window)] ++
      confirm_enter(:dungeon_progress_to_window_confirm) ++
      loading()
  end
end
