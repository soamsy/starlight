defmodule StarlightBotWeb.Components.HookSelect do
  use Phoenix.Component
  alias StarlightBot.Teams

  attr :name, :string, required: true
  attr :hooks, :list, required: true
  attr :selected, :string, default: nil
  attr :disabled, :boolean, default: false

  def hook_select(assigns) do
    ~H"""
    <div class="dropdown dropdown-end w-24 shrink-0">
      <input type="hidden" name={@name} value={@selected || ""} />
      <div tabindex={if @disabled, do: nil, else: "0"} role="button"
           class={"btn btn-sm w-full justify-start gap-1 px-2 font-normal " <> if(@disabled, do: "btn-disabled", else: "btn-outline")}>
        <img :if={@selected && Teams.hook_icon(@selected)} src={Teams.hook_icon(@selected)} class="size-4 object-contain shrink-0" />
        <span class="truncate"><%= if @selected, do: Teams.hook_label(@selected), else: "-" %></span>
      </div>
      <div :if={not @disabled} tabindex="0" class="dropdown-content z-30 mt-1 w-40 rounded-lg border border-base-300 bg-base-100 p-1 shadow-lg">
        <button :for={hook <- @hooks} type="button" data-value={hook}
                onclick="const i = this.closest('.dropdown').querySelector('input'); i.value = this.dataset.value; i.dispatchEvent(new Event('input', {bubbles: true})); document.activeElement.blur()"
                class={"btn btn-xs w-full justify-start gap-1.5 font-mono " <> if(hook == @selected, do: "btn-primary", else: "btn-ghost")}>
          <img :if={Teams.hook_icon(hook)} src={Teams.hook_icon(hook)} class="size-4 object-contain" /><%= Teams.hook_label(hook) %>
        </button>
      </div>
    </div>
    """
  end
end
