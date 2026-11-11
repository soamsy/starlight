defmodule StarlightBot.Navigation.Screens.Shop do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Shop.Ops

  screen :shop_sell_popup, identity: :shop_sell_popup do
    transition to: :shop, do: back_to_shop()
  end

  screen :shop_fuse_popup, identity: :shop_fuse_popup do
    transition to: :shop, do: back_to_shop()
  end

  screen :shop_uptie_popup, identity: :shop_uptie_popup do
    transition to: :shop, do: back_to_shop()
  end

  screen :shop_keyword_refresh_popup, identity: :shop_keyword_refresh_popup do
    transition to: :shop, do: back_to_shop()
  end

  screen :shop_purchase_popup, identity: :shop_purchase_popup do
    transition to: :shop, do: back_to_shop()
  end

  screen :shop_replace_popup, identity: :shop_replace_popup do
    transition to: :shop, do: back_to_shop()
  end

  screen :shop_heal_menu, identity: :shop_heal_menu do
    transition to: :shop, do: back_to_shop()
  end

  screen :shop_leave_confirm, identity: :shop_leave_confirm do
    transition to: :shop, do: back_to_shop()
  end

  screen :shop, identity: :shop do
    transition to: :dungeon_graph do
      [
        click(:shop_leave),
        branch([{:shop_leave_confirm, []}], wait: 1_500),
        retry_until(:dungeon_graph, [branch([{:shop_leave_confirm, [key(:enter)]}, {:shop, [click(:shop_leave)]}])], every: 1000, timeout: 8_000)
      ]
    end

    action :refresh_shelf do
      [click(:shop_refresh, settle_ms: 100)]
    end
  end

  screen :shop_super, identity: :shop_super, refines: :shop do
  end

  def popup_screens,
    do: [
      :shop_sell_popup,
      :shop_fuse_popup,
      :shop_uptie_popup,
      :shop_keyword_refresh_popup,
      :shop_purchase_popup,
      :shop_replace_popup,
      :shop_heal_menu,
      :shop_leave_confirm
    ]

  defp back_to_shop, do: [call(__MODULE__, :recover_to_shop)]

  def recover_to_shop(_frame, ctx), do: Ops.recover_to_shop(ctx)
end
