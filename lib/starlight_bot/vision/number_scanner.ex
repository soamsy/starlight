defmodule StarlightBot.Vision.NumberScanner do
  alias StarlightBot.Vision.{Frame, Matcher}

  @digit_hooks for d <- 0..9, do: {Integer.to_string(d), :"char_#{d}"}

  @spec read(Frame.t(), [{String.t(), atom}]) :: {:ok, integer} | :not_found
  def read(%Frame{} = frame, glyph_hooks \\ @digit_hooks) do
    glyph_hooks
    |> Enum.flat_map(fn {char, hook_name} ->
      frame
      |> Matcher.find_all(hook_name)
      |> Enum.map(fn {x, _y, _w, _h} -> {x, char} end)
    end)
    |> from_hits()
  end

  @spec from_hits([{number, String.t()}]) :: {:ok, integer} | :not_found
  def from_hits([]), do: :not_found

  def from_hits(hits) do
    hits
    |> Enum.sort_by(fn {x, _char} -> x end)
    |> Enum.map(fn {_x, char} -> char end)
    |> Enum.join()
    |> Integer.parse()
    |> case do
      {n, ""} -> {:ok, n}
      _ -> :not_found
    end
  end
end
