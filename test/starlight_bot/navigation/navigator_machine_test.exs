defmodule StarlightBot.Navigation.NavigatorMachineTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias StarlightBot.FakeWorld
  alias StarlightBot.Navigation.Navigator

  @reward_hooks [:exploration_reward, :exploration_reward_give_up, :exploration_reward_give_up_confirm]

  defp await_idle_log(text, timeout \\ 10_000) do
    receive do
      {:nav_state, %{phase: :idle, log: [%{text: ^text} | _]}} -> :ok
      {:nav_state, _} -> await_idle_log(text, timeout)
    after
      timeout -> flunk("navigator never logged #{inspect(text)}")
    end
  end

  setup do
    start_supervised!({Navigator, []})
    Navigator.subscribe()
    :ok
  end

  test "localize runs as a supervised machine and reports back to the navigator" do
    FakeWorld.start!()
    Navigator.localize()

    assert_receive {:nav_state, %{phase: :localizing}}
    assert_receive {:nav_state, %{phase: :idle, current_screen: :unknown}}, 2_000
  end

  test "a script keeps running while the navigator's code is reloaded twice, and the new code takes its result" do
    FakeWorld.start!(hooks: @reward_hooks)
    FakeWorld.react({:click, :exploration_reward_give_up}, show: [:exploration_reward_give_up_confirm])
    FakeWorld.react({:key, :enter}, hide: [:exploration_reward_give_up_confirm, :exploration_reward])

    Navigator.claim_rewards(%{action: :give_up})
    assert_receive {:nav_state, %{phase: :running}}
    Process.sleep(200)

    for _ <- 1..2 do
      :code.purge(Navigator)
      {:module, Navigator} = :code.load_file(Navigator)
    end

    FakeWorld.show(:exploration_reward)
    await_idle_log("Rewards: give_up")

    assert [{:click, :exploration_reward_give_up}, {:key, :enter}] =
             Enum.filter(FakeWorld.inputs(), &match?({kind, _} when kind in [:key, :click], &1))
  end
end
