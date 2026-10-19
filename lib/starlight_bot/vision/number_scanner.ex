defmodule StarlightBot.Vision.NumberScanner do
  alias StarlightBot.Vision.{Frame, Matcher}

  @digit_hooks for d <- 0..9, do: {Integer.to_string(d), :"char_#{d}"}
  @min_glyph_gap_px 12

  @spec read(Frame.t(), [{String.t(), atom}]) :: {:ok, integer} | :not_found
  def read(%Frame{} = frame, glyph_hooks \\ @digit_hooks) do
    glyph_hooks
    |> Enum.flat_map(fn {char, hook_name} ->
      case Matcher.find_all_with_scores(frame, hook_name) do
        {:ok, matches} -> Enum.map(matches, fn {{x, _y, _w, _h}, score} -> {x, char, score} end)
        {:error, _} -> []
      end
    end)
    |> from_hits()
  end

  @spec from_hits([{number, String.t(), number}]) :: {:ok, integer} | :not_found
  def from_hits([]), do: :not_found

  def from_hits(hits) do
    hits
    |> Enum.sort_by(fn {_x, _char, score} -> score end, :desc)
    |> Enum.reduce([], fn {x, _char, _score} = hit, kept ->
      if Enum.any?(kept, fn {kx, _, _} -> abs(kx - x) < @min_glyph_gap_px end), do: kept, else: [hit | kept]
    end)
    |> Enum.sort_by(fn {x, _char, _score} -> x end)
    |> Enum.map_join(fn {_x, char, _score} -> char end)
    |> Integer.parse()
    |> case do
      {n, ""} -> {:ok, n}
      _ -> :not_found
    end
  end
end
