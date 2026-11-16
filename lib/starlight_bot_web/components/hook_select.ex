defmodule StarlightBotWeb.Components.HookSelect do
  use Phoenix.Component
  alias StarlightBot.Teams

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :selected, :string, default: nil
  attr :disabled, :boolean, default: false

  def hook_select(assigns) do
    assigns = assign(assigns, :groups, Teams.team_hooks())

    ~H"""
    <div :if={@disabled} class="w-24 shrink-0">
      <input type="hidden" name={@name} value={@selected || ""} />
      <div class="btn btn-sm btn-disabled w-full justify-start gap-1 px-2 font-normal">
        <img :if={@selected && Teams.hook_icon(@selected)} src={Teams.hook_icon(@selected)} class="size-4 object-contain shrink-0" />
        <span class="truncate"><%= if @selected, do: Teams.hook_label(@selected), else: "-" %></span>
      </div>
    </div>
    <details :if={not @disabled} id={@id} phx-hook="FloatingDropdown" data-keep-open data-close-on-click class="dropdown w-24 shrink-0">
      <input type="hidden" name={@name} value={@selected || ""} />
      <summary class="btn btn-sm btn-outline w-full justify-start gap-1 px-2 font-normal">
        <img :if={@selected && Teams.hook_icon(@selected)} src={Teams.hook_icon(@selected)} class="size-4 object-contain shrink-0" />
        <span class="truncate"><%= if @selected, do: Teams.hook_label(@selected), else: "-" %></span>
      </summary>
      <div popover="manual" class="dropdown-content z-50 max-h-[70vh] w-[32rem] max-w-[calc(100vw-1rem)] overflow-y-auto rounded-lg border border-base-300 bg-base-100 p-2 shadow-lg">
        <div class="columns-3 gap-3">
          <div :for={{group, hooks} <- @groups} class="mb-2 break-inside-avoid">
            <div class="px-1 pb-0.5 text-[10px] font-semibold uppercase tracking-wide text-base-content/50"><%= group %></div>
            <button :for={hook <- hooks} type="button" data-value={hook}
                    onclick="const i = this.closest('details').querySelector('input'); i.value = this.dataset.value; i.dispatchEvent(new Event('input', {bubbles: true}))"
                    class={"btn btn-xs w-full justify-start gap-1.5 font-mono " <> if(hook == @selected, do: "btn-primary", else: "btn-ghost")}>
              <img :if={Teams.hook_icon(hook)} src={Teams.hook_icon(hook)} class="size-4 object-contain" /><%= Teams.hook_label(hook) %>
            </button>
          </div>
        </div>
      </div>
    </details>
    """
  end
end
