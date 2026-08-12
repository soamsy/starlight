defmodule StarlightBot.Navigation.DSLTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Navigation.DSL
  alias StarlightBot.Navigation.Catalog
  alias StarlightBot.Navigation.Screen

  describe "step builders" do
    test "click/1" do
      assert DSL.click(:home_lunacy) == {:click, :home_lunacy}
    end

    test "move_to/1" do
      assert DSL.move_to(:home_lunacy) == {:move_to, :home_lunacy}
    end

    test "drag/3-4 defaults duration to nil, dx/dy positive is right/down" do
      assert DSL.drag(:slider_handle, 100, 0) == {:drag, :slider_handle, 100, 0, nil}
      assert DSL.drag(:slider_handle, 0, -50) == {:drag, :slider_handle, 0, -50, nil}
      assert DSL.drag(:slider_handle, 100, 0, 500) == {:drag, :slider_handle, 100, 0, 500}
    end

    test "scroll_down/0-1 defaults to 3 clicks, downward is positive dy" do
      assert DSL.scroll_down() == {:scroll, 0, 3}
      assert DSL.scroll_down(5) == {:scroll, 0, 5}
    end

    test "scroll_up/0-1 defaults to 3 clicks, upward is negative dy" do
      assert DSL.scroll_up() == {:scroll, 0, -3}
      assert DSL.scroll_up(5) == {:scroll, 0, -5}
    end

    test "key/1" do
      assert DSL.key(:esc) == {:key, :esc}
    end

    test "type/1" do
      assert DSL.type("10") == {:type, "10"}
    end

    test "custom/1 wraps a 2-arity function" do
      fun = fn last_frame, _ctx -> {:ok, last_frame} end
      assert DSL.custom(fun) == {:custom, fun}
    end

    test "await/1-2 defaults to a 5s timeout and accepts atom/list/not_hook specs" do
      assert DSL.await(:foo) == {:await, :foo, 5_000}
      assert DSL.await(:foo, timeout: 100) == {:await, :foo, 100}
      assert DSL.await([:a, :b]) == {:await, [:a, :b], 5_000}
      assert DSL.await(DSL.not_hook(:a)) == {:await, {:not, :a}, 5_000}
    end

    test "await_any/1-2 defaults to a 5s timeout" do
      assert DSL.await_any([:a, :b]) == {:await_any, [:a, :b], 5_000}
      assert DSL.await_any([:a, :b], timeout: 250) == {:await_any, [:a, :b], 250}
    end

    test "branch/1 splits out :default and keeps declaration order for checks" do
      assert DSL.branch(a: [1], b: [2], default: [9]) == {:branch, [a: [1], b: [2]], [9]}
    end

    test "branch/1 with no :default clause yields an empty fallback" do
      assert DSL.branch(a: [1]) == {:branch, [a: [1]], []}
    end

    test "sleep/1" do
      assert DSL.sleep(200) == {:sleep, 200}
    end

    test "not_hook/1 wraps and nests without collapsing double negation" do
      assert DSL.not_hook(:a) == {:not, :a}
      assert DSL.not_hook(DSL.not_hook(:a)) == {:not, {:not, :a}}
    end

    test "retry_until/3 defaults to a 5s timeout, 500ms interval, and no fixed tries" do
      assert DSL.retry_until(:a, [DSL.click(:a)]) ==
               {:retry_until, :a, [{:click, :a}], 5_000, 500, nil}

      assert DSL.retry_until(:a, [DSL.click(:a)], timeout: 2_000, every: 200) ==
               {:retry_until, :a, [{:click, :a}], 2_000, 200, nil}
    end

    test "retry_until/3 with :tries carries the fixed attempt count instead" do
      assert DSL.retry_until(:a, [DSL.click(:a)], tries: 3) ==
               {:retry_until, :a, [{:click, :a}], 5_000, 500, 3}

      assert DSL.retry_until(:a, [DSL.click(:a)], every: 200, tries: 3) ==
               {:retry_until, :a, [{:click, :a}], 5_000, 200, 3}
    end

    test "wait_until/1-2 is retry_until/3 with an empty step list" do
      assert DSL.wait_until(:a) == {:retry_until, :a, [], 5_000, 500, nil}
    end

    test "reclick_until_gone/1-2 retries a click against the negated hook" do
      assert DSL.reclick_until_gone(:a) ==
               {:retry_until, {:not, :a}, [{:click, :a}], 5_000, 500, nil}
    end

    test "await_then_gone/1-2 awaits the hook, then awaits its negation" do
      assert DSL.await_then_gone(:loading_stage_2) ==
               [
                 {:await, :loading_stage_2, 5_000},
                 {:await, {:not, :loading_stage_2}, 30_000}
               ]

      assert DSL.await_then_gone(:loading_stage_2, appear_timeout: 100, gone_timeout: 200) ==
               [
                 {:await, :loading_stage_2, 100},
                 {:await, {:not, :loading_stage_2}, 200}
               ]
    end
  end

  describe "screen/2,3 macro output" do
    test "wires name, identity_hook, refines, and catch_all onto Screen structs" do
      screens = StarlightBot.Navigation.Screens.Home.__nav_screens__()

      assert %Screen{name: :home, identity_hook: :home_lunacy, refines: nil, catch_all: false} =
               Enum.find(screens, &(&1.name == :home))

      assert %Screen{
               name: :home_drive,
               identity_hook: :home_drive_selected,
               refines: :home,
               catch_all: false
             } = Enum.find(screens, &(&1.name == :home_drive))

      assert %Screen{name: :home_unknown, identity_hook: nil, refines: :home} =
               Enum.find(screens, &(&1.name == :home_unknown))
    end

    test "identity_hook accepts a list for OR-matched visual variants" do
      screens = StarlightBot.Navigation.Screens.BackAvailable.__nav_screens__()
      back = Enum.find(screens, &(&1.name == :back_available))
      assert back.identity_hook == [:back_button_thin, :back_button_thick]
    end

    test "catch_all: true with no do-block compiles as a bare landing pad" do
      screens = StarlightBot.Navigation.Screens.TeamSelect.__nav_screens__()

      assert %Screen{name: :exit_team_select, identity_hook: nil, catch_all: true} =
               Enum.find(screens, &(&1.name == :exit_team_select))
    end
  end

  describe "action/2 macro output" do
    test "wires screen, name, and steps onto an Action struct" do
      actions = StarlightBot.Test.NavFixtureScreens.Root.__nav_actions__()

      assert [%StarlightBot.Navigation.Action{screen: :fixture_root, name: :fixture_root_action, steps: steps}] =
               actions

      assert steps == [{:click, :root_button}]
    end
  end

  describe "transition/1-2 name option" do
    test "defaults to the :to target when :name is omitted" do
      transitions = StarlightBot.Navigation.Screens.Home.__nav_transitions__()
      t = Enum.find(transitions, &(&1.from == :home_window and &1.to == :home_drive))
      assert t.name == :home_drive
    end

    test "an explicit :name overrides the :to default" do
      defmodule NamedTransitionFixture do
        use StarlightBot.Navigation.DSL

        screen :named_fixture_screen, identity: :whatever do
          transition to: :home_drive, name: :via_named_path, do: []
        end
      end

      assert [%StarlightBot.Navigation.Transition{to: :home_drive, name: :via_named_path}] =
               NamedTransitionFixture.__nav_transitions__()
    end

    test "two transitions on the same screen with colliding names raise CompileError" do
      assert_raise CompileError, ~r/has 2 transitions named :home_drive/, fn ->
        defmodule DuplicateTransitionNameFixture do
          use StarlightBot.Navigation.DSL

          screen :dup_fixture_screen, identity: :whatever do
            transition to: :home_drive, do: []
            transition to: :home_window, name: :home_drive, do: []
          end
        end
      end
    end
  end

  describe "reclick_until_arrived resolves @current_transition_to per call site" do
    test "same macro, two transitions in one module, two different resolved hooks" do
      transitions = StarlightBot.Navigation.Screens.Home.__nav_transitions__()

      to_drive = Enum.find(transitions, &(&1.from == :home_window and &1.to == :home_drive))
      to_window = Enum.find(transitions, &(&1.from == :home_drive and &1.to == :home_window))

      assert to_drive.steps == [{:retry_until, :home_drive_selected, [{:click, :home_drive_unselected}], 5_000, 500, nil}]
      assert to_window.steps == [{:retry_until, :home_window_selected, [{:click, :home_window_unselected}], 5_000, 500, nil}]
    end

    test "raises when the transition target has no identity hook to retry against" do
      assert_raise ArgumentError, ~r/has no identity hook/, fn ->
        defmodule BrokenFixture do
          use StarlightBot.Navigation.DSL

          screen :broken_fixture_screen, identity: :whatever do
            transition to: :charge_enkephalin_unknown, do: reclick_until_arrived(:home_lunacy)
          end
        end

        BrokenFixture.__nav_transitions__()
      end
    end
  end

  test "the screens this file asserts against are actually registered" do
    names = Catalog.all_screens() |> Enum.map(& &1.name)
    assert :home in names
    assert :home_drive in names
    assert :home_unknown in names
    assert :charge_enkephalin_unknown in names
  end
end
