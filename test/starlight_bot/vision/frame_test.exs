defmodule StarlightBot.Vision.FrameTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Vision.Frame

  @window {0, 0, 1920, 1080}

  defp gradient_frame do
    binary = for y <- 0..1079, x <- 0..1919, into: <<>>, do: <<rem(x, 256), rem(y, 256), 0>>
    Frame.from_capture(binary, @window)
  end

  defp pixels(mat), do: Evision.Mat.to_binary(mat)

  test "a patch frame returns the same pixels as the full frame for a rect inside a patch" do
    full = gradient_frame()
    patch_rect = {100, 200, 300, 150}
    partial = Frame.from_patches([{patch_rect, Frame.crop(full.mat, patch_rect)}], @window)

    assert pixels(Frame.region(partial, patch_rect)) == pixels(Frame.region(full, patch_rect))
    assert pixels(Frame.region(partial, {150, 250, 40, 30})) == pixels(Frame.region(full, {150, 250, 40, 30}))
  end

  test "a patch frame raises for a rect no patch covers" do
    full = gradient_frame()
    partial = Frame.from_patches([{{0, 0, 50, 50}, Frame.crop(full.mat, {0, 0, 50, 50})}], @window)

    assert_raise ArgumentError, fn -> Frame.region(partial, {40, 40, 20, 20}) end
  end

  test "covers? and full? tell full frames from patch frames" do
    full = gradient_frame()
    partial = Frame.from_patches([{{0, 0, 50, 50}, Frame.crop(full.mat, {0, 0, 50, 50})}], @window)

    assert Frame.full?(full)
    refute Frame.full?(partial)
    assert Frame.covers?(full, [{1000, 1000, 10, 10}])
    assert Frame.covers?(partial, [{10, 10, 20, 20}])
    refute Frame.covers?(partial, [{10, 10, 20, 20}, {60, 60, 5, 5}])
  end
end
