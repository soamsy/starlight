defmodule StarlightBotWeb.Components.PlanTemplates do
  use Phoenix.Component
  alias Phoenix.LiveView.JS
  alias StarlightBot.{PlanTemplates, Plans}
  import StarlightBotWeb.Components.PlanPicker, only: [apply_plan: 6]

  attr :id, :string, required: true
  attr :templates, :list, required: true
  attr :editing, :integer, default: nil
  attr :label, :string, required: true
  attr :current_count, :integer, default: nil
  attr :status, :atom, default: :unknown

  def template_picker(assigns) do
    ~H"""
    <div id={@id} phx-hook="PlanClipboard" class="flex items-center gap-1">
      <button type="button" phx-click="copy_plan" class="btn btn-sm btn-square btn-outline" title={"Copy this #{@label} to the clipboard as JSON"}>
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="h-4 w-4">
          <rect width="14" height="14" x="8" y="8" rx="2" ry="2" />
          <path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2" />
        </svg>
      </button>
      <button type="button" data-paste-plan data-confirm={"Replace this #{@label} with the one on the clipboard?"}
              disabled={@status == :invalid} class="btn btn-sm btn-square btn-outline relative" title={paste_title(@status, @label)}>
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class={"h-4 w-4 " <> if(@status == :different, do: "text-success", else: "")}>
          <path d="M15 2H9a1 1 0 0 0-1 1v2c0 .6.4 1 1 1h6c.6 0 1-.4 1-1V3c0-.6-.4-1-1-1Z" />
          <path d="M8 4H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2" />
          <path d="M16 4h2a2 2 0 0 1 2 2v2" />
          <path d="M21 14H11" />
          <path d="m15 10-4 4 4 4" />
        </svg>
        <span :if={@status == :different} class="absolute -right-1 -top-1 h-2.5 w-2.5 rounded-full bg-success"></span>
      </button>
      <div class="relative" phx-click-away={JS.hide(to: "##{@id}-menu")}>
        <button type="button" phx-click={JS.toggle(to: "##{@id}-menu")} class="btn btn-sm btn-outline"
                title={"Load or delete #{@label} templates"}>
          Templates (<%= length(@templates) %>) ▾
        </button>
        <div id={"#{@id}-menu"} class="hidden absolute z-30 mt-1 w-[30rem] max-w-[90vw] rounded-box border border-base-300 bg-base-100 shadow-lg p-2">
          <div class="max-h-80 overflow-y-auto flex flex-col gap-0.5">
            <div :for={template <- @templates} class="flex items-center gap-1 rounded px-1 py-0.5 hover:bg-base-200">
              <input :if={@editing == template.id} id={"#{@id}-name-#{template.id}"} type="text" value={template.name}
                     phx-blur="template_rename" phx-value-id={template.id} phx-mounted={JS.focus()}
                     onfocus="this.select()" onkeydown="if (event.key === 'Enter') this.blur()"
                     class="input input-bordered input-xs flex-1 min-w-0 font-mono" />
              <div :if={@editing != template.id} class="flex-1 min-w-0 flex items-center gap-1.5">
                <span phx-dblclick="template_edit" phx-value-id={template.id} title="Double-click to rename"
                      class="min-w-0 truncate font-mono text-xs cursor-text select-none"><%= template.name %></span>
                <span class="badge badge-xs badge-ghost font-mono shrink-0"><%= template.count %></span>
              </div>
              <button type="button" phx-click="template_load" phx-value-id={template.id} class="btn btn-xs btn-outline btn-warning"
                      title={"Replace this team's #{@label} with this template"}
                      data-confirm={"Replace this team's #{@label} with the template '#{template.name}'? The current #{@label} will be lost."}>Load</button>
              <button type="button" phx-click="template_delete" phx-value-id={template.id} class="btn btn-xs btn-ghost text-error"
                      data-confirm={"Delete the template '#{template.name}'?"}>Del</button>
            </div>
            <div :if={@templates == []} class="px-2 py-3 text-center text-xs text-base-content/40">No <%= @label %> templates yet.</div>
          </div>
          <div class="my-2 border-t border-base-300"></div>
          <div class="flex items-center gap-1 px-1">
            <div class="flex-1 flex items-center gap-1.5">
              <span class="text-xs font-semibold">Current <%= @label %></span>
              <span :if={@current_count} class="badge badge-xs badge-ghost font-mono"><%= @current_count %></span>
            </div>
            <button type="button" phx-click="template_new" class="btn btn-xs btn-primary"
                    title={"Add a template holding a copy of this team's #{@label}"}>New from</button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp paste_title(:invalid, label), do: "The clipboard doesn't hold a #{label} that can be pasted here"
  defp paste_title(:same, label), do: "The clipboard holds the same #{label} as this one"
  defp paste_title(:different, label), do: "The clipboard holds a different #{label}, ready to paste"
  defp paste_title(:unknown, label), do: "Paste a #{label} from the clipboard"

  def assign_templates(socket, table) do
    assign(socket, templates: PlanTemplates.list(table), editing_template: nil)
  end

  def template_event(socket, "edit", %{"id" => id}, _table, _field, _load_plan) do
    assign(socket, :editing_template, String.to_integer(id))
  end

  def template_event(socket, "new", _params, table, _field, _load_plan) do
    %{data: data} = Plans.get(table, socket.assigns.editing_id)

    case PlanTemplates.create(table, data) do
      {:ok, id} -> socket |> refresh(table) |> assign(:editing_template, id)
      {:error, reason} -> flash_error(socket, "Create failed: #{inspect(reason)}")
    end
  end

  def template_event(socket, "rename", %{"id" => id, "value" => name}, table, _field, _load_plan) do
    socket = assign(socket, :editing_template, nil)

    case String.trim(name) do
      "" ->
        socket

      name ->
        case PlanTemplates.rename(String.to_integer(id), name) do
          {:ok, _} -> refresh(socket, table)
          {:error, :name_taken} -> flash_error(socket, "There is already a template called '#{name}'.")
          {:error, reason} -> flash_error(socket, "Rename failed: #{inspect(reason)}")
        end
    end
  end

  def template_event(socket, "delete", %{"id" => id}, table, _field, _load_plan) do
    PlanTemplates.delete(String.to_integer(id))
    refresh(socket, table)
  end

  def template_event(socket, "load", %{"id" => id}, table, field, load_plan) do
    case PlanTemplates.get(String.to_integer(id)) do
      %{name: name, data: data} when is_map(data) ->
        socket |> apply_plan(table, field, data, load_plan, "Loaded the template '#{name}'.") |> assign(:paste_status, :unknown)

      _ ->
        flash_error(socket, "That template is empty or gone.")
    end
  end

  defp refresh(socket, table), do: assign(socket, :templates, PlanTemplates.list(table))

  defp flash_error(socket, message), do: Phoenix.LiveView.put_flash(socket, :error, message)
end
