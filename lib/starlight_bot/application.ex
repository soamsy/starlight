defmodule StarlightBot.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    setup_file_logger()
    Logger.info("StarlightBot starting", module: __MODULE__)

    ensure_user_db_dir!()

    children =
      [
        StarlightBot.Repo,
        {Phoenix.PubSub, name: StarlightBot.PubSub},
        StarlightBotWeb.Endpoint,
        {Task.Supervisor, name: StarlightBot.TaskSupervisor},
        {StarlightBot.Vision.HookRegistry, []},
        {StarlightBot.Vision.EgoGiftDetector, []},
      ] ++ hardware_children()

    opts = [strategy: :one_for_one, name: StarlightBot.Supervisor]
    result = Supervisor.start_link(children, opts)

    case result do
      {:ok, _pid} -> Logger.info("StarlightBot started — run `mix starlight.check` to verify environment")
      {:error, reason} -> Logger.error("StarlightBot failed to start: #{inspect(reason)}")
    end

    result
  end

  @impl true
  def stop(_state) do
    Logger.info("StarlightBot stopping — releasing all inputs")
    # Not started at all when hardware_children/0 is skipped (:test).
    if Process.whereis(StarlightBot.Input.Mouse), do: StarlightBot.Input.Mouse.release_all()
    :ok
  end

  defp hardware_children do
    if Application.get_env(:starlight_bot, :start_hardware?, true) do
      [
        {StarlightBot.Vision.Capture, []},
        {StarlightBot.Input.Mouse, []},
        {StarlightBot.Input.Keyboard, []},
        {StarlightBot.Navigation.Navigator, []},
      ]
    else
      []
    end
  end

  defp setup_file_logger do
    if Application.get_env(:starlight_bot, :log_to_file, false) do
      :logger.remove_handler(:starlight_file)
      :logger.add_handler(:starlight_file, :logger_std_h, %{
        level: :warning,
        config: %{
          type: :file,
          file: ~c"/tmp/starlight.log",
          filesync_repeat_interval: 200
        }
      })
    end
  end

  defp ensure_user_db_dir! do
    db_path = Application.get_env(:starlight_bot, StarlightBot.Repo)[:database]
    dir = Path.dirname(db_path)

    unless File.exists?(dir) do
      Logger.info("Creating user data directory: #{dir}")
      File.mkdir_p!(dir)
    end
  end
end
