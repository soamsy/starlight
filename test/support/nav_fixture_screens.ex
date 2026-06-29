defmodule StarlightBot.Test.NavFixtureScreens.Root do
  use StarlightBot.Navigation.DSL

  screen :fixture_root, identity: :fixture_root_hook do
    transition to: :fixture_child, do: [click(:go_to_child)]
    action :fixture_root_action, do: [click(:root_button)]
  end

  screen :fixture_child, identity: :fixture_child_hook, refines: :fixture_root do
    transition to: :fixture_grandchild, do: [click(:go_to_grandchild)]
  end

  screen :fixture_grandchild, identity: :fixture_grandchild_hook, refines: :fixture_child do
  end
end

defmodule StarlightBot.Test.NavFixtureScreens do
  def screen_modules, do: [StarlightBot.Test.NavFixtureScreens.Root]
end
