defmodule StarlightBotWeb.Components.PlanPicker do
  use Phoenix.Component
  alias Phoenix.LiveView.JS
  alias StarlightBot.Teams

  attr :id, :string, required: true
  attr :items, :list, required: true
  attr :current_id, :integer, default: nil
  attr :name, :string, default: ""
  attr :noun, :string, required: true
  attr :label, :string, required: true

  def plan_picker(assigns) do
    ~H"""
    <div id={@id} class="relative" phx-click-away={JS.hide(to: "##{@id}-menu")}>
      <div class="join">
        <input type="text" value={@name} phx-blur={"rename_#{@noun}"} disabled={is_nil(@current_id)}
               class="input input-bordered input-sm join-item w-64 font-semibold"
               placeholder={"No #{@label} picked"} />
        <button type="button" phx-click={JS.toggle(to: "##{@id}-menu")}
                class="btn btn-sm join-item" title={"Switch, add, duplicate or delete #{@label}s"}>
          <%= length(@items) %> ▾
        </button>
      </div>
      <div id={"#{@id}-menu"} class="hidden absolute z-30 mt-1 w-96 rounded-box border border-base-300 bg-base-100 shadow-lg p-2">
        <div class="max-h-96 overflow-y-auto">
          <table class="table table-xs">
            <tbody>
              <tr :for={item <- @items}
                  phx-click={JS.push("select_#{@noun}", value: %{id: to_string(item.id)}) |> JS.hide(to: "##{@id}-menu")}
                  class={"cursor-pointer hover:bg-base-200 " <> if(@current_id == item.id, do: "bg-primary/10 border-l-2 border-primary", else: "")}>
                <td class="font-mono text-xs"><%= item.name %></td>
                <td class="text-right whitespace-nowrap">
                  <button phx-click={JS.push("duplicate_#{@noun}", value: %{id: to_string(item.id)}) |> JS.hide(to: "##{@id}-menu")}
                          class="btn btn-xs btn-ghost">Dup</button>
                  <button phx-click={"delete_#{@noun}"} phx-value-id={item.id} data-confirm={"Delete '#{item.name}'?"}
                          class="btn btn-xs btn-ghost text-error">Del</button>
                </td>
              </tr>
              <tr :if={@items == []}>
                <td colspan="2" class="text-center text-base-content/40 py-4">No <%= @label %>s yet.</td>
              </tr>
            </tbody>
          </table>
        </div>
        <button phx-click={JS.push("new_#{@noun}") |> JS.hide(to: "##{@id}-menu")} class="btn btn-primary btn-xs w-full mt-2">
          + New <%= @label %>
        </button>
      </div>
    </div>
    """
  end

  def link_team(%{assigns: %{team_id: team_id}} = socket, field) when is_integer(team_id) do
    Teams.set_plan(team_id, field, socket.assigns.editing_id)
    send(socket.parent_pid, :team_plans_changed)
    socket
  end

  def link_team(socket, _field), do: socket
end
