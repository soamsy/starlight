defmodule StarlightBot.Vdf do
  def parse_file(path) do
    with {:ok, text} <- File.read(path), do: parse(text)
  end

  def parse(text) do
    tokens = Regex.scan(~r/"((?:[^"\\]|\\.)*)"|([{}])/, text) |> Enum.map(&token/1)

    case read_pairs(tokens, %{}) do
      {map, []} -> {:ok, map}
      {_map, _rest} -> {:error, :unbalanced_vdf}
    end
  end

  def get(map, path) do
    Enum.reduce_while(path, map, fn key, acc ->
      case fetch_ci(acc, key) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  defp fetch_ci(map, key) when is_map(map) do
    Enum.find_value(map, fn {k, v} -> if String.downcase(k) == String.downcase(key), do: v end)
  end

  defp fetch_ci(_other, _key), do: nil

  defp token([_, text]), do: {:str, String.replace(text, ~r/\\(.)/, "\\1")}
  defp token([_, _, brace]), do: {:brace, brace}

  defp read_pairs([], acc), do: {acc, []}
  defp read_pairs([{:brace, "}"} | rest], acc), do: {acc, rest}

  defp read_pairs([{:str, key}, {:brace, "{"} | rest], acc) do
    {child, rest} = read_pairs(rest, %{})
    read_pairs(rest, Map.put(acc, key, child))
  end

  defp read_pairs([{:str, key}, {:str, value} | rest], acc), do: read_pairs(rest, Map.put(acc, key, value))
  defp read_pairs(_malformed, acc), do: {acc, [:malformed]}
end
