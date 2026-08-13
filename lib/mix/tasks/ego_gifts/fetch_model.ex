defmodule Mix.Tasks.EgoGifts.FetchModel do
  @shortdoc "Copy the EgoGiftML detector/classifier ONNX models into priv/"
  @moduledoc """
  Copies the "best" detector + classifier ONNX models (and the classifier's class
  map) from the vendor/EgoGiftML submodule into priv/models/ego_gifts/, where
  StarlightBot.Vision.EgoGiftDetector loads them from at runtime.

  The .pt (PyTorch) variants are not copied — Evision.DNN loads ONNX directly.

  Idempotent — always overwrites with the submodule's current files.

      mix ego_gifts.fetch_model
  """

  use Mix.Task

  @vendor_dir Path.expand("../../../../vendor/EgoGiftML", __DIR__)
  @source_dir Path.join(@vendor_dir, "models/best")
  @dest_dir Path.expand("../../../../priv/models/ego_gifts", __DIR__)

  @files ~w(detector.onnx classifier.onnx classifier_classes.json metadata.json)

  @impl Mix.Task
  def run(_args) do
    unless File.dir?(@source_dir) do
      Mix.raise("#{@source_dir} not found — run `git submodule update --init` first")
    end

    File.mkdir_p!(@dest_dir)

    for file <- @files do
      src = Path.join(@source_dir, file)

      unless File.exists?(src) do
        Mix.raise("#{src} not found in vendored EgoGiftML models/best/")
      end

      File.cp!(src, Path.join(@dest_dir, file))
      Mix.shell().info("Copied #{file}")
    end
  end
end
