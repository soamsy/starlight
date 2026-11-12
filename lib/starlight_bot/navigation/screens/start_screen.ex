defmodule StarlightBot.Navigation.Screens.StartScreen do
  use StarlightBot.Navigation.DSL

  screen :start_screen, identity: :clear_all_caches do
    transition to: :home, do: leave_start_screen()

    transition to: :start_screen_after, do: leave_start_screen()
  end

  screen :start_screen_after, identity: nil, catch_all: true

  defp leave_start_screen do
    [
      retry_until(
        any_of([:home_lunacy, :scheduled_maintenance, :cannot_operate_game]),
        [
          branch([
            {:random_confirm, [click(:random_confirm)]},
            {:random_confirm_2, [click(:random_confirm_2)]},
            {:clear_all_caches, [click(:clear_all_caches)]},
            {:default, [click(:safe_corner)]},
          ]),
          key(:enter),
        ],
        every: 1000,
        timeout: 150_000)
    ]
  end
end
