defmodule StarlightBot.Vision.EgoGiftCapture do
  use GenServer
  require Logger

  @enabled_key {__MODULE__, :enabled}
  @dedup_bucket_px 10

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def enable, do: GenServer.call(__MODULE__, {:enable, self()})

  def disable, do: GenServer.call(__MODULE__, :disable)

  def enabled?, do: :persistent_term.get(@enabled_key, false)

  def record(tag, crop, detections),
    do: GenServer.cast(__MODULE__, {:record, tag, crop, detections})

  @impl true
  def init(_) do
    :persistent_term.put(@enabled_key, false)
    {:ok, %{owner_ref: nil, seen: MapSet.new()}}
  end

  @impl true
  def handle_call({:enable, owner}, _from, state) do
    state = demonitor_owner(state)
    :persistent_term.put(@enabled_key, true)
    {:reply, :ok, %{state | owner_ref: Process.monitor(owner), seen: MapSet.new()}}
  end

  def handle_call(:disable, _from, state) do
    :persistent_term.put(@enabled_key, false)
    {:reply, :ok, demonitor_owner(state)}
  end

  @impl true
  def handle_cast({:record, tag, crop, detections}, state) do
    signature = {tag, detections |> Enum.map(&signature_entry/1) |> Enum.sort()}

    if enabled?() and not MapSet.member?(state.seen, signature) do
      try do
        write_capture(tag, crop, detections)
      rescue
        e -> Logger.warning("EgoGiftCapture: failed to save #{tag} capture: #{Exception.message(e)}", module: __MODULE__)
      end

      {:noreply, %{state | seen: MapSet.put(state.seen, signature)}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    :persistent_term.put(@enabled_key, false)
    {:noreply, %{state | owner_ref: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  defp demonitor_owner(%{owner_ref: nil} = state), do: state

  defp demonitor_owner(%{owner_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    %{state | owner_ref: nil}
  end

  defp signature_entry(%{box: box, preds: preds}) do
    top_id = preds |> List.first() |> then(&(&1 && &1.id))
    {bucket(box.x), bucket(box.y), bucket(box.w), bucket(box.h), top_id}
  end

  defp bucket(v), do: round(v / @dedup_bucket_px)

  defp write_capture(tag, crop, detections) do
    root = Application.fetch_env!(:starlight_bot, :ego_gift_ml_dir)
    resources = Path.join(root, "resources")
    now = NaiveDateTime.from_erl!(:calendar.local_time())
    stamp = Calendar.strftime(now, "%Y%m%d-%H%M%S")
    suffix = :crypto.strong_rand_bytes(2) |> Base.encode16(case: :lower)
    key = "captures/#{tag}/#{stamp}-#{suffix}.png"
    image_path = Path.join(resources, key)

    File.mkdir_p!(Path.dirname(image_path))
    true = Evision.imwrite(image_path, crop)

    {h, w} = crop_hw(crop)

    entry =
      Jason.OrderedObject.new([
        {"region", rect(0, 0, w, h)},
        {"gifts", Enum.map(detections, &gift_entry/1)},
        {"ignore_for_training", true},
        {"unreviewed", true}
      ])

    add_manual_train_entry(Path.join(resources, "manual_train.json"), key, entry)
  end

  defp gift_entry(%{box: box, preds: preds}) do
    top = List.first(preds) || %{id: nil, name: nil, confidence: nil}

    Jason.OrderedObject.new([
      {"id", top.id || ""},
      {"name", top.name || ""},
      {"subregion", rect(box.x, box.y, box.w, box.h)},
      {"detector_confidence", Float.round(box.confidence, 4)},
      {"classifier_confidence", top.confidence && Float.round(top.confidence, 4)},
      {"topk",
       Enum.map(preds, fn p ->
         Jason.OrderedObject.new([{"id", p.id}, {"name", p.name}, {"confidence", Float.round(p.confidence, 4)}])
       end)}
    ])
  end

  defp rect(x, y, w, h) do
    x0 = round(x)
    y0 = round(y)
    Jason.OrderedObject.new([{"x", x0}, {"y", y0}, {"w", round(x + w) - x0}, {"h", round(y + h) - y0}])
  end

  defp add_manual_train_entry(json_path, key, entry) do
    %Jason.OrderedObject{values: top} =
      case File.read(json_path) do
        {:ok, body} -> Jason.decode!(body, objects: :ordered_objects)
        {:error, :enoent} -> Jason.OrderedObject.new([{"gifts", Jason.OrderedObject.new([])}])
      end

    top =
      case List.keyfind(top, "gifts", 0) do
        {"gifts", %Jason.OrderedObject{values: gifts}} ->
          List.keyreplace(top, "gifts", 0, {"gifts", %Jason.OrderedObject{values: gifts ++ [{key, entry}]}})

        nil ->
          top ++ [{"gifts", Jason.OrderedObject.new([{key, entry}])}]
      end

    tmp_path = json_path <> ".starlight-tmp"
    File.write!(tmp_path, Jason.encode!(%Jason.OrderedObject{values: top}, pretty: true) <> "\n")
    File.rename!(tmp_path, json_path)
  end

  defp crop_hw(mat) do
    case Evision.Mat.shape(mat) do
      {h, w, _} -> {h, w}
      {h, w} -> {h, w}
    end
  end
end
