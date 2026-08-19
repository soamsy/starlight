defmodule StarlightBot.Navigation.Screens.Event do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.EventAdvantage

  screen :event, identity: :event do
    transition to: :event_over, do: play_out_steps()
  end

  screen :event_over, identity: nil, catch_all: true

  def play_out_steps do
    [
      retry_until(
        not_hook(:event),
        [
          branch([
            {:event_proceed, [reclick_until_gone(:event_proceed)]},
            {:event_continue, [retry_until_gone(:event_continue, [key(:space)])]},
            {:event_skip, [retry_until_gone(:event_skip, [key(:space)]), key(:space), sleep(20), key(:space)]},
            {:event_commence, [reclick_until_gone(:event_commence)]},
            {:event_advantage_none_selected,
              [
                retry_until(
                  not_hook(:event_advantage_none_selected),
                  [custom(&EventAdvantage.select_best_sinner/2)],
                  every: 500,
                  tries: 20
                ),
                await(:event_commence, timeout: 1000),
                reclick_until_gone(:event_commence)
              ]},
            {:event_chicken_1, [click(:event_choice_0), sleep(300)]},
            {:event_chicken_2, [click(:event_choice_0), sleep(300)]},
            {:event_text_ego_gift, [click(:event_choice_0), sleep(300)]},
            {:event_choices, [click(:event_choice_0), sleep(300)]},
            {:event_skip_unselectable, [click(:event_skip_unselectable)]},
            {:default, [key(:space), click(:event_skip)]}
          ])
        ],
        every: 500,
        tries: 60
      )
    ]
  end
end
