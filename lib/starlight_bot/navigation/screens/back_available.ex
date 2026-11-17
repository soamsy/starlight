defmodule StarlightBot.Navigation.Screens.BackAvailable do
  use StarlightBot.Navigation.DSL

  screen :back_available, identity: any_of([:back_button_thin, :back_button_thick]) do
    transition to: :any? do
      [
        branch([
          {:back_button_thin, [click(:back_button_thin)]},
          {:back_button_thick, [click(:back_button_thick)]},
          {:default, [key(:escape)]}
        ]),
      ]
    end
  end

  screen :any?, identity: nil, catch_all: true do
  end
end
