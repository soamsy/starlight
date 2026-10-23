defmodule StarlightBot.Automation.LeafProgramsTest do
  use ExUnit.Case, async: false

  alias StarlightBot.Automation.{Scripts, SeasonPassCollector}
  alias StarlightBot.{Ctx, FakeWorld}
  alias StarlightBot.Navigation.Runner

  @moduletag :capture_log

  @season_pass_hooks [
    :season_pass_mission_tab_xp_available,
    :season_pass_claim_all_available,
    :season_pass_missions_tab,
    :season_pass_battle_pass,
    :season_pass_claim_all,
    :season_pass_claim_all_confirm
  ]

  describe "SeasonPassCollector" do
    test "claims visible xp and stops when nothing else is offered" do
      FakeWorld.start!(hooks: @season_pass_hooks, visible: [:season_pass_mission_tab_xp_available])
      FakeWorld.react({:click, :season_pass_mission_tab_xp_available}, hide: [:season_pass_mission_tab_xp_available])

      assert SeasonPassCollector.collect(Ctx.new()) == :ok
      assert FakeWorld.inputs() == [{:click, :season_pass_mission_tab_xp_available}]
    end

    test "claims everything through the battle pass tab when claim all is offered" do
      FakeWorld.start!(hooks: @season_pass_hooks, visible: [:season_pass_claim_all_available, :season_pass_missions_tab, :season_pass_battle_pass])
      FakeWorld.react({:click, :season_pass_battle_pass}, hide: [:season_pass_missions_tab], show: [:season_pass_claim_all])
      FakeWorld.react({:click, :season_pass_claim_all}, hide: [:season_pass_claim_all], show: [:season_pass_claim_all_confirm])
      FakeWorld.react({:click, :season_pass_claim_all_confirm}, hide: [:season_pass_claim_all_confirm])

      assert SeasonPassCollector.collect(Ctx.new()) == :ok

      assert FakeWorld.inputs() == [
               {:click, :season_pass_battle_pass},
               {:click, :season_pass_claim_all},
               {:click, :season_pass_claim_all_confirm}
             ]
    end
  end

  test "the mounting trials script confirms a full selection and leaves" do
    FakeWorld.start!(hooks: [:mounting_trials_1_of_1], visible: [:mounting_trials_1_of_1])
    FakeWorld.react({:click, :mounting_trials_1_of_1}, hide: [:mounting_trials_1_of_1])

    assert Runner.run_steps(Scripts.MountingTrials.program(), Ctx.new()) == {:ok, :mounting_trials_over}
    assert FakeWorld.inputs() == [{:click, :mounting_trials_1_of_1}]
  end
end
