precompiled_target_vars = ["TARGET_ARCH", "TARGET_OS", "TARGET_ABI"]

if match?({:win32, _}, :os.type()) and Enum.all?(precompiled_target_vars, &is_nil(System.get_env(&1))) do
  System.put_env(Enum.zip(precompiled_target_vars, ["x86_64", "windows", "msvc"]))
end

defmodule StarlightBot.MixProject do
  use Mix.Project

  def project do
    [
      app: :starlight_bot,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      listeners: [Phoenix.CodeReloader],
    ]
  end

  def cli do
    [preferred_envs: ["test.hardware": :test]]
  end

  def application do
    [
      mod: {StarlightBot.Application, []},
      extra_applications: [:logger, :runtime_tools, :crypto],
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:rustler, "~> 0.34"},
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.18"},
      {:jason, "~> 1.4"},
      {:evision, "~> 1.0"},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_ecto, "~> 4.6"},
      {:bandit, "~> 1.5"},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:elixirkit, github: "livebook-dev/elixirkit"},
      {:lucide, github: "lucide-icons/lucide", tag: "1.70.0", sparse: "icons", app: false, compile: false, depth: 1},
    ]
  end

  defp releases do
    [
      starlight_bot: [
        include_executables_for: [:unix, :windows],
        steps: [:assemble, &copy_models/1, &prune_duplicate_libs/1],
      ],
    ]
  end

  defp copy_models(release) do
    source = Path.expand("vendor/EgoGiftML/models/best", __DIR__)
    dest = Path.join([release.path, "lib", "starlight_bot-#{release.version}", "priv", "models"])
    File.mkdir_p!(dest)

    for file <- ~w(detector.onnx classifier.onnx classifier_classes.json) do
      File.cp!(Path.join(source, file), Path.join(dest, file))
    end

    release
  end

  defp prune_duplicate_libs(release) do
    for dir <- Path.wildcard(Path.join([release.path, "lib", "evision-*", "priv", "lib"])),
        {_hash, [_soname | duplicates]} <- duplicate_groups(dir),
        duplicate <- duplicates do
      File.rm!(duplicate)
    end

    release
  end

  defp duplicate_groups(dir) do
    dir
    |> File.ls!()
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.filter(&File.regular?/1)
    |> Enum.group_by(&:crypto.hash(:sha256, File.read!(&1)))
    |> Enum.map(fn {hash, files} -> {hash, Enum.sort_by(files, &(not Regex.match?(~r/\.so\.\d+$/, &1)))} end)
  end

  defp aliases do
    [
      "db.setup": ["ecto.create", "ecto.migrate"],
      "db.migrate": ["ecto.migrate"],
      "db.checkpoint": ["cmd scripts/db-checkpoint"],
      "test.hardware": ["test --include kde"],
      "ego_gifts.setup": ["ego_gifts.import"],
      "theme_packs.setup": ["theme_packs.import", "theme_packs.hooks"],
      "assets.build": ["tailwind starlight_bot", "esbuild starlight_bot"],
      "assets.deploy": ["tailwind starlight_bot --minify", "esbuild starlight_bot --minify"],
    ]
  end
end
