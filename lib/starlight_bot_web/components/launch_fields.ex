defmodule StarlightBotWeb.Components.LaunchFields do
  use Phoenix.Component
  alias StarlightBot.Scheduler

  attr :launch_mode, :string, required: true
  attr :steam_app_id, :string, required: true
  attr :exe_path, :string, required: true
  attr :launch_timeout_s, :any, required: true
  attr :reset_event, :string, required: true
  attr :launcher, :string, default: "kwin"
  attr :requirements, :list, default: []

  def launch_fields(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs">
      <span class="text-base-content/50">Needs:</span>
      <span :if={@requirements == []} class="text-base-content/60">nothing extra</span>
      <span :for={req <- @requirements} class={["font-mono", req.found? && "text-success", !req.found? && "text-error"]}>
        {req.name} {if req.found?, do: "detected", else: "not found"}
      </span>
    </div>
    <div class="flex flex-wrap items-end gap-3">
      <label class="flex flex-col gap-1">
        <span class="text-xs font-semibold text-base-content/50 uppercase tracking-wide">Limbus launcher</span>
        <select name="launcher" phx-change="game_launcher_set" class="select select-sm select-bordered">
          <option :for={{id, label} <- StarlightBot.LauncherDeps.launchers()} value={id} selected={@launcher == id}>{label}</option>
        </select>
      </label>

      <label class="flex flex-col gap-1">
        <span class="text-xs font-semibold text-base-content/50 uppercase tracking-wide">If Limbus isn't open</span>
        <select name="launch_mode" class="select select-sm select-bordered">
          <option value="steam" selected={@launch_mode == "steam"}>Launch through Steam</option>
          <option value="exe" selected={@launch_mode == "exe"}>Launch an executable</option>
          <option value="none" selected={@launch_mode == "none"}>Don't launch, wait for it</option>
        </select>
      </label>

      <%= if @launch_mode == "steam" do %>
        <label class="flex flex-col gap-1">
          <span class="text-xs text-base-content/40">Steam app id</span>
          <div class="flex items-center gap-1">
            <input type="text" name="steam_app_id" phx-debounce="500" value={@steam_app_id} class="input input-sm input-bordered font-mono w-24" />
            <button type="button" phx-click={@reset_event} disabled={@steam_app_id == Scheduler.default_steam_app_id()} class="tooltip tooltip-left btn btn-ghost btn-square btn-sm text-base-content/60" data-tip="Reset to default">
              <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="h-4 w-4">
                <path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8" />
                <path d="M21 3v5h-5" />
                <path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16" />
                <path d="M8 16H3v5" />
              </svg>
            </button>
          </div>
        </label>
      <% else %>
        <input type="hidden" name="steam_app_id" value={@steam_app_id} />
      <% end %>

      <%= if @launch_mode == "exe" do %>
        <label class="flex flex-col gap-1">
          <span class="text-xs text-base-content/40">Executable path</span>
          <input type="text" name="exe_path" phx-debounce="500" value={@exe_path} class="input input-sm input-bordered font-mono" />
        </label>
      <% else %>
        <input type="hidden" name="exe_path" value={@exe_path} />
      <% end %>

      <label class="flex flex-col gap-1">
        <span class="text-xs text-base-content/40">Timeout (seconds)</span>
        <input type="number" name="launch_timeout_s" phx-debounce="500" min="1" value={@launch_timeout_s} class="input input-sm input-bordered w-24" />
      </label>
    </div>
    <p class="max-w-prose text-xs text-base-content/60">{StarlightBot.LauncherDeps.description(@launcher)}</p>
    """
  end
end
