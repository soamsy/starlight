defmodule StarlightBot.RunHistory do
  require Logger
  import Ecto.Query
  alias StarlightBot.Navigation.ScreenTimes
  alias StarlightBot.RunsRepo, as: Repo
  alias StarlightBot.Vision.DungeonGraph

  @topic "run_history"

  def subscribe, do: Phoenix.PubSub.subscribe(StarlightBot.PubSub, @topic)

  def save_run(_attrs, []), do: {:error, :no_segments}

  def save_run(attrs, [first | _] = segments) do
    now = DateTime.utc_now()
    run_start_ms = first.start_ms
    floors = segments |> Enum.map(& &1.floor) |> Enum.filter(&is_integer/1)
    max_floor = Enum.max(floors, fn -> 0 end)

    run_row = %{
      team_id: attrs[:team_id],
      team_name: attrs[:team_name],
      started_at: first.started_at,
      ended_at: now,
      result: attrs.result,
      floors_completed: if(attrs.result == "success", do: max_floor, else: max(max_floor - 1, 0)),
      duration_seconds: segments |> Enum.map(&ScreenTimes.duration_ms/1) |> Enum.sum() |> div(1000),
      notes: attrs[:notes],
      inserted_at: now,
      updated_at: now
    }

    result =
      Repo.transaction(fn ->
        {1, [%{id: run_log_id}]} = Repo.insert_all("run_logs", [run_row], returning: [:id])

        segments
        |> Enum.map(fn segment ->
          %{
            run_log_id: run_log_id,
            timestamp: segment.started_at,
            event_type: "screen",
            screen: segment.screen && to_string(segment.screen),
            data:
              Jason.encode!(%{
                task: segment.task,
                step: segment.step,
                floor: segment.floor,
                start_ms: segment.start_ms - run_start_ms,
                duration_ms: ScreenTimes.duration_ms(segment)
              }),
            inserted_at: now,
            updated_at: now
          }
        end)
        |> Enum.chunk_every(500)
        |> Enum.each(&Repo.insert_all("run_events", &1))

        Repo.update_all(
          from(e in "run_events", where: is_nil(e.run_log_id) and e.event_type == "dungeon_graph" and e.timestamp >= ^first.started_at),
          set: [run_log_id: run_log_id]
        )

        run_log_id
      end)

    if match?({:ok, _}, result),
      do: Phoenix.PubSub.broadcast(StarlightBot.PubSub, @topic, :run_history_changed)

    result
  rescue
    e ->
      Logger.error("RunHistory DB error: #{Exception.message(e)}", module: __MODULE__)
      {:error, Exception.message(e)}
  end

  def record_dungeon_graph(seen, merged, decision) do
    now = DateTime.utc_now()
    seen_edges = MapSet.new(seen.edges, &{&1.from_node, &1.to_node})

    data = %{
      decision: decision,
      floor: merged.floor,
      current_level: merged.current_level,
      warnings: merged.warnings,
      nodes: merged.nodes |> Map.values() |> Enum.sort_by(&{&1.hop, &1.level}),
      edges: Enum.map(merged.edges, &Map.put(&1, :remembered, not MapSet.member?(seen_edges, {&1.from_node, &1.to_node}))),
      node_hits: merged.node_hits,
      warning_hits: merged.warning_hits,
      diagnostics: Enum.map(seen.diagnostics, &Map.delete(&1, :region))
    }

    Repo.insert_all("run_events", [
      %{
        run_log_id: nil,
        timestamp: now,
        event_type: "dungeon_graph",
        screen: "dungeon_graph",
        data: data |> jsonable() |> Jason.encode!(),
        inserted_at: now,
        updated_at: now
      }
    ])

    :ok
  rescue
    e ->
      Logger.error("RunHistory dungeon graph error: #{Exception.message(e)}", module: __MODULE__)
      {:error, Exception.message(e)}
  end

  def dungeon_graph_snapshots(limit \\ 300) do
    Repo.all(
      from(e in "run_events",
        where: e.event_type == "dungeon_graph",
        order_by: [desc: e.id],
        limit: ^limit,
        select: %{
          id: e.id,
          run_log_id: e.run_log_id,
          timestamp: e.timestamp,
          floor: fragment("json_extract(?, '$.floor')", e.data),
          current_level: fragment("json_extract(?, '$.current_level')", e.data),
          direction: fragment("json_extract(?, '$.decision.direction')", e.data),
          kind: fragment("json_extract(?, '$.decision.kind')", e.data)
        }
      )
    )
  end

  def dungeon_graph_snapshot(id) when is_integer(id) do
    query = from(e in "run_events", where: e.id == ^id and e.event_type == "dungeon_graph", select: %{run_log_id: e.run_log_id, timestamp: e.timestamp, data: e.data})

    case Repo.one(query) do
      nil ->
        :error

      row ->
        data = Jason.decode!(row.data)

        {:ok,
         %{
           id: id,
           run_log_id: row.run_log_id,
           timestamp: row.timestamp,
           decision: data["decision"],
           graph: decode_graph(data),
           diagnostics: data["diagnostics"],
           node_hits: data["node_hits"],
           warning_hits: data["warning_hits"]
         }}
    end
  end

  defp decode_graph(data) do
    %DungeonGraph{
      floor: data["floor"],
      current_level: decode_atom(data["current_level"]),
      nodes: Map.new(data["nodes"], fn node -> {decode_slot([node["hop"], node["level"]]), %{hop: node["hop"], level: decode_atom(node["level"]), type: decode_atom(node["type"])}} end),
      edges:
        Enum.map(data["edges"], fn edge ->
          %{
            from_node: decode_slot(edge["from_node"]),
            to_node: decode_slot(edge["to_node"]),
            hook: edge["hook"],
            variant: decode_atom(edge["variant"]),
            score: edge["score"],
            rect: edge["rect"] && List.to_tuple(edge["rect"]),
            remembered: edge["remembered"]
          }
        end),
      diagnostics: [],
      warnings: Enum.map(data["warnings"], &decode_atom/1),
      node_hits: [],
      warning_hits: []
    }
  end

  defp decode_slot([hop, level]), do: {hop, decode_atom(level)}

  defp decode_atom(nil), do: nil
  defp decode_atom(name), do: String.to_existing_atom(name)

  defp jsonable(%_{} = struct), do: struct |> Map.from_struct() |> jsonable()
  defp jsonable(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key, jsonable(value)} end)
  defp jsonable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> jsonable()
  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(value), do: value

  def record_canceled(kind) when kind in [:luxcavation, :mirror_dungeon] do
    now = DateTime.utc_now()

    Repo.insert_all("run_logs", [
      %{result: "canceled", notes: Atom.to_string(kind), started_at: now, ended_at: now, floors_completed: 0, duration_seconds: 0, inserted_at: now, updated_at: now}
    ])

    Phoenix.PubSub.broadcast(StarlightBot.PubSub, "scheduler", :daily_progress)
    Phoenix.PubSub.broadcast(StarlightBot.PubSub, @topic, :run_history_changed)
    :ok
  end

  def last_canceled_at do
    Repo.one(from(r in "run_logs", where: r.result == "canceled", order_by: [desc: r.id], limit: 1, select: r.ended_at))
    |> case do
      nil -> nil
      value -> value |> NaiveDateTime.from_iso8601!() |> DateTime.from_naive!("Etc/UTC")
    end
  end

  def list_runs(limit \\ 50) do
    Repo.all(
      from(r in "run_logs",
        order_by: [desc: r.id],
        limit: ^limit,
        select: %{
          id: r.id,
          team_name: r.team_name,
          started_at: r.started_at,
          result: r.result,
          floors_completed: r.floors_completed,
          duration_seconds: r.duration_seconds
        }
      )
    )
  end

  def segments(run_log_id) when is_integer(run_log_id) do
    Repo.all(
      from(e in "run_events",
        where: e.run_log_id == ^run_log_id and e.event_type == "screen",
        order_by: [asc: e.id],
        select: %{screen: e.screen, timestamp: e.timestamp, data: e.data}
      )
    )
    |> Enum.map(fn event ->
      data = Jason.decode!(event.data)
      start_ms = data["start_ms"]

      %{
        screen: event.screen,
        task: data["task"],
        step: data["step"],
        floor: data["floor"],
        run: run_log_id,
        start_ms: start_ms,
        end_ms: start_ms + data["duration_ms"],
        started_at: event.timestamp
      }
    end)
  end
end
