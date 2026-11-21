defmodule StarlightBotWeb.Components.TeamSelect do
  use Phoenix.Component
  alias StarlightBotWeb.Components.TeamNav

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :teams, :list, required: true
  attr :selected, :any, default: nil
  attr :nav, :map, required: true
  attr :disabled, :boolean, default: false
  attr :allow_none, :boolean, default: false

  def team_select(assigns) do
    assigns = assign(assigns, :current, Enum.find(assigns.teams, &(&1.id == assigns.selected)))

    ~H"""
    <div :if={@disabled} class="min-w-0 flex-1">
      <div class="btn btn-sm btn-disabled w-full justify-start gap-2 px-3 font-normal">
        <.label current={@current} nav={@nav} />
      </div>
    </div>
    <details :if={not @disabled} id={@id} phx-hook="FloatingDropdown" data-keep-open data-close-on-click class="dropdown min-w-0 flex-1">
      <input type="hidden" name={@name} value={@selected || ""} />
      <summary class="btn btn-sm btn-outline w-full justify-start gap-2 px-3 font-normal">
        <.label current={@current} nav={@nav} />
      </summary>
      <div popover="manual" class="dropdown-content z-50 max-h-[70vh] w-72 max-w-[calc(100vw-1rem)] overflow-y-auto rounded-lg border border-base-300 bg-base-100 p-1 shadow-lg">
        <div id={"#{@id}-options"} phx-hook="HookOptions" phx-update="ignore" data-source="team-select-options" data-allow-none={@allow_none}></div>
      </div>
    </details>
    """
  end

  attr :teams, :list, required: true
  attr :nav, :map, required: true

  def team_options(assigns) do
    ~H"""
    <div id="team-select-options" hidden>
      <div class="flex flex-col">
        <button type="button" data-value="" data-optional
                onclick="const i = this.closest('details').querySelector('input'); i.value = this.dataset.value; i.dispatchEvent(new Event('input', {bubbles: true}))"
                class="btn btn-sm btn-ghost w-full justify-start gap-2 font-normal">
          None selected
        </button>
        <button :for={team <- @teams} type="button" data-value={team.id}
                onclick="const i = this.closest('details').querySelector('input'); i.value = this.dataset.value; i.dispatchEvent(new Event('input', {bubbles: true}))"
                class="btn btn-sm btn-ghost w-full justify-start gap-2 font-normal">
          <.label current={team} nav={@nav} />
        </button>
      </div>
    </div>
    """
  end

  attr :current, :map, default: nil
  attr :nav, :map, required: true

  defp label(assigns) do
    assigns =
      assign(assigns, :icons, if(assigns.current, do: TeamNav.team_icons(assigns.current, assigns.nav.profiles_by_id, assigns.nav.locator_thumbs), else: []))

    ~H"""
    <%= if @current do %>
      <span class="truncate"><%= @current.name %></span>
      <span class="ml-auto inline-flex shrink-0 items-center gap-1">
        <img :for={icon <- Enum.take(@icons, 4)} src={icon.src} title={icon.name} class="h-4 w-auto rounded object-contain" />
        <span :if={length(@icons) > 4} class="badge badge-xs badge-neutral font-mono">+<%= length(@icons) - 4 %></span>
      </span>
    <% else %>
      <span class="truncate text-base-content/60">None selected</span>
    <% end %>
    """
  end
end
