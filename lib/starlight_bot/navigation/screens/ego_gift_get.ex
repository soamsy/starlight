defmodule StarlightBot.Navigation.Screens.EgoGiftGet do
  use StarlightBot.Navigation.DSL

  screen :ego_gift_get, identity: :ego_gift_get do
    transition to: :ego_gift_over,
      do:
        [retry_until(not_hook(:ego_gift_get), [key(:space)], every: 700, tries: 8)] ++ sleep(500)
  end

  screen :ego_gift_over, identity: nil, catch_all: true
end
