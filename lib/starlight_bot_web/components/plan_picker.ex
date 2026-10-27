defmodule StarlightBotWeb.Components.PlanPicker do
  use Phoenix.Component
  use Phoenix.VerifiedRoutes, endpoint: StarlightBotWeb.Endpoint, router: StarlightBotWeb.Router
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

  attr :team_id, :integer, default: nil
  attr :pane, :string, required: true

  def pane_tabs(assigns) do
    ~H"""
    <div :if={@team_id} class="join shrink-0">
      <.link :for={{pane, label} <- [{"battle", "Battle"}, {"packs", "Packs"}, {"gifts", "Gifts"}, {"stats", "Stats"}]}
             patch={~p"/teams?team=#{@team_id}&pane=#{pane}"}
             title={label}
             class={"btn btn-sm join-item " <> if(@pane == pane, do: "btn-primary", else: "btn-outline")}>
        <.pane_icon pane={pane} class="h-4 w-4" /><%= if pane != "stats", do: label %>
      </.link>
    </div>
    """
  end

  attr :pane, :string, required: true
  attr :class, :string, default: nil

  def pane_icon(assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class={@class}>
      <%= case @pane do %>
        <% "battle" -> %>
          <polyline points="14.5 17.5 3 6 3 3 6 3 17.5 14.5" />
          <line x1="13" x2="19" y1="19" y2="13" />
          <line x1="16" x2="20" y1="16" y2="20" />
          <line x1="19" x2="21" y1="21" y2="19" />
          <polyline points="14.5 6.5 18 3 21 3 21 6 17.5 9.5" />
          <line x1="5" x2="9" y1="14" y2="18" />
          <line x1="7" x2="4" y1="17" y2="20" />
          <line x1="3" x2="5" y1="19" y2="21" />
        <% "packs" -> %>
          <path d="m12.83 2.18a2 2 0 0 0-1.66 0L2.6 6.08a1 1 0 0 0 0 1.83l8.58 3.91a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83Z" />
          <path d="m22 17.65-9.17 4.16a2 2 0 0 1-1.66 0L2 17.65" />
          <path d="m22 12.65-9.17 4.16a2 2 0 0 1-1.66 0L2 12.65" />
        <% "stats" -> %>
          <path d="M3 3v16a2 2 0 0 0 2 2h16" />
          <path d="M18 17V9" />
          <path d="M13 17V5" />
          <path d="M8 17v-3" />
        <% "gifts" -> %>
          <rect x="3" y="8" width="18" height="4" rx="1" />
          <path d="M12 8v13" />
          <path d="M19 12v7a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2v-7" />
          <path d="M7.5 8a2.5 2.5 0 0 1 0-5A4.8 8 0 0 1 12 8a4.8 8 0 0 1 4.5-5 2.5 2.5 0 0 1 0 5" />
      <% end %>
    </svg>
    """
  end

  def link_team(%{assigns: %{team_id: team_id}} = socket, field) when is_integer(team_id) do
    Teams.set_plan(team_id, field, socket.assigns.editing_id)
    send(socket.parent_pid, :team_plans_changed)
    socket
  end

  def link_team(socket, _field), do: socket
end
