defmodule StarlightBot.Navigation.Screens.Grace do
  use StarlightBot.Navigation.DSL

  screen :grace, identity: :grace_available do
    transition to: :grace_confirm, do: [reclick_until_arrived(:grace_enter, every: 1000)]
  end

  screen :grace_confirm, identity: :grace_popup_confirm, refines: :grace do
    transition to: :cabinet_ego_gifts, do: [reclick_until_gone(:grace_popup_confirm)]
  end
end
