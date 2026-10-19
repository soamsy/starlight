defmodule StarlightBot.Conditions do
  def eval(nil, _eval_leaf), do: true
  def eval(%{"op" => "and", "children" => children}, eval_leaf), do: Enum.all?(children, &eval(&1, eval_leaf))
  def eval(%{"op" => "or", "children" => children}, eval_leaf), do: Enum.any?(children, &eval(&1, eval_leaf))
  def eval(leaf, eval_leaf), do: eval_leaf.(leaf)

  def leaves(nil), do: []
  def leaves(%{"children" => children}), do: Enum.flat_map(children, &leaves/1)
  def leaves(leaf), do: [leaf]

  def prune(%{"op" => op, "children" => children} = node) when op in ["and", "or"] do
    case children |> Enum.map(&prune/1) |> Enum.reject(&is_nil/1) do
      [] -> nil
      kept -> %{node | "children" => kept}
    end
  end

  def prune(node), do: node

  def label(nil, _leaf_label), do: nil
  def label(node, leaf_label), do: node_label(node, true, leaf_label)

  defp node_label(%{"op" => op, "children" => children}, root?, leaf_label) do
    joined = Enum.map_join(children, " #{String.upcase(op)} ", &node_label(&1, false, leaf_label))
    if root? or length(children) == 1, do: joined, else: "(#{joined})"
  end

  defp node_label(leaf, _root?, leaf_label), do: leaf_label.(leaf)

  def add(nil, _path, child), do: %{"op" => "and", "children" => [child]}
  def add(tree, path, child), do: update_node(tree, parse_path(path), &Map.update!(&1, "children", fn children -> children ++ [child] end))

  def group(leaf), do: %{"op" => "or", "children" => [leaf]}

  def remove(tree, path) do
    case parse_path(path) do
      [] ->
        nil

      parts ->
        {parent_path, [index]} = Enum.split(parts, -1)
        update_node(tree, parent_path, &Map.update!(&1, "children", fn children -> List.delete_at(children, index) end))
    end
  end

  def toggle_op(tree, path) do
    update_node(tree, parse_path(path), fn group -> Map.put(group, "op", if(group["op"] == "and", do: "or", else: "and")) end)
  end

  def put_leaf(tree, path, leaf), do: update_node(tree, parse_path(path), fn _ -> leaf end)

  def child_path("", index), do: "#{index}"
  def child_path(path, index), do: "#{path}.#{index}"

  defp parse_path(""), do: []
  defp parse_path(path), do: path |> String.split(".") |> Enum.map(&String.to_integer/1)

  defp update_node(node, [], fun), do: fun.(node)

  defp update_node(%{"children" => children} = node, [index | rest], fun) do
    %{node | "children" => List.update_at(children, index, &update_node(&1, rest, fun))}
  end
end
