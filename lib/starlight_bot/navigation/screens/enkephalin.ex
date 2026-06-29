defmodule StarlightBot.Navigation.Screens.Enkephalin do
  use StarlightBot.Navigation.DSL

  defmacrop tab_switch_sequence(hook) do
    quote do
      [branch([{unquote(hook), []}, {:default, [reclick_until_arrived(unquote(hook), every: 700, tries: 5)]}])]
    end
  end

  screen :charge_enkephalin, identity: :charge_enkephalin_popup do
    transition to: :home do
      [key(:esc), sleep(400)]
    end
  end

  screen :charge_enkephalin_modules_tab, identity: :charge_enkephalin_tab_modules, refines: :charge_enkephalin do
    transition to: :charge_enkephalin_lunacy_tab, do: tab_switch_sequence(:charge_enkephalin_tab_lunacy)
    transition to: :charge_enkephalin_boxes_tab, do: tab_switch_sequence(:charge_enkephalin_tab_boxes)
  end

  screen :charge_enkephalin_lunacy_tab, identity: :charge_enkephalin_tab_lunacy, refines: :charge_enkephalin do
    transition to: :charge_enkephalin_modules_tab, do: tab_switch_sequence(:charge_enkephalin_tab_modules)
    transition to: :charge_enkephalin_boxes_tab, do: tab_switch_sequence(:charge_enkephalin_tab_boxes)
  end

  screen :charge_enkephalin_boxes_tab, identity: :charge_enkephalin_tab_boxes, refines: :charge_enkephalin do
    transition to: :charge_enkephalin_modules_tab, do: tab_switch_sequence(:charge_enkephalin_tab_modules)
    transition to: :charge_enkephalin_lunacy_tab, do: tab_switch_sequence(:charge_enkephalin_tab_lunacy)
  end

  screen :charge_enkephalin_unknown, identity: nil, refines: :charge_enkephalin do
    transition to: :charge_enkephalin_modules_tab, do: tab_switch_sequence(:charge_enkephalin_tab_modules)
    transition to: :charge_enkephalin_lunacy_tab, do: tab_switch_sequence(:charge_enkephalin_tab_lunacy)
    transition to: :charge_enkephalin_boxes_tab, do: tab_switch_sequence(:charge_enkephalin_tab_boxes)
  end
end
