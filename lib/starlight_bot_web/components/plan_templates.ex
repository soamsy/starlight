defmodule StarlightBotWeb.Components.PlanTemplates do
  use Phoenix.Component
  alias Phoenix.LiveView.JS
  alias StarlightBot.{PlanCounts, PlanTemplates, Plans, Teams}
  import StarlightBotWeb.Components.PlanPicker, only: [notify_parent: 1]

  @selectors ~w(phx-click phx-change phx-submit phx-keyup phx-keydown phx-blur)
  @controls ~w(button input select textarea [phx-click] [phx-change] [draggable=true] [phx-hook=SortableList]>* [phx-hook=PriorityRightClick] [phx-hook=DblClickEvent] [phx-hook=RightClickEvent] [phx-hook=GiftDragSource] [phx-hook=GiftDropZone])

  def blocked?(socket, event, allowed) do
    is_integer(socket.assigns[:template_id]) and event not in allowed and not String.starts_with?(event, "template_")
  end

  def read_only_guard(socket, allowed) do
    if Phoenix.LiveView.connected?(socket) do
      Phoenix.LiveView.attach_hook(socket, :read_only, :handle_event, fn event, _params, socket ->
        if blocked?(socket, event, allowed) do
          {:halt, Phoenix.LiveView.put_flash(socket, :error, "This team is using a template, which is read-only. Pick your own plan in the Plans menu to edit.")}
        else
          {:cont, socket}
        end
      end)
    else
      socket
    end
  end

  attr :container, :string, required: true
  attr :allowed, :list, required: true
  attr :template_id, :integer, default: nil
  attr :templates, :list, required: true
  attr :label, :string, required: true

  def read_only_banner(assigns) do
    assigns = assign(assigns, :template, Enum.find(assigns.templates, &(&1.id == assigns.template_id)))

    ~H"""
    <div :if={@template_id} role="alert" class="alert alert-info alert-soft py-1.5 px-3 text-xs flex items-center gap-2">
      <span>Using the read-only template <span class="font-semibold"><%= @template && @template.name %></span>.</span>
      <button type="button" phx-click="template_customize" class="btn btn-xs btn-primary"
              title={"Copy this template into a new #{@label} of your own that you can edit"}>Customize a copy</button>
    </div>
    <style :if={@template_id}>
      <%= Phoenix.HTML.raw(read_only_css(@container, @allowed)) %>
    </style>
    """
  end

  defp read_only_css(container, allowed) do
    disabled = Enum.map_join(@controls, ",", &"##{container} #{&1}")

    enabled =
      for attr <- @selectors, event <- ["lv:clear-flash" | allowed], selector <- ["##{container} [#{attr}=\"#{event}\"]", "##{container} [#{attr}=\"#{event}\"] *"], do: selector

    enabled = enabled ++ ["##{container} [phx-hook=PlanClipboard]", "##{container} [phx-hook=PlanClipboard] *", "##{container} [phx-click^=\"template_\"]", "##{container} [phx-click^=\"template_\"] *"]

    "#{disabled}{pointer-events:none}\n#{Enum.join(enabled, ",")}{pointer-events:auto}"
  end

  attr :id, :string, required: true
  attr :templates, :list, required: true
  attr :editing, :integer, default: nil
  attr :label, :string, required: true
  attr :current_count, :integer, default: nil
  attr :status, :atom, default: :unknown
  attr :selected, :integer, default: nil
  attr :plans, :list, default: []
  attr :plan_id, :integer, default: nil
  attr :editing_plan, :integer, default: nil

  def template_picker(assigns) do
    ~H"""
    <div id={@id} phx-hook="PlanClipboard" class="flex items-center gap-1">
      <button type="button" phx-click="copy_plan" class="btn btn-sm btn-square btn-outline" title={"Copy this #{@label} to the clipboard as JSON"}>
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="h-4 w-4">
          <rect width="14" height="14" x="8" y="8" rx="2" ry="2" />
          <path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2" />
        </svg>
      </button>
      <button type="button" data-paste-plan data-confirm-text={"Replace this #{@label} with the one on the clipboard?"}
              disabled={@status == :invalid or not is_nil(@selected)} class="btn btn-sm btn-square btn-outline relative" title={paste_title(@status, @label, @selected)}>
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
        <button type="button" phx-click={JS.toggle(to: "##{@id}-menu")} class="btn btn-sm btn-outline max-lg:px-2 max-lg:gap-1"
                title={"Choose which #{@label} this team uses"}>
          <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="h-4 w-4 lg:hidden">
            <rect width="18" height="7" x="3" y="3" rx="1" />
            <rect width="9" height="7" x="3" y="14" rx="1" />
            <rect width="5" height="7" x="16" y="14" rx="1" />
          </svg>
          <span class="max-lg:hidden">Plans</span>
          <span class="lg:before:content-['('] lg:after:content-[')']"><%= length(@templates) %></span>
          <span class="max-lg:hidden">▾</span>
        </button>
        <div id={"#{@id}-menu"} class="hidden absolute right-0 z-30 mt-1 w-[30rem] max-w-[90vw] rounded-box border border-base-300 bg-base-100 shadow-lg p-2">
          <div class="max-h-80 overflow-y-auto flex flex-col gap-0.5">
            <div :for={template <- @templates} class={["flex items-center gap-1 rounded px-1 py-0.5 hover:bg-base-200", @selected == template.id && "bg-primary/10"]}>
              <input :if={@editing == template.id} id={"#{@id}-name-#{template.id}"} type="text" value={template.name}
                     phx-blur="template_rename" phx-value-id={template.id} phx-mounted={JS.focus()}
                     onfocus="this.select()" onkeydown="if (event.key === 'Enter') this.blur()"
                     class="input input-bordered input-xs flex-1 min-w-0 font-mono" />
              <button :if={@editing != template.id} id={"#{@id}-template-#{template.id}"} type="button" phx-click="template_select" phx-value-id={template.id}
                      phx-hook={PlanTemplates.writable?() && "DblClickEvent"} data-event="template_edit" data-id={template.id}
                      title={if PlanTemplates.writable?(), do: "Use the template '#{template.name}' (read-only). Double-click to rename.", else: "Use the template '#{template.name}' (read-only)"}
                      class="flex-1 min-w-0 flex items-center gap-1.5 text-left">
                <span class="min-w-0 truncate font-mono text-xs"><%= template.name %></span>
                <span class="badge badge-xs badge-ghost font-mono shrink-0"><%= template.count %></span>
                <img :for={src <- template.icons} src={src} class={["h-5 w-5 shrink-0 object-contain", String.starts_with?(src, "/images/sinners/") && "sinner-icon"]} />
              </button>
              <span :if={@selected == template.id} class="text-xs text-primary shrink-0">in use</span>
              <button :if={PlanTemplates.writable?()} type="button" phx-click="template_delete" phx-value-id={template.id} class="btn btn-xs btn-ghost text-error"
                      data-confirm={"Delete the template '#{template.name}'?"}>Del</button>
            </div>
            <div :if={@templates == []} class="px-2 py-3 text-center text-xs text-base-content/40">No <%= @label %> templates yet.</div>
          </div>
          <div class="my-2 border-t border-base-300"></div>
          <div class="max-h-60 overflow-y-auto flex flex-col gap-0.5">
            <div :for={plan <- @plans} class={["flex items-center gap-1 rounded px-1 py-0.5 hover:bg-base-200", is_nil(@selected) && @plan_id == plan.id && "bg-primary/10"]}>
              <input :if={@editing_plan == plan.id} id={"#{@id}-plan-name-#{plan.id}"} type="text" value={plan.name}
                     phx-blur="template_plan_rename" phx-value-id={plan.id} phx-mounted={JS.focus()}
                     onfocus="this.select()" onkeydown="if (event.key === 'Enter') this.blur()"
                     class="input input-bordered input-xs flex-1 min-w-0 font-mono" />
              <button :if={@editing_plan != plan.id} id={"#{@id}-plan-#{plan.id}"} type="button" phx-click="template_plan" phx-value-id={plan.id}
                      phx-hook="DblClickEvent" data-event="template_plan_edit" data-id={plan.id}
                      title="Edit this plan. Double-click to rename." class="flex-1 min-w-0 flex items-center gap-1.5 text-left">
                <span class="min-w-0 truncate font-mono text-xs font-semibold"><%= plan.name %></span>
                <span class="badge badge-xs badge-ghost font-mono shrink-0"><%= if is_nil(@selected) and @plan_id == plan.id, do: @current_count || plan.count, else: plan.count %></span>
              </button>
              <span :if={is_nil(@selected) and @plan_id == plan.id} class="text-xs text-primary shrink-0">in use</span>
              <button :if={length(@plans) > 1} type="button" phx-click="template_plan_delete" phx-value-id={plan.id} class="btn btn-xs btn-ghost text-error"
                      data-confirm={"Delete the #{@label} '#{plan.name}'?"}>Del</button>
            </div>
          </div>
          <div class="mt-2 flex items-center gap-1 px-1">
            <button type="button" phx-click="template_plan_new" class="btn btn-xs btn-outline" title={"Add a blank #{@label} to this team"}>+ New plan</button>
            <button :if={PlanTemplates.writable?()} type="button" phx-click="template_new" class="btn btn-xs btn-primary ml-auto"
                    title={"Add a template holding a copy of this team's active #{@label}"}>Save as template</button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp paste_title(_status, label, selected) when not is_nil(selected), do: "Choose your own #{label} in the Plans menu to paste into it"
  defp paste_title(status, label, _selected), do: paste_title(status, label)
  defp paste_title(:invalid, label), do: "The clipboard doesn't hold a #{label} that can be pasted here"
  defp paste_title(:same, label), do: "The clipboard holds the same #{label} as this one"
  defp paste_title(:different, label), do: "The clipboard holds a different #{label}, ready to paste"
  defp paste_title(:unknown, label), do: "Paste a #{label} from the clipboard"

  def assign_templates(socket, table) do
    socket |> assign(templates: PlanTemplates.list(table), editing_template: nil, editing_plan: nil) |> refresh_plans(table)
  end

  defp refresh_plans(socket, table), do: assign(socket, :plans, Plans.list_for_team(table, socket.assigns.team_id))

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

  def template_event(socket, "delete", %{"id" => id}, table, field, load_plan) do
    id = String.to_integer(id)
    PlanTemplates.delete(id)
    socket = refresh(socket, table)

    if socket.assigns[:template_id] == id,
      do: use_plan(socket, table, field, socket.assigns.editing_id, load_plan),
      else: socket
  end

  def template_event(%{assigns: %{team_id: team_id, editing_id: plan_id}} = socket, "select", %{"id" => id}, table, field, load_plan) when is_integer(team_id) and is_integer(plan_id) do
    template_id = String.to_integer(id)
    kind = Atom.to_string(table)

    case PlanTemplates.get(template_id) do
      %{kind: ^kind, data: %{} = data} ->
        {:ok, _} = Teams.set_template(team_id, field, template_id)
        PlanCounts.broadcast(team_id, table, data)
        socket |> load_plan.(plan_id, template_id) |> notify_parent() |> assign(:paste_status, :unknown)

      _ ->
        flash_error(socket, "That template is empty or gone.")
    end
  end

  def template_event(socket, "select", _params, _table, _field, _load_plan), do: flash_error(socket, "Plans can only be chosen for a team.")

  def template_event(%{assigns: %{team_id: team_id}} = socket, "plan", %{"id" => id}, table, field, load_plan) when is_integer(team_id) do
    plan_id = String.to_integer(id)

    if Plans.owned_by?(table, plan_id, team_id),
      do: use_plan(socket, table, field, plan_id, load_plan),
      else: flash_error(socket, "That plan doesn't belong to this team.")
  end

  def template_event(%{assigns: %{team_id: team_id}} = socket, "plan_new", _params, table, field, load_plan) when is_integer(team_id) do
    attrs = %{name: Plans.new_name(table, team_id), data: Plans.blank(table), team_id: team_id}

    case Plans.save(table, attrs) do
      {:ok, plan_id} -> use_plan(socket, table, field, plan_id, load_plan)
      {:error, reason} -> flash_error(socket, "Create failed: #{inspect(reason)}")
    end
  end

  def template_event(%{assigns: %{team_id: team_id, template_id: template_id}} = socket, "customize", _params, table, field, load_plan) when is_integer(team_id) and is_integer(template_id) do
    case PlanTemplates.get(template_id) do
      %{name: name, data: %{} = data} ->
        attrs = %{name: Plans.unique_name(table, name), data: data, team_id: team_id}

        case Plans.save(table, attrs) do
          {:ok, plan_id} -> socket |> use_plan(table, field, plan_id, load_plan) |> Phoenix.LiveView.put_flash(:info, "Copied the template '#{name}' into '#{attrs.name}'.")
          {:error, reason} -> flash_error(socket, "Customize failed: #{inspect(reason)}")
        end

      _ ->
        flash_error(socket, "That template is empty or gone.")
    end
  end

  def template_event(socket, "customize", _params, _table, _field, _load_plan), do: socket

  def template_event(socket, "plan_edit", %{"id" => id}, _table, _field, _load_plan), do: assign(socket, :editing_plan, String.to_integer(id))

  def template_event(%{assigns: %{team_id: team_id}} = socket, "plan_rename", %{"id" => id, "value" => name}, table, _field, _load_plan) do
    socket = assign(socket, :editing_plan, nil)
    plan_id = String.to_integer(id)

    case String.trim(name) do
      "" ->
        socket

      name ->
        with true <- Plans.owned_by?(table, plan_id, team_id),
             {:ok, _} <- Plans.rename(table, plan_id, name) do
          socket = if socket.assigns.editing_id == plan_id and is_nil(socket.assigns.template_id), do: assign(socket, :name, name), else: socket
          refresh_plans(socket, table)
        else
          {:error, :name_taken} -> flash_error(socket, "There is already a plan called '#{name}'.")
          _ -> flash_error(socket, "Rename failed.")
        end
    end
  end

  def template_event(%{assigns: %{team_id: team_id}} = socket, "plan_delete", %{"id" => id}, table, field, load_plan) when is_integer(team_id) do
    plan_id = String.to_integer(id)

    with true <- Plans.owned_by?(table, plan_id, team_id),
         [_, _ | _] = plans <- Plans.list_for_team(table, team_id) do
      {:ok, _} = Plans.delete(table, plan_id)
      socket = refresh_plans(socket, table)

      if socket.assigns.editing_id == plan_id do
        %{id: next} = Enum.find(plans, &(&1.id != plan_id))
        {:ok, _} = Teams.set_plan(team_id, field, next)
        socket |> load_plan.(next, socket.assigns.template_id) |> notify_parent()
      else
        socket
      end
    else
      _ -> flash_error(socket, "A team keeps at least one plan.")
    end
  end

  defp use_plan(%{assigns: %{team_id: team_id}} = socket, table, field, plan_id, load_plan) do
    {:ok, _} = Teams.set_plan(team_id, field, plan_id)
    {:ok, _} = Teams.set_template(team_id, field, nil)
    %{data: data} = Plans.get(table, plan_id)
    PlanCounts.broadcast(team_id, table, data)
    socket |> refresh_plans(table) |> load_plan.(plan_id, nil) |> notify_parent() |> assign(:paste_status, :unknown)
  end

  defp refresh(socket, table), do: assign(socket, :templates, PlanTemplates.list(table))

  defp flash_error(socket, message), do: Phoenix.LiveView.put_flash(socket, :error, message)
end
