defmodule StarlightBot.Navigation.Screens.ThemePack do
  use StarlightBot.Navigation.DSL

  screen :theme_pack, identity: :theme_pack_select do
    action :refresh, do: [branch([{not_hook(:theme_pack_select_refresh_0), [click(:theme_pack_select_refresh), await_then_gone(:connecting)]}])]
    action :to_hard, do: [branch([{:theme_pack_select_normal, [click(:theme_pack_select_normal)]}])]
    action :to_normal, do: [branch([{:theme_pack_select_hard, [click(:theme_pack_select_hard)]}])]
    transition to: :dungeon_graph do
      [
        retry_until(not_hook(:theme_pack_select), [drag(:theme_pack_middle, 0, 430)], every: 1000, tries: 4),
        wait_until_arrived(every: 300, tries: 5),
        await_any([:dungeon_graph_dante, :ego_gift_get])
      ]
    end
    transition to: :cabinet_reward do
      [
        retry_until(not_hook(:theme_pack_select), [drag(:theme_pack_middle, 0, 430)], every: 1000, tries: 4),
        wait_until_arrived(timeout: 5_000)
      ]
    end
  end
end
