defmodule StarlightBot.PlanCountsTest do
  use ExUnit.Case, async: false

  alias StarlightBot.{BattlePlans, GiftPlans, PlanCounts, Plans, Repo, Teams}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  test "battle counts every playbook" do
    assert PlanCounts.count(:battle_plans, BattlePlans.blank()) == 2
  end

  test "pack counts hunted packs across modes" do
    data = %{
      "packs" => %{
        "thm_1" => %{"normal" => %{"priority" => "hunt"}, "hard" => %{"priority" => "hunt"}},
        "thm_2" => %{"normal" => %{"priority" => "banned"}},
        "thm_3" => %{"hard" => %{"floors" => [3]}}
      }
    }

    assert PlanCounts.count(:pack_plans, data) == 2
  end

  test "gift counts entries across all milestones" do
    data = %{"milestones" => [%{"entries" => [1, 2]}, %{"entries" => []}, %{"entries" => [3]}, %{}]}
    assert PlanCounts.count(:gift_plans, data) == 3
    assert PlanCounts.count(:gift_plans, GiftPlans.blank()) == 0
  end

  test "unreadable data counts as zero" do
    assert PlanCounts.count(:battle_plans, nil) == 0
    assert PlanCounts.count(:pack_plans, %{}) == 0
  end

  test "for_team reads each of the team's plans" do
    {:ok, id} = Teams.create_default_team()
    assert PlanCounts.for_team(id) == %{battle_plans: 2, pack_plans: 0, gift_plans: 0}
    assert PlanCounts.for_team(nil) == %{}
  end

  test "broadcast delivers the new count to subscribers" do
    PlanCounts.subscribe()
    PlanCounts.broadcast(7, :battle_plans, BattlePlans.blank())
    assert_receive {:plan_count, 7, :battle_plans, 2}
    assert Plans.blank(:pack_plans) |> then(&PlanCounts.count(:pack_plans, &1)) == 0
  end
end
