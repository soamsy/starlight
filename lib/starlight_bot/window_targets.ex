defmodule StarlightBot.WindowTargets do
  alias StarlightBot.{AppSettings, Native}

  def titles do
    case AppSettings.window_titles() do
      [] -> [default_title()]
      titles -> titles
    end
  end

  def find do
    Enum.find_value(titles(), fn title ->
      match?({:ok, _, _, _, _}, Native.get_window_rect(title)) && title
    end)
  end

  def title, do: find() || hd(titles())

  defp default_title, do: Application.get_env(:starlight_bot, :game_window_title, "LimbusCompany")
end
