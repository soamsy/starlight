defmodule StarlightBotWeb.ErrorHTML do
  use StarlightBotWeb, :html

  def render("404.html", _assigns), do: "Not found"
  def render("500.html", _assigns), do: "Internal server error"
end
