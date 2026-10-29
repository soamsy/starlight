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
    ]
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
