defmodule StarlightBot.Navigation.Screens.Shop do
  use StarlightBot.Navigation.DSL

  screen :shop, identity: :shop do
    transition to: :dungeon_graph do
      [
        retry_until_arrived([click(:shop_leave), await(:shop_leave_confirm), click(:shop_leave_confirm)], every: 2000)
      ]
    end

    action :refresh_shelf do
      [
        click(:shop_refresh),
        sleep(400),
        branch(shop_refresh_popup_are_you_sure: [click(:shop_refresh_popup_confirm)], default: [])
      ]
    end
  end

  screen :shop_super, identity: :shop_super, refines: :shop do
  end
end
