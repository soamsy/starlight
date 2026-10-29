defmodule StarlightBot.TeamsDuplicateTest do
  use ExUnit.Case, async: false

  alias StarlightBot.{Plans, Repo, Teams}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  test "duplicate_team copies the hooks and plans under a unique name" do
    {:ok, id} = Teams.save_team(%{name: "Saikai", hooks: ["team_slash", "team_pierce"], battle_plan_id: 7})

    {:ok, copy_id} = Teams.duplicate_team(id)
    {:ok, second_id} = Teams.duplicate_team(id)

    copy = Teams.get_team(copy_id)
    assert copy.name == "Saikai (copy)"
    assert copy.hooks == ["team_slash", "team_pierce"]
    assert Teams.get_team(second_id).name == "Saikai (copy) 2"
  end

  test "duplicate_team reports a missing team" do
    assert Teams.duplicate_team(-1) == {:error, :not_found}
  end

  test "new teams get their own blank plans" do
    {:ok, first} = Teams.create_default_team()
    {:ok, second} = Teams.create_default_team()
    plan_ids = fn id -> id |> Teams.get_team() |> Map.take([:gift_plan_id, :battle_plan_id, :pack_plan_id]) |> Map.values() end

    assert Enum.all?(plan_ids.(first), &is_integer/1)
    assert MapSet.disjoint?(MapSet.new(plan_ids.(first)), MapSet.new(plan_ids.(second)))
  end

  test "duplicating a team gives the copy its own plans" do
    {:ok, id} = Teams.create_default_team()
    {:ok, copy_id} = Teams.duplicate_team(id)

    team = Teams.get_team(id)
    copy = Teams.get_team(copy_id)
    for field <- [:gift_plan_id, :battle_plan_id, :pack_plan_id], do: assert(team[field] != copy[field])
  end

  test "deleting a team deletes its plans" do
    {:ok, id} = Teams.create_default_team()
    team = Teams.get_team(id)
    {:ok, _} = Teams.delete_team(id)

    assert Plans.get(:gift_plans, team.gift_plan_id) == nil
    assert Plans.get(:battle_plans, team.battle_plan_id) == nil
    assert Plans.get(:pack_plans, team.pack_plan_id) == nil
  end

  test "the association teams are valid team types" do
    for type <- ~w(zwei shi cinq liu seven devyat dieci oufi fingers thumb index middle ring pinky), do: assert(type in Teams.team_types())
  end
end
