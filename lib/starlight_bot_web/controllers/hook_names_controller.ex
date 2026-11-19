defmodule StarlightBotWeb.HookNamesController do
  use StarlightBotWeb, :controller

  alias StarlightBot.Hooks

  def index(conn, _params), do: json(conn, Enum.map(Hooks.list_hooks(), & &1.name))
end
