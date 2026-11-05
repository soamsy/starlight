defmodule StarlightBot.Navigation.Screens.StartScreen do
  use StarlightBot.Navigation.DSL

  screen :start_screen, identity: :clear_all_caches do
    transition to: :start_screen_after do
      [
        retry_until(
          any_of([not_hook(:clear_all_caches), :scheduled_maintenance, :cannot_operate_game]),
          [
            branch([
              {:random_confirm, [click(:random_confirm)]},
              {:default, [click(:clear_all_caches)]},
            ]),
            key(:enter),
          ],
          every: 1000,
          timeout: 150_000)
      ]
    end
  end

  screen :start_screen_after, identity: nil, catch_all: true
end
