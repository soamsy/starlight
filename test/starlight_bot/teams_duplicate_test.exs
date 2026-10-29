defmodule StarlightBot.TeamsDuplicateTest do
  use ExUnit.Case, async: false

  alias StarlightBot.{Repo, Teams}

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

  test "the association teams are valid team types" do
    for type <- ~w(zwei shi cinq liu seven devyat dieci oufi fingers thumb index middle ring pinky), do: assert(type in Teams.team_types())
  end
end
