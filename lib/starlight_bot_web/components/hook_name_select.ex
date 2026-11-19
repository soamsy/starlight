defmodule StarlightBotWeb.Components.HookNameSelect do
  use Phoenix.Component

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :selected, :string, default: nil

  def hook_name_select(assigns) do
    ~H"""
    <details id={@id} phx-hook="FloatingDropdown" data-keep-open data-close-on-click class="dropdown flex-1 min-w-0">
      <input type="hidden" name={@name} value={@selected || ""} />
      <summary class="btn btn-xs btn-outline w-full justify-start font-mono font-normal">
        <span class="truncate"><%= if @selected in [nil, ""], do: "hook name", else: @selected %></span>
      </summary>
      <div popover="manual" class="dropdown-content z-50 w-80 max-w-[calc(100vw-1rem)] rounded-lg border border-base-300 bg-base-100 p-2 shadow-lg">
        <div id={"#{@id}-picker"} phx-hook="HookNameList" data-src="/hooks/names.json" class="flex flex-col gap-2">
          <input type="text" form="hook-name-filter" placeholder="Filter hooks" autocomplete="off" class="input input-bordered input-xs w-full font-mono" />
          <div id={"#{@id}-list"} phx-update="ignore" class="flex max-h-72 flex-col overflow-y-auto"></div>
        </div>
      </div>
    </details>
    """
  end
end
