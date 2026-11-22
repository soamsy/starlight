defmodule StarlightBot.HostEnv do
  @marker_vars ~w(APPDIR APPIMAGE ARGV0 OWD PYTHONDONTWRITEBYTECODE)
  @keep_vars ~w(PWD OLDPWD)

  def overrides do
    case System.get_env("APPDIR") do
      nil -> []
      appdir -> Enum.map(@marker_vars, &{&1, nil}) ++ scrubbed(System.get_env(), appdir)
    end
  end

  defp scrubbed(vars, appdir) do
    for {name, value} <- vars,
        name not in @marker_vars and name not in @keep_vars,
        String.contains?(value, appdir),
        do: {name, strip(value, appdir)}
  end

  defp strip(value, appdir) do
    case value |> String.split(":") |> Enum.reject(&String.contains?(&1, appdir)) do
      [] -> nil
      entries -> Enum.join(entries, ":")
    end
  end
end
