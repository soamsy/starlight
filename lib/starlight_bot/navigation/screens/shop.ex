defmodule StarlightBot.Navigation.Screens.Shop do
  use StarlightBot.Navigation.DSL

  screen :shop, identity: :shop do
    transition to: :dungeon_graph do
      [retry_until(not_hook(:shop), [click(:shop_leave)], every: 500, tries: 5)] ++
        loading()
    end
  end

  screen :shop_super, identity: :shop_super, refines: :shop do
  end
end
