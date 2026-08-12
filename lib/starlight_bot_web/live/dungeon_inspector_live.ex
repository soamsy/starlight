defmodule StarlightBotWeb.Live.DungeonInspectorLive do
  use StarlightBotWeb, :live_view
  alias StarlightBot.Vision.{Capture, DungeonGraph}

  @tmp_jpeg "/tmp/_starlight_dungeon_inspector.jpg"

  @matched_color "#4ade80"
  @orphan_color "#facc15"
  @miss_color "#6b7280"
  @battle_color "#4ade80"
  @hard_battle_color "#f87171"

  @node_type_colors %{
    event: "#9ca3af",
    battle: @battle_color,
    hard_battle: @hard_battle_color,
    shop: "#60a5fa",
    boss: "#c084fc"
  }

  @node_type_labels %{
    event: "Event",
    battle: "Battle",
    hard_battle: "Hard Battle",
    shop: "Shop",
    boss: "Boss"
  }

  @diagram_levels_top_to_bottom Enum.reverse(DungeonGraph.levels())
  @diagram_col_x %{0 => 20, 1 => 190, 2 => 360, 3 => 530}
  @diagram_row_top 20
  @diagram_row_h 60
  @diagram_node_w 130
  @diagram_node_h 44

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:status, :idle)
     |> assign(:frame_b64, nil)
     |> assign(:graph, nil)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_event("take_screenshot", _, socket) do
    case Capture.grab_frame() do
      {:ok, frame} ->
        handle_frame(socket, frame)

      {:error, :no_window} ->
        {:noreply,
         socket
         |> assign(:status, :error)
         |> put_flash(:error, "Game window not found. Start Limbus Company first.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:status, :error)
         |> put_flash(:error, "Screenshot failed: #{inspect(reason)}")}
    end
  end

  defp handle_frame(socket, frame) do
    case encode_jpeg(frame.mat) do
      {:ok, jpeg} ->
        b64 = Base.encode64(jpeg)

        case DungeonGraph.build(frame) do
          {:ok, graph} ->
            {:noreply,
             socket
             |> assign(:status, :done)
             |> assign(:frame_b64, b64)
             |> assign(:graph, graph)
             |> assign(:error, nil)
             |> push_event("load_dungeon_frame", %{data: b64, overlays: overlays(graph)})}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:status, :done)
             |> assign(:frame_b64, b64)
             |> assign(:graph, nil)
             |> assign(:error, reason)
             |> push_event("load_dungeon_frame", %{data: b64, overlays: []})}
        end

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:status, :error)
         |> put_flash(:error, "Encode failed: #{inspect(reason)}")}
    end
  end

  defp overlays(%DungeonGraph{diagnostics: diagnostics, edges: edges, node_hits: node_hits}) do
    reachable = MapSet.new(edges, &{&1.from_node, &1.to_node})
    Enum.flat_map(diagnostics, &diagnostic_overlay(&1, reachable)) ++ Enum.map(node_hits, &node_hit_overlay/1)
  end

  defp node_hit_overlay(%{rect: {x, y, w, h}} = hit) do
    color = if hit.centered?, do: @battle_color, else: @hard_battle_color
    label = if hit.centered?, do: "battle", else: "hard battle"

    %{
      type: "rect",
      x: x,
      y: y,
      w: w,
      h: h,
      color: color,
      text: "#{hit.hop} #{hit.level} #{label}",
      text_x: x,
      text_y: y - 6
    }
  end

  defp diagnostic_overlay(%{region: nil}, _reachable), do: []

  defp diagnostic_overlay(%{region: {x, y, w, h}} = m, reachable) do
    {color, status} = diagnostic_style(m, reachable)

    [
      %{
        type: "rect",
        x: x,
        y: y,
        w: w,
        h: h,
        color: color,
        text: "#{m.hop} #{m.from}→#{m.to} #{status} #{Float.round(m.score, 2)}",
        text_x: x,
        text_y: y - 6
      }
    ]
  end

  defp diagnostic_style(%{matched?: false} = m, _reachable),
    do: {@miss_color, "no match (#{variant_label(m.variant)})"}

  defp diagnostic_style(%{matched?: true} = m, reachable) do
    edge_key = {{m.hop, m.from}, {m.hop + 1, m.to}}

    if MapSet.member?(reachable, edge_key) do
      {@matched_color, "matched #{variant_label(m.variant)}"}
    else
      {@orphan_color, "unreachable #{variant_label(m.variant)}"}
    end
  end

  defp variant_label(nil), do: "plain"
  defp variant_label(variant), do: to_string(variant)

  defp encode_jpeg(mat) do
    Evision.imwrite(@tmp_jpeg, mat)
    File.read(@tmp_jpeg)
  rescue
    e -> {:error, Exception.message(e)}
  end

  def error_message(:not_on_dungeon_graph), do: "Not on the DungeonGraph screen."

  def error_message(:pan_zoom_not_reset),
    do: "Cursor pan/zoom isn't at the default location — press d then a to reset, then retake the screenshot."

  def error_message(other), do: inspect(other)

  def edges_by_hop(%DungeonGraph{edges: edges}) do
    edges
    |> Enum.sort_by(&elem(&1.from_node, 0))
    |> Enum.group_by(&elem(&1.from_node, 0))
  end

  def node_type(%DungeonGraph{nodes: nodes}, node_key), do: nodes[node_key].type

  def diagram_width, do: Map.fetch!(@diagram_col_x, 3) + @diagram_node_w + 20

  def diagram_height, do: @diagram_row_top + length(@diagram_levels_top_to_bottom) * @diagram_row_h

  def diagram_nodes(%DungeonGraph{nodes: nodes}) do
    Enum.map(nodes, fn {key, node} ->
      {x, y} = node_position(key)
      color = Map.fetch!(@node_type_colors, node.type)

      %{
        key: key,
        x: x,
        y: y,
        w: @diagram_node_w,
        h: @diagram_node_h,
        color: color,
        level: node.level,
        type_label: Map.fetch!(@node_type_labels, node.type)
      }
    end)
  end

  def diagram_edges(%DungeonGraph{edges: edges}) do
    Enum.map(edges, fn edge ->
      {x1, y1} = node_position(edge.from_node)
      {x2, y2} = node_position(edge.to_node)

      %{
        x1: x1 + @diagram_node_w,
        y1: y1 + div(@diagram_node_h, 2),
        x2: x2,
        y2: y2 + div(@diagram_node_h, 2),
        color: if(edge.variant == :hard, do: @hard_battle_color, else: "#9ca3af")
      }
    end)
  end

  defp node_position({hop, level}) do
    x = Map.fetch!(@diagram_col_x, hop)
    row = Enum.find_index(@diagram_levels_top_to_bottom, &(&1 == level))
    {x, @diagram_row_top + row * @diagram_row_h}
  end
end
