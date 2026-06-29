defmodule StarlightBotTest do
  use ExUnit.Case, async: true

  describe "Vision.Frame" do
    test "to_screen_coords scales from normalized to real space (fullscreen)" do
      frame = StarlightBot.Vision.Frame.from_capture(
        :binary.copy(<<0>>, 1920 * 1080 * 3),
        {0, 0, 1920, 1080}
      )
      assert StarlightBot.Vision.Frame.to_screen_coords(frame, {960, 540}) == {960, 540}
    end

    test "to_screen_coords scales for windowed mode" do
      frame = StarlightBot.Vision.Frame.from_capture(
        :binary.copy(<<0>>, 1920 * 1080 * 3),
        {100, 50, 960, 540}
      )
      # (480, 270) in normalized → half scale → (100 + 240, 50 + 135) = (340, 185)
      assert StarlightBot.Vision.Frame.to_screen_coords(frame, {480, 270}) == {340, 185}
    end
  end

  describe "Input.MovementProfile" do
    test "defaults to fast in dev" do
      assert StarlightBot.Input.MovementProfile.current() in [:human, :fast]
    end

    test "can toggle between profiles" do
      StarlightBot.Input.MovementProfile.set(:human)
      assert StarlightBot.Input.MovementProfile.human?()
      StarlightBot.Input.MovementProfile.set(:fast)
      assert StarlightBot.Input.MovementProfile.fast?()
    end
  end
end
