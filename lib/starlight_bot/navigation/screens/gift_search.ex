defmodule StarlightBot.Navigation.Screens.GiftSearch do
  use StarlightBot.Navigation.DSL

  screen :gift_search, identity: :gift_search do
    transition to: :gift_search_refuse_confirm, do: [reclick_until_arrived(:gift_search_refuse)]
  end

  screen :gift_search_refuse_confirm, identity: :gift_search_refuse_confirm do
    transition to: :theme_pack do
      [reclick_until_gone(:gift_search_refuse_confirm)] ++ loading()
    end
  end
end
