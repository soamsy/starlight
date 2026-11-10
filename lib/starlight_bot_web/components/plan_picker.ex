defmodule StarlightBotWeb.Components.PlanPicker do
  use Phoenix.Component
  import StarlightBotWeb.Components.Icon, only: [icon: 1]
  use Phoenix.VerifiedRoutes, endpoint: StarlightBotWeb.Endpoint, router: StarlightBotWeb.Router
  alias StarlightBot.{PlanClipboard, PlanCounts, PlanTemplates, Plans, Teams}

  attr :team_id, :integer, default: nil
  attr :pane, :string, required: true
  attr :counts, :map, default: %{}
  attr :on_page, :boolean, default: true

  def pane_tabs(assigns) do
    ~H"""
    <div :if={@team_id} class={["join shrink-0", !@on_page && "grayscale opacity-60 transition hover:opacity-100 hover:grayscale-0"]}>
      <.link :for={{pane, label, key} <- [{"battle", "Battle", "3"}, {"packs", "Packs", "4"}, {"gifts", "Gifts", "5"}, {"stats", "Stats", "6"}]}
             {pane_link(@on_page, ~p"/teams?team=#{@team_id}&pane=#{pane}")}
             data-hotkey={key}
             title={label}
             class={"btn btn-xs lg:btn-sm join-item " <> if(@on_page and @pane == pane, do: "btn-primary", else: "btn-outline")}>
        <img :if={pane == "stats"} src="/images/icons/starlight.webp" alt="Stats" class="h-4 w-4" style="filter: drop-shadow(1px 0 0 #000) drop-shadow(-1px 0 0 #000) drop-shadow(0 1px 0 #000) drop-shadow(0 -1px 0 #000);" />
        <.pane_icon :if={pane != "stats"} pane={pane} class="h-4 w-4" /><%= if pane != "stats", do: label %>
        <span :if={pane == "stats" and tab_count(@counts, pane)} class={["badge badge-xs badge-ghost font-mono", net_class(tab_count(@counts, pane))]}><%= tab_count(@counts, pane) %></span>
        <kbd class="kbd kbd-xs hidden lg:inline-flex"><%= key %></kbd>
      </.link>
    </div>
    """
  end

  defp pane_link(true, path), do: [patch: path]
  defp pane_link(false, path), do: [navigate: path]

  defp net_class("-" <> _), do: "text-error"
  defp net_class("+" <> _), do: "text-success"
  defp net_class(_text), do: nil

  defp tab_count(counts, "stats") do
    case counts[:starlight_net] do
      nil -> nil
      net -> StarlightBot.StarlightBudget.signed(net)
    end
  end

  defp tab_count(_counts, _pane), do: nil

  attr :pane, :string, required: true
  attr :class, :string, default: nil

  def pane_icon(assigns) do
    ~H"""
    <.icon name={pane_icon_name(@pane)} class={@class} />
    """
  end

  defp pane_icon_name("battle"), do: "lucide-swords"
  defp pane_icon_name("packs"), do: "lucide-layers"
  defp pane_icon_name("stats"), do: "lucide-chart-column"
  defp pane_icon_name("gifts"), do: "lucide-gift"

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
    %{data: data} = shown_plan(socket, table)
    text = PlanClipboard.encode(table, Teams.get_team(socket.assigns.team_id).name, data)
    socket |> Phoenix.LiveView.push_event("copy_plan_json", %{text: text}) |> Phoenix.LiveView.put_flash(:info, "Plan copied to the clipboard.")
  end

  defp shown_plan(%{assigns: %{template_id: template_id}}, _table) when is_integer(template_id), do: PlanTemplates.get(template_id)
  defp shown_plan(socket, table), do: Plans.get(table, socket.assigns.editing_id)

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

  def paste_plan(%{assigns: %{template_id: template_id}} = socket, _table, _field, _text, _load_plan) when is_integer(template_id) do
    Phoenix.LiveView.put_flash(socket, :error, "Choose your own plan in the Plans menu before pasting.")
  end

  def paste_plan(socket, table, field, text, load_plan) do
    case PlanClipboard.decode(text, table) do
      {:ok, data} -> socket |> apply_plan(table, field, data, load_plan, "Plan pasted.") |> Phoenix.Component.assign(:paste_status, :same)
      {:error, message} -> Phoenix.LiveView.put_flash(socket, :error, message)
    end
  end

  def apply_plan(socket, table, field, data, load_plan, success_message) do
    case Teams.paste_plan(socket.assigns.team_id, field, data) do
      {:ok, id} ->
        PlanCounts.broadcast(socket.assigns.team_id, table, data)
        socket = socket |> load_plan.(id) |> notify_parent() |> Phoenix.LiveView.put_flash(:info, success_message)

        case PlanClipboard.warnings(table, data) do
          [] -> socket
          warnings -> Phoenix.LiveView.put_flash(socket, :error, Enum.join(warnings, " "))
        end

      {:error, reason} ->
        Phoenix.LiveView.put_flash(socket, :error, "Replacing the plan failed: #{inspect(reason)}")
    end
  end
end
