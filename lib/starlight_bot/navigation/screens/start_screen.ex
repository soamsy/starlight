defmodule StarlightBot.Navigation.Screens.StartScreen do
  use StarlightBot.Navigation.DSL

  screen :start_screen, identity: :clear_all_caches do
    transition to: :home,
      do: [reclick_until_gone(:clear_all_caches, every: 1000, timeout: 90_000)] ++ loading()
  end
end
