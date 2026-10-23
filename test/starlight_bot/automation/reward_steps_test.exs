defmodule StarlightBot.Automation.RewardStepsTest do
  use ExUnit.Case, async: false

  alias StarlightBot.Automation.{Engine, RewardHelpers}
  alias StarlightBot.FakeWorld

  @moduletag :capture_log

  @hooks [
    :ego_gift_get,
    :ego_gift_get_confirm,
    :encounter_reward,
    :encounter_reward_gain_cost,
    :encounter_reward_confirm
  ]

  describe "dismiss_ego_gift_get_step" do
    test "presses space and enter until the popup is gone" do
      FakeWorld.start!(hooks: @hooks, visible: [:ego_gift_get])
      FakeWorld.react({:key, :space}, hide: [:ego_gift_get])

      assert {:ok, _} = Engine.act([RewardHelpers.dismiss_ego_gift_get_step()])
      assert FakeWorld.inputs() == [{:key, :space}, {:key, :enter}]
    end

    test "does nothing when the popup never shows" do
      FakeWorld.start!(hooks: @hooks)

      assert {:ok, _} = Engine.act([RewardHelpers.dismiss_ego_gift_get_step(appear_timeout: 100)])
      assert FakeWorld.inputs() == []
    end

    test "clicks confirm when the keys don't close it" do
      FakeWorld.start!(hooks: @hooks, visible: [:ego_gift_get, :ego_gift_get_confirm])
      FakeWorld.react({:click, :ego_gift_get_confirm}, hide: [:ego_gift_get, :ego_gift_get_confirm])

      assert {:ok, _} = Engine.act([RewardHelpers.dismiss_ego_gift_get_step()])

      inputs = FakeWorld.inputs()
      assert Enum.count(inputs, &(&1 == {:key, :space})) == 5
      assert List.last(inputs) == {:click, :ego_gift_get_confirm}
    end

    test "clicks confirm straight away over an encounter reward" do
      FakeWorld.start!(hooks: @hooks, visible: [:ego_gift_get, :ego_gift_get_confirm, :encounter_reward])
      FakeWorld.react({:click, :ego_gift_get_confirm}, hide: [:ego_gift_get, :ego_gift_get_confirm])

      assert {:ok, _} = Engine.act([RewardHelpers.dismiss_ego_gift_get_step()])
      assert FakeWorld.inputs() == [{:click, :ego_gift_get_confirm}]
    end
  end

  test "the encounter reward transition picks a gift, confirms and dismisses the gift popup" do
    FakeWorld.start!(hooks: @hooks, visible: [:encounter_reward, :encounter_reward_gain_cost, :encounter_reward_confirm])

    FakeWorld.react({:click, :encounter_reward_confirm},
      hide: [:encounter_reward, :encounter_reward_gain_cost, :encounter_reward_confirm],
      show: [:ego_gift_get]
    )

    FakeWorld.react({:key, :space}, hide: [:ego_gift_get])

    assert Engine.goto(:encounter_reward, :encounter_reward_over) == {:ok, :encounter_reward_over}

    assert FakeWorld.inputs() == [
             {:click, :encounter_reward_gain_cost},
             {:click, :encounter_reward_confirm},
             {:key, :space},
             {:key, :enter}
           ]
  end
end
