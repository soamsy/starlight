defmodule StarlightBot.Navigation.Screens.CabinetEgoGifts do
  use StarlightBot.Navigation.DSL

  screen :cabinet_ego_gifts, identity: :cabinet_ego_gifts do
    action :select_bleed, do: [click(:cabinet_ego_gifts_bleed)]
    action :select_blunt, do: [click(:cabinet_ego_gifts_blunt)]
    action :select_burn, do: [click(:cabinet_ego_gifts_burn)]
    action :select_charge, do: [click(:cabinet_ego_gifts_charge)]
    action :select_pierce, do: [click(:cabinet_ego_gifts_pierce)]
    action :select_poise, do: [click(:cabinet_ego_gifts_poise)]
    action :select_rupture, do: [click(:cabinet_ego_gifts_rupture)]
    action :select_sinking, do: [click(:cabinet_ego_gifts_sinking)]
    action :select_slash, do: [click(:cabinet_ego_gifts_slash)]
    action :select_tremor, do: [click(:cabinet_ego_gifts_tremor)]

    action :select_gift_0, do: [branch([{any_of([:cabinet_ego_gift_available_1, :cabinet_ego_gift_available_2, :cabinet_ego_gift_available_3]), select_gift(:cabinet_ego_gift_0)}])]
    action :select_gift_1, do: [branch([{any_of([:cabinet_ego_gift_available_2, :cabinet_ego_gift_available_3]), select_gift(:cabinet_ego_gift_1)}])]
    action :select_gift_2, do: [branch([{:cabinet_ego_gift_available_3, select_gift(:cabinet_ego_gift_2)}])]

    transition to: :cabinet_ego_gift_refuse_confirm, do: [reclick_until_arrived(:cabinet_ego_gift_refuse)]
    transition to: :ego_gift_get, do: [
      key(:enter),
      sleep(100),
      branch([
        {:cabinet_ego_gift_never_message_again, [click(:cabinet_ego_gift_never_message_again), click(:cabinet_ego_gift_unselected_confirm)]},
        {:ego_gift_get, []},
        {:cabinet_ego_gift_1_of_1, [click(:cabinet_ego_gift_select)]},
        {:cabinet_ego_gift_2_of_2, [click(:cabinet_ego_gift_select)]},
        {:cabinet_ego_gift_3_of_3, [click(:cabinet_ego_gift_select)]},
        {:default, [
          click(:cabinet_ego_gift_0),
          click(:cabinet_ego_gift_select),
          sleep(200),
          branch([
            {:cabinet_ego_gift_never_message_again, [click(:cabinet_ego_gift_never_message_again), click(:cabinet_ego_gift_unselected_confirm)]},
            {:default, []}
          ], wait: 500)
        ]}
      ], wait: 800)
    ]
  end

  defp select_gift(hook) do
    [
      click(hook),
    ]
  end

  screen :cabinet_ego_gift_refuse_confirm, identity: :cabinet_ego_gift_refuse_confirm do
    transition to: :any?,
      do:
        [reclick_until_gone(:cabinet_ego_gift_refuse_confirm)] ++ loading()
  end

end
