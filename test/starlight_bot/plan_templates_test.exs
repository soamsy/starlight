defmodule StarlightBot.PlanTemplatesTest do
  use ExUnit.Case, async: false

  alias StarlightBot.{PlanTemplates, Plans, Repo, Teams}
  alias StarlightBotWeb.Live.PackPlanEditorLive, as: Live

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
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
    {:ok, _} = PlanTemplates.create(:pack_plans, %{"packs" => %{"thm_1" => %{"normal" => %{"priority" => "hunt"}}}})
    {:ok, _} = PlanTemplates.create(:gift_plans, %{"milestones" => [%{"entries" => [1, 2, 3]}]})

    assert [%{count: 2}] = PlanTemplates.list(:battle_plans)
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

  test "pane flow: new snapshots the plan, templates stay as saved, load replaces the team's plan" do
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
    socket = event.(socket, "template_load", %{"id" => id})
    assert Plans.get(:pack_plans, plan_id).data == original
    assert socket.assigns.flash["info"] =~ "Loaded the template"

    socket = event.(socket, "template_new", %{})
    assert Enum.map(socket.assigns.templates, & &1.name) == ["Floor five", "New template", "New template 2"]

    socket = event.(socket, "template_rename", %{"id" => to_string(socket.assigns.editing_template), "value" => "Floor five"})
    assert socket.assigns.flash["error"] =~ "already a template"

    socket = event.(socket, "template_delete", %{"id" => id})
    assert Enum.map(socket.assigns.templates, & &1.name) == ["New template", "New template 2"]
  end
end
