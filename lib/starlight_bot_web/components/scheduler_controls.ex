defmodule StarlightBotWeb.Components.SchedulerControls do
  use Phoenix.Component

  attr :blocked, :any, default: nil
  attr :pending, :boolean, default: true
  attr :section, :atom, default: :all, values: [:all, :start, :hold]

  def scheduler_controls(assigns) do
    ~H"""
    <div class={["flex flex-col gap-1", @section == :hold && "items-end"]}>
      <div :if={@section != :hold} class="flex flex-wrap gap-1">
        <button :if={@pending} type="button" phx-click="scheduler_start_now" class="btn btn-xs btn-success">Start runs now</button>
        <button :if={@blocked} type="button" phx-click="scheduler_hold" phx-value-for="clear" class="btn btn-xs">Resume schedulers</button>
      </div>
      <span :if={@section != :start} class="font-semibold text-base-content/50">Stop both schedulers for</span>
      <div :if={@section != :start} class={["flex flex-wrap gap-1", @section == :hold && "justify-end"]}>
        <button :for={{label, value} <- [{"1h", "1"}, {"2h", "2"}, {"4h", "4"}, {"8h", "8"}, {"Rest of day", "day"}]} type="button" phx-click="scheduler_hold" phx-value-for={value} class="btn btn-xs">{label}</button>
      </div>
    </div>
    """
  end
end
