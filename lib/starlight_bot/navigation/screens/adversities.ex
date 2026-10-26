defmodule StarlightBot.Navigation.Screens.Adversities do
  use StarlightBot.Navigation.DSL

  @card_hooks Enum.map(0..5, &:"adversities_#{&1}")
  @card_settle_ms 150
  @all_selected_hook :adversities_6_6

  screen :adversities, identity: :adversities do
    transition to: :adversities_over do
      Enum.map(@card_hooks, &branch([{@all_selected_hook, []}, default: [click(&1), sleep(@card_settle_ms)]], wait: 1)) ++
        [await(@all_selected_hook, timeout: 2_000), reclick_until_gone(@all_selected_hook)]
    end
  end

  screen :adversities_over, identity: nil, catch_all: true
end
