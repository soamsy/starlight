defmodule StarlightBot.Data do
  @term_key {__MODULE__, :resolved}
  @config_keys ~w(mode data_dir)

  def mode, do: resolved().mode
  def user_mode?, do: mode() == :user
  def authoring?, do: mode() == :authoring
  def paths, do: resolved()
  def base_writable?, do: authoring?()

  def require_authoring! do
    unless authoring?() do
      raise "this task edits the shipped databases and needs authoring mode (currently #{mode()}); see the settings file at #{config_file()}"
    end
  end

  def user_hooks_dir, do: resolved().user_hooks_dir
  def base_hooks_dir, do: resolved().base_hooks_dir

  def config_file do
    cond do
      path = System.get_env("STARLIGHT_CONFIG") -> path
      dir = System.get_env("XDG_CONFIG_HOME") -> Path.join([dir, "starlight", "config.toml"])
      true -> Path.join([System.user_home!(), ".config", "starlight", "config.toml"])
    end
  end

  def settings do
    paths = resolved()
    file = read_config()

    %{
      mode: paths.mode,
      mode_source: paths.mode_source,
      data_dir: paths.root,
      config_file: config_file(),
      config: file,
      paths: Map.take(paths, [:base, :user, :runs, :user_hooks_dir, :base_hooks_dir, :seed])
    }
  end

  def write_config(attrs) do
    current = read_config()

    merged =
      attrs
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.filter(fn {k, _} -> k in @config_keys end)
      |> Map.new()
      |> then(&Map.merge(current, &1))
      |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
      |> Enum.sort()

    body = Enum.map_join(merged, "", fn {k, v} -> "#{k} = #{inspect(to_string(v))}\n" end)
    file = config_file()

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(file, body) do
      :persistent_term.erase(@term_key)
      :ok
    end
  end

  def repo_config(:user, config), do: config |> put_database(:user) |> ensure_ready()
  def repo_config(:runs, config), do: config |> put_database(:runs) |> ensure_ready()

  def repo_config(:base, config) do
    config = config |> put_database(:base) |> Keyword.put(:journal_mode, :delete)
    if base_writable?(), do: config, else: Keyword.put(config, :mode, :readonly)
  end

  def reset_cache, do: :persistent_term.erase(@term_key)

  defp put_database(config, key), do: Keyword.put(config, :database, Map.fetch!(resolved(), key))

  defp ensure_ready(config) do
    paths = resolved()

    for dir <- [Path.dirname(paths.user), Path.dirname(paths.runs), paths.user_hooks_dir] do
      File.mkdir_p!(dir)
    end

    if not File.exists?(paths.user) and File.exists?(paths.seed) do
      File.cp!(paths.seed, paths.user)
    end

    config
  end

  defp resolved do
    case :persistent_term.get(@term_key, nil) do
      nil ->
        value = compute()
        :persistent_term.put(@term_key, value)
        value

      value ->
        value
    end
  end

  defp compute do
    case Application.get_env(:starlight_bot, :data_paths) do
      %{} = paths -> paths
      nil -> compute_from_env()
    end
  end

  defp compute_from_env do
    file = read_config()
    env_home = System.get_env("STARLIGHT_HOME")

    {mode, source} =
      cond do
        env_home -> {:user, :env}
        file["mode"] in ["user", "authoring"] -> {String.to_existing_atom(file["mode"]), :config}
        true -> {Application.get_env(:starlight_bot, :default_data_mode, :user), :default}
      end

    priv = :code.priv_dir(:starlight_bot) |> to_string()
    shipped = Path.join(priv, "data")

    case mode do
      :authoring ->
        local = Path.join(File.cwd!(), ".starlight-dev")

        %{
          mode: :authoring,
          mode_source: source,
          root: local,
          base: Path.join(shipped, "base.db"),
          seed: Path.join(shipped, "user_seed.db"),
          user: Path.join(shipped, "user_seed.db"),
          runs: Path.join(local, "runs.db"),
          user_hooks_dir: Path.join(local, "user_hooks"),
          base_hooks_dir: Application.get_env(:starlight_bot, :hook_image_dir) || Path.join(priv, "hooks")
        }

      :user ->
        root = Path.expand(env_home || file["data_dir"] || "~/.starlight")

        %{
          mode: :user,
          mode_source: source,
          root: root,
          base: Path.join(shipped, "base.db"),
          seed: Path.join(shipped, "user_seed.db"),
          user: Path.join(root, "user.db"),
          runs: Path.join(root, "runs.db"),
          user_hooks_dir: Path.join(root, "hooks"),
          base_hooks_dir: Application.get_env(:starlight_bot, :hook_image_dir) || Path.join(priv, "hooks")
        }
    end
  end

  defp read_config do
    with {:ok, body} <- File.read(config_file()) do
      for line <- String.split(body, "\n"),
          [_, key, value] <- [Regex.run(~r/^\s*([a-z_]+)\s*=\s*"(.*)"\s*$/, line)],
          into: %{},
          do: {key, value}
    else
      _ -> %{}
    end
  end
end
