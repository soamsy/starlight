defmodule StarlightBot.PlanTemplatesTest do
  use ExUnit.Case, async: false

  alias StarlightBot.{PlanTemplates, Plans, Teams}
  alias StarlightBotWeb.Live.PackPlanEditorLive, as: Live

  setup do
    :ok = StarlightBot.TestDB.checkout()
  end

  test "templates are listed per kind with unique default names" do
    {:ok, first} = PlanTemplates.create(:pack_plans, %{"a" => 1})
    {:ok, second} = PlanTemplates.create(:pack_plans, %{"b" => 2})
    {:ok, _} = PlanTemplates.create(:gift_plans, %{})

    assert PlanTemplates.list(:pack_plans) == [%{id: first, name: "New template", count: 0, icons: []}, %{id: second, name: "New template 2", count: 0, icons: []}]
    assert PlanTemplates.get(second).data == %{"b" => 2}
    assert length(PlanTemplates.list(:gift_plans)) == 1
  end

  test "listed templates carry the same rough count as the tabs" do
    {:ok, _} = PlanTemplates.create(:battle_plans, StarlightBot.BattlePlans.blank())
    {:ok, _} = PlanTemplates.create(:pack_plans, %{"packs" => %{"thm_1" => %{"normal" => %{"1" => "hunt"}}}})
    {:ok, _} = PlanTemplates.create(:gift_plans, %{"milestones" => [%{"entries" => [1, 2, 3]}]})

    assert [%{count: 3}] = PlanTemplates.list(:battle_plans)
    assert [%{count: 1}] = PlanTemplates.list(:pack_plans)
    assert [%{count: 3}] = PlanTemplates.list(:gift_plans)
  end

  test "rename refuses a name already used by the same kind" do
    {:ok, first} = PlanTemplates.create(:pack_plans, %{})
    {:ok, second} = PlanTemplates.create(:pack_plans, %{})

    assert {:ok, _} = PlanTemplates.rename(first, "Hunt all")
    assert PlanTemplates.rename(second, "Hunt all") == {:error, :name_taken}
    assert {:ok, _} = PlanTemplates.rename(first, "Hunt all")
  end

  test "pane flow: new snapshots the plan, templates stay as saved, selecting references the template" do
    {:ok, team} = Teams.create_default_team()
    plan_id = Teams.get_team(team).pack_plan_id
    original = Plans.get(:pack_plans, plan_id).data
    bare = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
    {:ok, socket} = Live.mount(%{}, %{"team_id" => team}, bare)
    event = fn socket, name, params -> elem(Live.handle_event(name, params, socket), 1) end

    socket = event.(socket, "template_new", %{})
    template_id = socket.assigns.editing_template
    id = to_string(template_id)
    assert PlanTemplates.get(template_id).data == original

    socket = event.(socket, "template_rename", %{"id" => id, "value" => "Floor five"})
    assert socket.assigns.editing_template == nil
    assert Enum.map(socket.assigns.templates, & &1.name) == ["Floor five"]

    socket = event.(socket, "template_edit", %{"id" => id})
    assert socket.assigns.editing_template == template_id

    changed = Map.put(original, "search_floors", [5])
    {:ok, _} = Plans.save(:pack_plans, %{id: plan_id, name: Plans.get(:pack_plans, plan_id).name, data: changed})
    socket = event.(socket, "template_new", %{})
    assert PlanTemplates.get(socket.assigns.editing_template).data == changed
    assert PlanTemplates.get(template_id).data == original

    assert Plans.get(:pack_plans, plan_id).data == changed
    socket = event.(socket, "template_select", %{"id" => id})
    assert Plans.get(:pack_plans, plan_id).data == changed
    assert socket.assigns.template_id == template_id
    assert socket.assigns.plan_data == original
    assert Teams.get_team(team).pack_template_id == template_id
    assert Plans.for_team(Teams.get_team(team), :pack_plans).data == original

    socket = event.(socket, "toggle_search_floor", %{"floor" => "5"})
    assert Plans.get(:pack_plans, plan_id).data == changed
    assert PlanTemplates.get(template_id).data == original

    socket = event.(socket, "template_plan", %{"id" => to_string(plan_id)})
    assert socket.assigns.template_id == nil
    assert socket.assigns.plan_data == changed
    assert Teams.get_team(team).pack_template_id == nil
    assert Plans.for_team(Teams.get_team(team), :pack_plans).data == changed

    socket = event.(socket, "template_new", %{})
    assert Enum.map(socket.assigns.templates, & &1.name) == ["Floor five", "New template", "New template 2"]

    socket = event.(socket, "template_rename", %{"id" => to_string(socket.assigns.editing_template), "value" => "Floor five"})
    assert socket.assigns.flash["error"] =~ "already a template"

    socket = event.(socket, "template_select", %{"id" => id})
    socket = event.(socket, "template_delete", %{"id" => id})
    assert Enum.map(socket.assigns.templates, & &1.name) == ["New template", "New template 2"]
    assert socket.assigns.template_id == nil
    assert Plans.for_team(Teams.get_team(team), :pack_plans).data == changed
  end

  test "a team keeps several plans, can customize a template into one, and keeps at least one" do
    {:ok, team} = Teams.create_default_team()
    {:ok, other} = Teams.create_default_team()
    first = Teams.get_team(team).pack_plan_id
    foreign = Teams.get_team(other).pack_plan_id
    {:ok, template} = PlanTemplates.create(:pack_plans, %{"mode_schedule" => [], "packs" => %{}, "search_floors" => [7]})
    bare = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
    {:ok, socket} = Live.mount(%{}, %{"team_id" => team}, bare)
    event = fn socket, name, params -> elem(Live.handle_event(name, params, socket), 1) end

    socket = event.(socket, "template_plan_new", %{})
    second = Teams.get_team(team).pack_plan_id
    assert second != first
    assert Enum.sort(Enum.map(socket.assigns.plans, & &1.id)) == Enum.sort([first, second])
    assert socket.assigns.editing_id == second

    socket = event.(socket, "template_plan", %{"id" => to_string(foreign)})
    assert Teams.get_team(team).pack_plan_id == second
    assert socket.assigns.flash["error"] =~ "doesn't belong"

    socket = event.(socket, "template_select", %{"id" => to_string(template)})
    socket = event.(socket, "template_customize", %{})
    copy = Teams.get_team(team).pack_plan_id
    assert copy not in [first, second]
    assert socket.assigns.template_id == nil
    assert Teams.get_team(team).pack_template_id == nil
    assert Plans.get(:pack_plans, copy).data["search_floors"] == [7]
    assert PlanTemplates.get(template).data["search_floors"] == [7]
    assert length(socket.assigns.plans) == 3

    socket = event.(socket, "template_plan_delete", %{"id" => to_string(copy)})
    assert Teams.get_team(team).pack_plan_id in [first, second]
    assert length(socket.assigns.plans) == 2

    socket = event.(socket, "template_plan_delete", %{"id" => to_string(first)})
    socket = event.(socket, "template_plan_delete", %{"id" => to_string(second)})
    assert socket.assigns.flash["error"] =~ "at least one"
    assert length(Plans.list_for_team(:pack_plans, team)) == 1

    {:ok, copy_team} = Teams.duplicate_team(team)
    assert length(Plans.list_for_team(:pack_plans, copy_team)) == 1
    assert Plans.owned_by?(:pack_plans, Teams.get_team(copy_team).pack_plan_id, copy_team)
  end

  test "a template of another kind or a deleted one falls back to the team's own plan" do
    {:ok, team} = Teams.create_default_team()
    own = Plans.get(:pack_plans, Teams.get_team(team).pack_plan_id).data
    {:ok, gift_template} = PlanTemplates.create(:gift_plans, %{"milestones" => []})
    {:ok, pack_template} = PlanTemplates.create(:pack_plans, %{"search_floors" => [3]})

    {:ok, _} = Teams.set_template(team, :pack_plan_id, gift_template)
    assert Plans.for_team(Teams.get_team(team), :pack_plans).data == own

    {:ok, _} = Teams.set_template(team, :pack_plan_id, pack_template)
    assert %{template_id: ^pack_template, data: %{"search_floors" => [3]}} = Plans.for_team(Teams.get_team(team), :pack_plans)

    {:ok, _} = PlanTemplates.delete(pack_template)
    assert %{template_id: nil, data: ^own} = Plans.for_team(Teams.get_team(team), :pack_plans)
  end

  test "read-only mode blocks edits and allows browsing" do
    allowed = Live.read_only_events()
    template = %Phoenix.LiveView.Socket{assigns: %{template_id: 4}}
    custom = %Phoenix.LiveView.Socket{assigns: %{template_id: nil}}

    assert StarlightBotWeb.Components.PlanTemplates.blocked?(template, "toggle_cell", allowed)
    assert StarlightBotWeb.Components.PlanTemplates.blocked?(template, "paste_plan", allowed)
    refute StarlightBotWeb.Components.PlanTemplates.blocked?(template, "set_view", allowed)
    refute StarlightBotWeb.Components.PlanTemplates.blocked?(template, "template_select", allowed)
    refute StarlightBotWeb.Components.PlanTemplates.blocked?(custom, "toggle_cell", allowed)
  end
end
