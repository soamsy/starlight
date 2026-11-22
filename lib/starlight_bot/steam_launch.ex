defmodule StarlightBot.SteamLaunch do
  alias StarlightBot.{LogStore, Vdf}

  @verb "waitforexitandrun"
  @exe "LimbusCompany.exe"
  @system_tool_dirs ["/usr/share/steam/compatibilitytools.d", "/usr/local/share/steam/compatibilitytools.d"]

  def command(app_id, opts \\ []) do
    app_id = to_string(app_id)

    with {:ok, root} <- steam_root(),
         {:ok, libraries} <- libraries(root),
         {:ok, library, install_dir} <- find_app(libraries, app_id),
         {:ok, tool_name, tool_dir} <- resolve_tool(root, libraries, app_id),
         _ = log(opts, "steam root #{root}, libraries #{Enum.join(libraries, ", ")}"),
         _ = log(opts, "app #{app_id} installed in #{library} as #{inspect(install_dir)}, compat tool #{tool_name} at #{tool_dir}"),
         {:ok, tool_manifest} <- Vdf.parse_file(Path.join(tool_dir, "toolmanifest.vdf")),
         {:ok, runtime} <- runtime(libraries, tool_manifest),
         _ = log(opts, "container runtime: #{inspect(runtime && runtime.path)}") do
      exe = Path.join([library, "steamapps", "common", install_dir, @exe])
      tool_cmd = expand_commandline(Vdf.get(tool_manifest, ["manifest", "commandline"]), tool_dir)
      runtime_cmd = runtime_commandline(runtime)

      argv =
        [Path.join(root, "ubuntu12_32/reaper"), "SteamLaunch", "AppId=#{app_id}", "--"] ++
          runtime_cmd ++ tool_cmd ++ [Keyword.get(opts, :exe, exe) | Keyword.get(opts, :args, [])]

      tool_paths = Enum.join([tool_dir | runtime_paths(runtime)], ":")

      env = [
        {"SteamAppId", app_id},
        {"SteamGameId", app_id},
        {"SteamOverlayGameId", app_id},
        {"STEAM_COMPAT_APP_ID", app_id},
        {"SteamClientLaunch", "1"},
        {"SteamEnv", "1"},
        {"STEAM_COMPAT_PROTON", "1"},
        {"STEAM_COMPAT_FLAGS", "search-cwd"},
        {"STEAM_COMPAT_CLIENT_INSTALL_PATH", root},
        {"STEAM_COMPAT_DATA_PATH", Path.join([library, "steamapps", "compatdata", app_id])},
        {"STEAM_COMPAT_SHADER_PATH", Path.join([library, "steamapps", "shadercache", app_id])},
        {"STEAM_COMPAT_INSTALL_PATH", Path.join([library, "steamapps", "common", install_dir])},
        {"STEAM_COMPAT_LIBRARY_PATHS", libraries |> Enum.map(&Path.join(&1, "steamapps")) |> Enum.join(":")},
        {"STEAM_COMPAT_TOOL_PATHS", tool_paths},
        {"STEAM_COMPAT_MOUNTS", Enum.join(runtime_paths(runtime), ":")}
      ] ++ user_env()

      log(opts, "command: #{Enum.join(argv, " ")}")
      {:ok, %{argv: argv, env: env, exe: exe, cwd: Path.dirname(exe)}}
    end
  end

  def describe({:no_compat_tool, app_id}),
    do: "no Proton version is selected for app #{app_id}; set one in Steam (game Properties, Compatibility) and launch it once from Steam"

  def describe({:steam_config_unreadable, path}), do: "could not read Steam's config at #{path}"
  def describe({:compat_tool_not_found, name}), do: "Steam selects compatibility tool #{inspect(name)} but it is not installed"
  def describe({:app_not_installed, app_id}), do: "app #{app_id} is not installed in any Steam library"
  def describe(:libraryfolders_unreadable), do: "could not read Steam's libraryfolders.vdf"
  def describe(:steam_not_found), do: "Steam installation not found"
  def describe({:game_exited, ""}), do: "the game process exited right after starting; see the gamescope log"
  def describe({:game_exited, detail}), do: "the game process exited right after starting: #{detail}"
  def describe(reason), do: inspect(reason)

  def update_pending?(app_id) do
    app_id = to_string(app_id)

    with {:ok, root} <- steam_root(),
         {:ok, libraries} <- libraries(root),
         {:ok, library, _dir} <- find_app(libraries, app_id),
         {:ok, manifest} <- Vdf.parse_file(Path.join([library, "steamapps", "appmanifest_#{app_id}.acf"])) do
      flags = manifest |> Vdf.get(["AppState", "StateFlags"]) |> to_int()
      built = Vdf.get(manifest, ["AppState", "buildid"])
      target = Vdf.get(manifest, ["AppState", "TargetBuildID"])
      Bitwise.band(flags, 2) != 0 or (target not in [nil, "0"] and target != built)
    else
      _ -> false
    end
  end

  defp to_int(value) do
    case Integer.parse(to_string(value)) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp steam_root do
    candidates = [Path.expand("~/.local/share/Steam"), Path.expand("~/.steam/steam")]

    case Enum.find(candidates, &File.regular?(Path.join(&1, "ubuntu12_32/reaper"))) do
      nil -> {:error, :steam_not_found}
      root -> {:ok, root}
    end
  end

  defp libraries(root) do
    with {:ok, vdf} <- Vdf.parse_file(Path.join(root, "steamapps/libraryfolders.vdf")),
         %{} = folders <- Vdf.get(vdf, ["libraryfolders"]) do
      paths = for {_, %{"path" => path}} <- folders, do: path
      {:ok, Enum.uniq([root | paths])}
    else
      _ -> {:error, :libraryfolders_unreadable}
    end
  end

  defp find_app(libraries, app_id) do
    Enum.find_value(libraries, {:error, {:app_not_installed, app_id}}, fn library ->
      with {:ok, manifest} <- Vdf.parse_file(Path.join([library, "steamapps", "appmanifest_#{app_id}.acf"])),
           dir when is_binary(dir) <- Vdf.get(manifest, ["AppState", "installdir"]) do
        {:ok, library, dir}
      else
        _ -> nil
      end
    end)
  end

  defp tool_name(root, app_id) do
    case Vdf.parse_file(Path.join(root, "config/config.vdf")) do
      {:ok, config} ->
        mapping = Vdf.get(config, ["InstallConfigStore", "Software", "Valve", "Steam", "CompatToolMapping"])

        case is_map(mapping) && (get_in(mapping, [app_id, "name"]) || get_in(mapping, ["0", "name"])) do
          name when is_binary(name) -> {:ok, name}
          _ -> {:error, {:no_compat_tool, app_id}}
        end

      _ ->
        {:error, {:steam_config_unreadable, Path.join(root, "config/config.vdf")}}
    end
  end

  defp resolve_tool(root, libraries, app_id) do
    case tool_name(root, app_id) do
      {:ok, name} ->
        with {:ok, dir} <- find_tool(root, libraries, name), do: {:ok, name, dir}

      {:error, {:no_compat_tool, _}} = error ->
        default_tool(root, libraries) || error

      error ->
        error
    end
  end

  defp tool_vdf_paths(root, libraries) do
    roots =
      [Path.join(root, "compatibilitytools.d") | @system_tool_dirs] ++
        Enum.map(libraries, &Path.join([&1, "steamapps", "common"]))

    Enum.flat_map(roots, fn dir -> Path.wildcard(Path.join([dir, "*", "compatibilitytool.vdf"])) end)
  end

  defp find_tool(root, libraries, name) do
    Enum.find_value(tool_vdf_paths(root, libraries), {:error, {:compat_tool_not_found, name}}, fn vdf_path ->
      with {:ok, vdf} <- Vdf.parse_file(vdf_path),
           %{} = tool <- Vdf.get(vdf, ["compatibilitytools", "compat_tools", name]) do
        {:ok, vdf_path |> Path.dirname() |> Path.join(Map.get(tool, "install_path", ".")) |> Path.expand()}
      else
        _ -> nil
      end
    end)
  end

  defp default_tool(root, libraries) do
    (vdf_tools(root, libraries) ++ builtin_tools(libraries))
    |> Enum.max_by(&elem(&1, 0), fn -> nil end)
    |> case do
      nil -> nil
      {_rank, name, dir} -> {:ok, name, dir}
    end
  end

  defp builtin_tools(libraries) do
    libraries
    |> Enum.flat_map(&Path.wildcard(Path.join([&1, "steamapps", "common", "Proton*", "toolmanifest.vdf"])))
    |> Enum.flat_map(fn manifest ->
      dir = Path.dirname(manifest)

      case builtin_rank(Path.basename(dir)) do
        nil -> []
        rank -> [{rank, Path.basename(dir), dir}]
      end
    end)
  end

  defp builtin_rank("Proton - Experimental"), do: 1_000_000

  defp builtin_rank(dir) do
    case Regex.run(~r/^Proton (\d+)\.\d+$/, dir) do
      [_, major] -> String.to_integer(major)
      _ -> nil
    end
  end

  defp vdf_tools(root, libraries) do
    root
    |> tool_vdf_paths(libraries)
    |> Enum.flat_map(fn vdf_path ->
      with {:ok, vdf} <- Vdf.parse_file(vdf_path),
           %{} = tools <- Vdf.get(vdf, ["compatibilitytools", "compat_tools"]) do
        for {name, tool} <- tools, rank = valve_proton_rank(name), is_map(tool) do
          {rank, name, vdf_path |> Path.dirname() |> Path.join(Map.get(tool, "install_path", ".")) |> Path.expand()}
        end
      else
        _ -> []
      end
    end)
  end

  defp valve_proton_rank("proton_experimental"), do: 1_000_000

  defp valve_proton_rank(name) do
    case Regex.run(~r/^proton_(\d+)$/, name) do
      [_, major] -> String.to_integer(major)
      _ -> nil
    end
  end

  defp runtime(libraries, tool_manifest) do
    case Vdf.get(tool_manifest, ["manifest", "require_tool_appid"]) do
      nil ->
        {:ok, nil}

      runtime_app_id ->
        with {:ok, library, dir} <- find_app(libraries, runtime_app_id),
             path = Path.join([library, "steamapps", "common", dir]),
             {:ok, manifest} <- Vdf.parse_file(Path.join(path, "toolmanifest.vdf")) do
          {:ok, %{path: path, manifest: manifest}}
        end
    end
  end

  defp runtime_commandline(nil), do: []

  defp runtime_commandline(%{path: path, manifest: manifest}),
    do: expand_commandline(Vdf.get(manifest, ["manifest", "commandline"]), path)

  defp runtime_paths(nil), do: []
  defp runtime_paths(%{path: path}), do: [path]

  defp expand_commandline(commandline, dir) do
    [entry | args] = commandline |> String.replace("%verb%", @verb) |> String.split()
    [dir <> entry | args]
  end

  defp user_env do
    with {:ok, registry} <- Vdf.parse_file(Path.expand("~/.steam/registry.vdf")),
         user when is_binary(user) <- Vdf.get(registry, ["Registry", "HKCU", "Software", "Valve", "Steam", "AutoLoginUser"]) do
      [{"SteamUser", user}, {"SteamAppUser", user}]
    else
      _ -> []
    end
  end

  defp log(opts, text), do: if(Keyword.get(opts, :log, true), do: LogStore.append(:info, "launch: " <> text))
end
