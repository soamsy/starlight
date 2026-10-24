import Config

config :logger, level: :debug

config :starlight_bot, :log_to_file, true

config :starlight_bot, save_timeout_frames: true

config :starlight_bot, StarlightBotWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "r3DEQg7ohRr4LZF1wOJqS5d0HwCWPpjGqLGe0FrSN0r4OYS3VjNt0P5p5Z7xJMJt",
  watchers: [
    tailwind: {Tailwind, :install_and_run, [:starlight_bot, ~w(--watch)]},
    esbuild: {Esbuild, :install_and_run, [:starlight_bot, ~w(--sourcemap=inline --watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/starlight_bot_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]
