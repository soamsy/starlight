defmodule StarlightBot.Vision.EgoGiftDetector do
  use GenServer
  require Logger

  @color_bgr2rgb 4  # cv_COLOR_BGR2RGB
  @border_constant 0  # cv_BORDER_CONSTANT

  @letterbox_gray {114.0, 114.0, 114.0, 0.0}  # must match training's "nothing space" fill color
  @classifier_input_size 160

  @default_det_imgsz 384
  @default_det_conf 0.25
  @default_det_iou 0.45
  @default_cls_topk 3
  @default_cls_conf 0.8

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Detects ego gifts inside `region` (`{x, y, w, h}` in `frame_mat`'s coordinate
  space) of the given BGR frame. Returns
  `{:ok, [%{x:, y:, w:, h:, gift_id:, gift_name:, detector_confidence:, classifier_confidence:, topk:}]}`.

  Opts: `:imgsz`, `:conf`, `:iou` (detector), `:topk`, `:classifier_conf` (classifier).
  """
  def detect(frame_mat, region, opts \\ []) do
    GenServer.call(__MODULE__, {:detect, frame_mat, region, opts}, 30_000)
  end

  @impl true
  def init(_) do
    {:ok, load_models()}
  end

  @impl true
  def handle_call({:detect, frame_mat, region, opts}, _from, state) do
    {:reply, run_detect(state, frame_mat, region, opts), state}
  end

  defp load_models do
    dir = Path.join([:code.priv_dir(:starlight_bot), "models", "ego_gifts"])
    detector_path = Path.join(dir, "detector.onnx")
    classifier_path = Path.join(dir, "classifier.onnx")
    classes_path = Path.join(dir, "classifier_classes.json")

    if File.exists?(detector_path) and File.exists?(classifier_path) and File.exists?(classes_path) do
      try do
        detector_net = Evision.DNN.readNetFromONNX(detector_path)
        classifier_net = Evision.DNN.readNetFromONNX(classifier_path)

        classes =
          classes_path
          |> File.read!()
          |> Jason.decode!()
          |> Map.new(fn %{"index" => idx, "id" => id, "name" => name} -> {idx, %{id: id, name: name}} end)

        Logger.info("EgoGiftDetector: loaded detector + classifier (#{map_size(classes)} classes)",
          module: __MODULE__)

        %{detector_net: detector_net, classifier_net: classifier_net, classes: classes}
      rescue
        e ->
          Logger.warning("EgoGiftDetector: failed to load models: #{Exception.message(e)}", module: __MODULE__)
          %{detector_net: nil, classifier_net: nil, classes: %{}}
      end
    else
      Logger.warning(
        "EgoGiftDetector: models not found under #{dir} — run `mix ego_gifts.fetch_model`",
        module: __MODULE__
      )

      %{detector_net: nil, classifier_net: nil, classes: %{}}
    end
  end

  defp run_detect(%{detector_net: nil}, _frame_mat, _region, _opts), do: {:error, :models_not_loaded}

  defp run_detect(state, frame_mat, {rx, ry, rw, rh}, opts) do
    {fh, fw} = mat_hw(frame_mat)
    x0 = max(0, round(rx))
    y0 = max(0, round(ry))
    x1 = min(fw, round(rx + rw))
    y1 = min(fh, round(ry + rh))

    if x1 <= x0 or y1 <= y0 do
      {:error, :empty_region}
    else
      crop = Evision.Mat.roi(frame_mat, {x0, y0, x1 - x0, y1 - y0})

      imgsz = Keyword.get(opts, :imgsz, @default_det_imgsz)
      det_conf = Keyword.get(opts, :conf, @default_det_conf) * 1.0
      iou = Keyword.get(opts, :iou, @default_det_iou) * 1.0
      topk = Keyword.get(opts, :topk, @default_cls_topk)
      min_cls_conf = Keyword.get(opts, :classifier_conf, @default_cls_conf)

      boxes = run_detector(state.detector_net, crop, det_conf, iou, imgsz)

      results =
        Enum.map(boxes, fn box ->
          sub_crop = crop_box(crop, box)
          preds = run_classifier(state.classifier_net, state.classes, sub_crop, topk)
          top = List.first(preds)
          accepted? = top != nil and top.confidence >= min_cls_conf

          %{
            x: x0 + box.x,
            y: y0 + box.y,
            w: box.w,
            h: box.h,
            detector_confidence: box.confidence,
            gift_id: if(accepted?, do: top.id),
            gift_name: if(accepted?, do: top.name),
            classifier_confidence: if(accepted?, do: top.confidence),
            topk: preds
          }
        end)

      {:ok, results}
    end
  end

  # --- detector: letterbox-pad to a square, run YOLO-style single-class net, un-letterbox + NMS ---

  defp run_detector(net, img_bgr, conf, iou, imgsz) do
    {padded, r, pad_left, pad_top} = letterbox(img_bgr, imgsz)

    blob =
      Evision.DNN.blobFromImage(padded,
        scalefactor: 1.0 / 255.0,
        size: {imgsz, imgsz},
        mean: {0.0, 0.0, 0.0, 0.0},
        swapRB: true,
        crop: false
      )

    Evision.DNN.Net.setInput(net, blob)

    [channels] =
      net
      |> Evision.DNN.Net.forward()
      |> forward_mat()
      |> Evision.Mat.to_nx()
      |> Nx.to_list()

    preds = channels |> Enum.zip() |> Enum.map(&Tuple.to_list/1)
    {img_h, img_w} = mat_hw(img_bgr)

    candidates =
      preds
      |> Enum.filter(fn [_cx, _cy, _w, _h, score | _] -> score > conf end)
      |> Enum.map(fn [cx, cy, w, h, score | _] ->
        {score, {cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2}}
      end)

    case candidates do
      [] ->
        []

      _ ->
        nms_boxes = Enum.map(candidates, fn {_s, {x0, y0, x1, y1}} -> {x0, y0, x1 - x0, y1 - y0} end)
        nms_scores = Enum.map(candidates, fn {s, _} -> s end)
        kept = Evision.DNN.nmsBoxes(nms_boxes, nms_scores, conf, iou)

        kept
        |> Enum.map(&Enum.at(candidates, &1))
        |> Enum.map(fn {score, {x0, y0, x1, y1}} ->
          unletterboxed_box(x0, y0, x1, y1, pad_left, pad_top, r, img_w, img_h, score)
        end)
        |> Enum.reject(&is_nil/1)
    end
  end

  defp letterbox(img_bgr, new_size) do
    {h, w} = mat_hw(img_bgr)
    r = min(new_size / h, new_size / w)
    new_w = round(w * r)
    new_h = round(h * r)
    dw = (new_size - new_w) / 2
    dh = (new_size - new_h) / 2

    resized = Evision.resize(img_bgr, {new_w, new_h})

    top = round(dh - 0.1)
    bottom = round(dh + 0.1)
    left = round(dw - 0.1)
    right = round(dw + 0.1)

    padded = Evision.copyMakeBorder(resized, top, bottom, left, right, @border_constant, value: @letterbox_gray)

    {padded, r, left, top}
  end

  defp unletterboxed_box(x0, y0, x1, y1, pad_left, pad_top, r, img_w, img_h, score) do
    ux0 = max(0.0, (x0 - pad_left) / r)
    uy0 = max(0.0, (y0 - pad_top) / r)
    ux1 = min(img_w * 1.0, (x1 - pad_left) / r)
    uy1 = min(img_h * 1.0, (y1 - pad_top) / r)

    if ux1 > ux0 and uy1 > uy0 do
      %{x: ux0, y: uy0, w: ux1 - ux0, h: uy1 - uy0, confidence: score}
    end
  end

  defp crop_box(mat, %{x: x, y: y, w: w, h: h}) do
    {mh, mw} = mat_hw(mat)
    bx = max(0, round(x))
    by = max(0, round(y))
    bw = min(mw - bx, round(w))
    bh = min(mh - by, round(h))

    if bw > 0 and bh > 0, do: Evision.Mat.roi(mat, {bx, by, bw, bh})
  end

  # --- classifier: resize to a fixed square, ImageNet-normalize, softmax + top-k ---

  defp run_classifier(_net, _classes, nil, _topk), do: []

  defp run_classifier(net, classes, crop, topk) do
    normalized =
      crop
      |> Evision.resize({@classifier_input_size, @classifier_input_size})
      |> Evision.cvtColor(@color_bgr2rgb)
      |> Evision.Mat.to_nx()
      |> Nx.as_type(:f32)
      |> Nx.divide(255.0)
      |> Nx.subtract(imagenet_mean())
      |> Nx.divide(imagenet_std())

    blob = normalized |> Nx.transpose(axes: [2, 0, 1]) |> Nx.new_axis(0)

    Evision.DNN.Net.setInput(net, blob)

    logits =
      net
      |> Evision.DNN.Net.forward()
      |> forward_mat()
      |> Evision.Mat.to_nx()
      |> Nx.to_flat_list()

    softmax_topk(logits, classes, topk)
  end

  defp softmax_topk(logits, classes, topk) do
    max_logit = Enum.max(logits)
    exps = Enum.map(logits, &:math.exp(&1 - max_logit))
    sum_exp = Enum.sum(exps)

    exps
    |> Enum.with_index()
    |> Enum.sort_by(fn {e, _i} -> -e end)
    |> Enum.take(max(topk, 1))
    |> Enum.map(fn {e, i} ->
      class = Map.get(classes, i, %{id: nil, name: nil})
      %{id: class.id, name: class.name, confidence: e / sum_exp}
    end)
  end

  defp imagenet_mean, do: Nx.tensor([0.485, 0.456, 0.406], type: :f32)
  defp imagenet_std, do: Nx.tensor([0.229, 0.224, 0.225], type: :f32)

  defp forward_mat([mat]), do: mat
  defp forward_mat(mat), do: mat

  defp mat_hw(mat) do
    case Evision.Mat.shape(mat) do
      {h, w, _} -> {h, w}
      {h, w} -> {h, w}
    end
  end
end
