defmodule StarlightBot.TeamTemplatesTest do
  use ExUnit.Case, async: false

  alias StarlightBot.{BattlePlans, PlanTemplates, Plans, Teams}

  setup do
    :ok = StarlightBot.TestDB.checkout()
  end

  defp team_with_battle_plan do
    {:ok, id} = Teams.create_default_team()
    {:ok, ^id} = Teams.save_team(%{Teams.get_team(id) | notes: "some notes"})
    plan_id = Teams.get_team(id).battle_plan_id
    data = Map.put(BattlePlans.blank(), "marker", "custom")
    {:ok, _} = Plans.save(:battle_plans, %{id: plan_id, name: Plans.get(:battle_plans, plan_id).name, data: data})
    id
  end

  test "templatize moves the team and its customized plans into base.db" do
    id = team_with_battle_plan()
    {:ok, ^id} = Teams.templatize(id)

    assert Teams.get_team(id) == nil
    assert Enum.all?(Teams.list_teams(), &(&1.id != id))

    assert [template] = Enum.filter(Teams.list_all_teams(), & &1.template)
    assert template.id < 0
    assert template.notes == "some notes"
    assert %{data: %{"marker" => "custom"}} = Plans.for_team(Teams.get_team(template.id), :battle_plans)
  end

  test "templatize reuses plan templates a team already references" do
    {:ok, plan_template} = PlanTemplates.create(:battle_plans, Map.put(BattlePlans.blank(), "marker", "shared"))
    {:ok, id} = Teams.create_default_team()
    {:ok, _} = Teams.set_template(id, :battle_plan_id, plan_template)
    {:ok, ^id} = Teams.templatize(id)

    [template] = Enum.filter(Teams.list_all_teams(), & &1.template)
    assert Teams.get_team(template.id).battle_template_id == plan_template
  end

  test "template teams are editable while authoring, cannot be duplicated, and can be created from" do
    id = team_with_battle_plan()
    {:ok, _} = Teams.templatize(id)
    [template] = Enum.filter(Teams.list_all_teams(), & &1.template)

    assert Teams.get_team(template.id).template
    assert {:ok, _} = Teams.save_team(%{Teams.get_team(template.id) | name: "Renamed", notes: "edited"})
    assert %{name: "Renamed", notes: "edited"} = Teams.get_team(template.id)
    assert {:error, :template_locked} = Teams.duplicate_team(template.id)

    {:ok, new_id} = Teams.create_from_template(template.id)
    copy = Teams.get_team(new_id)
    refute copy.template
    assert copy.notes == "edited"
    assert %{data: %{"marker" => "custom"}} = Plans.for_team(copy, :battle_plans)
    assert {:ok, ^new_id} = Teams.save_team(%{id: new_id, name: "Mine"})
  end

  test "create_from_template rejects user teams" do
    {:ok, id} = Teams.create_default_team()
    assert {:error, :not_found} = Teams.create_from_template(id)
  end

  test "template teams can be deleted while authoring" do
    id = team_with_battle_plan()
    {:ok, _} = Teams.templatize(id)
    [template] = Enum.filter(Teams.list_all_teams(), & &1.template)
    assert {:ok, _} = Teams.delete_team(template.id)
    assert Teams.get_team(template.id) == nil
  end

  test "duplicate copies notes" do
    id = team_with_battle_plan()
    {:ok, new_id} = Teams.duplicate_team(id)
    assert Teams.get_team(new_id).notes == "some notes"
  end

  test "plan template listing counts the teams that use it" do
    {:ok, plan_template} = PlanTemplates.create(:battle_plans, BattlePlans.blank())
    {:ok, a} = Teams.create_default_team()
    {:ok, b} = Teams.create_default_team()
    {:ok, _} = Teams.set_template(a, :battle_plan_id, plan_template)
    {:ok, _} = Teams.set_template(b, :battle_plan_id, plan_template)
    {:ok, ^b} = Teams.templatize(b)

    assert %{teams: 2, template_teams: 1} = Enum.find(PlanTemplates.list(:battle_plans), &(&1.id == plan_template))
  end
end
