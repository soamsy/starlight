defmodule StarlightBot.Navigation.Screens.Event do
  use StarlightBot.Navigation.DSL


  screen :event, identity: :event do
    transition to: :event_over do
      [
        retry_until(
          [:event_choices, :event_advantage_check, :event_continue, not_hook(:event)],
          [
            branch([
              {:event_skip, [click(:event_skip)]},
              {:event_skip_unselectable, [click(:event_skip_unselectable)]},
              {:default, []}
            ])
          ],
          every: 500,
          tries: 60
        ),
        branch([
          {:event_advantage_check,
           [
             click(:event_advantage_check),
             await(:event_advantage_go_forth),
             click(:event_advantage_go_forth),
             await(:event_commence),
             click(:event_commence),
             await(:event_result)
           ]},
          {:event_choices, [click(:event_choice_0), sleep(300)]},
          {:default, []}
        ]),
        retry_until(
          not_hook(:event),
          [
            branch([
              {:event_proceed, [click(:event_proceed)]},
              {:event_continue, [click(:event_continue)]},
              {:event_skip, [click(:event_skip)]},
              {:event_skip_unselectable, [click(:event_skip_unselectable)]},
              {:default, []}
            ])
          ],
          every: 500,
          tries: 60
        )
      ]
    end
  end

  screen :event_over, identity: nil, catch_all: true
end
