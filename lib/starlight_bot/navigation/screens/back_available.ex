defmodule StarlightBot.Navigation.Screens.BackAvailable do
  use StarlightBot.Navigation.DSL

  screen :back_available, identity: [:back_button_thin, :back_button_thick] do
    transition to: :any? do
      [key(:esc), sleep(300)]
    end
  end

  screen :any?, identity: nil, catch_all: true do
  end
end
