defmodule StarlightBotWeb.Live.DataLive do
  use StarlightBotWeb, :live_view
  alias StarlightBot.Data

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :settings, Data.settings())}

  @impl true
  def handle_event("settings_save", %{"data_dir" => data_dir} = params, socket) do
    mode = if Data.authoring_allowed?(), do: Map.get(params, "mode", "user"), else: "user"

    case Data.write_config(mode: mode, data_dir: String.trim(data_dir)) do
      :ok ->
        {:noreply,
         socket
         |> assign(:settings, Data.settings())
         |> put_flash(:info, "Saved. Restart Starlight for the new location to take effect.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't save settings: #{inspect(reason)}")}
    end
  end

  def handle_event("settings_open_folder", _params, socket) do
    dir = Data.settings().data_dir
    File.mkdir_p(dir)
    Task.Supervisor.start_child(StarlightBot.TaskSupervisor, fn -> System.cmd("xdg-open", [dir], stderr_to_stdout: true) end)
    {:noreply, socket}
  end
end
