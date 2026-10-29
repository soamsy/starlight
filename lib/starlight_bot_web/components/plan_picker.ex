defmodule StarlightBotWeb.Components.PlanPicker do
  use Phoenix.Component
  use Phoenix.VerifiedRoutes, endpoint: StarlightBotWeb.Endpoint, router: StarlightBotWeb.Router
  alias StarlightBot.{PlanClipboard, PlanCounts, Plans, Teams}

  attr :label, :string, required: true
  attr :status, :atom, default: :unknown

  def plan_clipboard(assigns) do
    ~H"""
    <div id={"plan-clipboard-#{String.replace(@label, " ", "-")}"} phx-hook="PlanClipboard" class="flex items-center gap-2">
      <button type="button" phx-click="copy_plan" class="btn btn-sm btn-outline" title={"Copy this #{@label} to the clipboard as JSON"}>Copy plan</button>
      <button type="button" data-paste-plan data-confirm={"Replace this #{@label} with the one on the clipboard?"}
              disabled={@status == :invalid} class="btn btn-sm btn-outline gap-1"
              title={paste_title(@status, @label)}>
        <svg :if={@status == :different} xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="h-4 w-4 text-success">
          <rect width="8" height="4" x="8" y="2" rx="1" ry="1" />
          <path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2" />
          <path d="m9 14 2 2 4-4" />
        </svg>
        Paste plan
      </button>
    </div>
    """
  end

  defp paste_title(:invalid, label), do: "The clipboard doesn't hold a #{label} that can be pasted here"
  defp paste_title(:same, label), do: "The clipboard holds the same #{label} as this one"
  defp paste_title(:different, label), do: "The clipboard holds a different #{label}, ready to paste"
  defp paste_title(:unknown, label), do: "Paste a #{label} from the clipboard"

  attr :team_id, :integer, default: nil
  attr :pane, :string, required: true
  attr :counts, :map, default: %{}

  def pane_tabs(assigns) do
    ~H"""
    <div :if={@team_id} class="join shrink-0">
      <.link :for={{pane, label} <- [{"battle", "Battle"}, {"packs", "Packs"}, {"gifts", "Gifts"}, {"stats", "Stats"}]}
             patch={~p"/teams?team=#{@team_id}&pane=#{pane}"}
             title={label}
             class={"btn btn-sm join-item " <> if(@pane == pane, do: "btn-primary", else: "btn-outline")}>
        <.pane_icon pane={pane} class="h-4 w-4" /><%= if pane != "stats", do: label %>
        <span :if={tab_count(@counts, pane)} class="badge badge-xs badge-ghost font-mono"><%= tab_count(@counts, pane) %></span>
      </.link>
    </div>
    """
  end

  defp tab_count(counts, "battle"), do: counts[:battle_plans]
  defp tab_count(counts, "packs"), do: counts[:pack_plans]
  defp tab_count(counts, "gifts"), do: counts[:gift_plans]
  defp tab_count(_counts, _pane), do: nil

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
    notify_parent(socket)
  end

  def link_team(socket, _field), do: socket

  def broadcast_count(socket, table, data) do
    PlanCounts.broadcast(socket.assigns.team_id, table, data)
    socket
  end

  def notify_parent(%{parent_pid: parent} = socket) when is_pid(parent) do
    send(parent, :team_plans_changed)
    socket
  end

  def notify_parent(socket), do: socket

  def copy_plan(socket, table) do
    %{data: data} = Plans.get(table, socket.assigns.editing_id)
    text = PlanClipboard.encode(table, Teams.get_team(socket.assigns.team_id).name, data)
    socket |> Phoenix.LiveView.push_event("copy_plan_json", %{text: text}) |> Phoenix.LiveView.put_flash(:info, "Plan copied to the clipboard.")
  end

  def paste_status(socket, table, text) do
    Phoenix.Component.assign(socket, :paste_status, status_of(socket.assigns.editing_id, table, text))
  end

  defp status_of(_plan_id, _table, nil), do: :unknown
  defp status_of(nil, _table, _text), do: :invalid

  defp status_of(plan_id, table, text) do
    case PlanClipboard.decode(text, table) do
      {:ok, data} -> if Plans.get(table, plan_id).data == data, do: :same, else: :different
      {:error, _} -> :invalid
    end
  end

  def paste_plan(socket, table, field, text, load_plan) do
    with {:ok, data} <- PlanClipboard.decode(text, table),
         {:ok, id} <- Teams.paste_plan(socket.assigns.team_id, field, data) do
      PlanCounts.broadcast(socket.assigns.team_id, table, data)
      socket = socket |> load_plan.(id) |> notify_parent() |> Phoenix.Component.assign(:paste_status, :same) |> Phoenix.LiveView.put_flash(:info, "Plan pasted.")

      case PlanClipboard.warnings(table, data) do
        [] -> socket
        warnings -> Phoenix.LiveView.put_flash(socket, :error, Enum.join(warnings, " "))
      end
    else
      {:error, message} when is_binary(message) -> Phoenix.LiveView.put_flash(socket, :error, message)
      {:error, reason} -> Phoenix.LiveView.put_flash(socket, :error, "Paste failed: #{inspect(reason)}")
    end
  end
end
