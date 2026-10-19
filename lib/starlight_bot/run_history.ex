defmodule StarlightBot.RunHistory do
  require Logger
  import Ecto.Query
  alias StarlightBot.Navigation.ScreenTimes
  alias StarlightBot.Repo

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
