defmodule StarlightBot.Navigation.Screens.StartScreen do
  use StarlightBot.Navigation.DSL

  screen :start_screen, identity: :clear_all_caches do
    transition to: :home,
      do: [reclick_until_arrived(:clear_all_caches, every: 1000, timeout: 150_000)]
  end
end
