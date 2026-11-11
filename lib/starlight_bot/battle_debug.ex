defmodule StarlightBot.BattleDebug do
  alias StarlightBot.{AppSettings, Ctx, Data}
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.BattleDebug.Detect
  alias StarlightBot.Vision.{Frame, SkillTray}

  @enemy_box_w 120
  @enemy_box_h 90
  @enemy_box_above_px 45

  def enabled?, do: Data.authoring?() and AppSettings.battle_debug?()

  def record_tray(%Frame{} = frame, %SkillTray{} = tray, %Ctx{} = ctx) do
    if enabled?() do
      context = context(ctx)
      spawn_write("chain_tray", frame, fn -> Detect.tray(frame, tray) end, context)
    end

    :ok
  end

  def record_enemies(%Frame{} = frame, targets, %Ctx{} = ctx) when is_list(targets) do
    if enabled?() do
      context = context(ctx)
      spawn_write("focused_enemies", frame, fn -> Detect.enemies(targets) end, context)
    end

    :ok
  end

  def list do
    dir = Data.battle_debug_dir()

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&(String.ends_with?(&1, ".json") and not String.ends_with?(&1, ".truth.json")))
        |> Enum.sort(:desc)
        |> Enum.flat_map(fn name ->
          id = Path.rootname(name)

          case get(id) do
            nil -> []
            record -> [record]
          end
        end)
        |> Enum.sort_by(&is_nil(&1["review"]))

      {:error, _} ->
        []
    end
  end

  def get(id) do
    with {:ok, body} <- File.read(json_path(id)),
         {:ok, record} <- Jason.decode(body) do
      Map.merge(record, %{"id" => safe_id(id), "labeled?" => File.exists?(truth_path(id)), "in_suite?" => in_suite?(id), "review" => review(id)})
    else
      _ -> nil
    end
  end

  def truth(id, record) do
    with {:ok, body} <- File.read(truth_path(id)),
         {:ok, truth} <- Jason.decode(body) do
      truth
    else
      _ -> default_truth(record)
    end
  end

  def save_truth(id, truth) do
    clear_review(id)
    File.write!(truth_path(id), Jason.encode!(truth, pretty: true))
  end

  def review(id) do
    with {:ok, body} <- File.read(review_path(id)),
         {:ok, cells} <- Jason.decode(body) do
      cells
    else
      _ -> nil
    end
  end

  def clear_review(id), do: File.rm(review_path(id))

  def reset_truth(id) do
    File.rm(truth_path(id))
    :ok
  end

  def default_truth(%{"kind" => "chain_tray", "detected" => %{"slots" => slots}}), do: %{"slots" => Enum.map(slots, &strip_confidence/1)}

  def default_truth(%{"kind" => "focused_enemies", "detected" => %{"enemies" => enemies}}) do
    %{
      "rects" =>
        Enum.map(enemies, fn %{"x" => x, "y" => y} ->
          %{"x" => x - div(@enemy_box_w, 2), "y" => y - @enemy_box_above_px, "w" => @enemy_box_w, "h" => @enemy_box_h}
        end)
    }
  end

  def in_suite?(id), do: File.exists?(suite_path(id))

  def set_suite(id, true) do
    clear_review(id)
    File.write!(suite_path(id), "")
  end

  def set_suite(id, false) do
    File.rm(suite_path(id))
    :ok
  end

  def delete_outside_suite do
    {kept, doomed} = list() |> Enum.split_with(& &1["in_suite?"])

    files =
      Enum.flat_map(doomed, fn %{"id" => id} -> [json_path(id), image_path(id), truth_path(id), review_path(id)] end)
      |> Enum.filter(&File.exists?/1)

    if files != [], do: System.cmd("gio", ["trash" | files], stderr_to_stdout: true)
    %{deleted: length(doomed), kept: length(kept)}
  end

  def delete(id) do
    files = Enum.filter([json_path(id), image_path(id), truth_path(id), review_path(id), suite_path(id)], &File.exists?/1)
    if files != [], do: System.cmd("gio", ["trash" | files], stderr_to_stdout: true)
    :ok
  end

  def load_frame(id) do
    path = image_path(id)

    with true <- File.exists?(path),
         %Evision.Mat{} = mat <- Evision.imread(path) do
      {:ok, %Frame{binary: nil, mat: mat, window_rect: {0, 0, 1920, 1080}, scale: 1.0, captured_at: System.monotonic_time(:millisecond)}}
    else
      _ -> :error
    end
  end

  def image_path(id), do: Path.join(Data.battle_debug_dir(), safe_id(id) <> ".png")

  defp json_path(id), do: Path.join(Data.battle_debug_dir(), safe_id(id) <> ".json")
  defp review_path(id), do: Path.join(Data.battle_debug_dir(), safe_id(id) <> ".review")
  defp suite_path(id), do: Path.join(Data.battle_debug_dir(), safe_id(id) <> ".suite")
  defp truth_path(id), do: Path.join(Data.battle_debug_dir(), safe_id(id) <> ".truth.json")
  defp safe_id(id), do: id |> to_string() |> Path.basename()

  defp strip_confidence(slot) do
    %{
      "sinner_start" => slot["sinner_start"],
      "top" => Map.take(slot["top"], ["sin", "tier"]),
      "bottom" => Map.take(slot["bottom"], ["sin", "tier"])
    }
  end

  defp spawn_write(kind, frame, detect_fun, context) do
    Task.Supervisor.start_child(StarlightBot.TaskSupervisor, fn -> write(kind, frame, detect_fun, context) end)
  end

  defp write(kind, frame, detect_fun, context) do
    now = DateTime.utc_now()
    id = Calendar.strftime(now, "%Y-%m-%d_%H-%M-%S-") <> millis(now) <> "_" <> kind
    dir = Data.battle_debug_dir()
    File.mkdir_p!(dir)
    meta = Map.merge(%{kind: kind, captured_at: DateTime.to_iso8601(now), detected: detect_fun.()}, context)

    if Evision.imwrite(Path.join(dir, id <> ".png"), frame.mat) do
      File.write!(Path.join(dir, id <> ".json"), Jason.encode!(meta, pretty: true))
    end
  rescue
    _ -> :error
  end

  defp millis(now), do: now.microsecond |> elem(0) |> div(1000) |> Integer.to_string() |> String.pad_leading(3, "0")

  defp context(ctx), do: %{floor: RunMemory.floor(ctx), battle_turn: RunMemory.battle_turn(ctx)}
end
