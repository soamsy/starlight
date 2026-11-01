defmodule StarlightBotWeb.Components.GameStream do
  use Phoenix.Component

  attr :id, :string, required: true
  attr :class, :string, default: ""

  def game_stream(assigns) do
    ~H"""
    <div id={@id} phx-hook="GameStream" phx-update="ignore" data-src="/stream/frame.jpg" class={"flex flex-col gap-1 " <> @class}>
      <div class="flex items-center justify-between">
        <span class="text-xs font-semibold text-base-content/50 uppercase tracking-wide">Game view</span>
        <button type="button" data-stream-off class="btn btn-ghost btn-xs hidden">Stop watching</button>
      </div>
      <div class="relative aspect-video w-full bg-base-300 rounded-lg overflow-hidden">
        <img data-stream-img class="absolute inset-0 w-full h-full object-cover hidden" alt="" />
        <button type="button" data-stream-on class="absolute inset-0 flex items-center justify-center text-base-content/40 hover:text-base-content/80 transition-colors" title="Show game view">
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" class="size-8">
            <path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12Z" />
            <circle cx="12" cy="12" r="3" />
          </svg>
        </button>
        <span data-stream-status class="absolute inset-x-0 bottom-0 text-center text-[10px] bg-base-300/80 text-base-content/60 hidden">No game window</span>
      </div>
    </div>
    """
  end
end
