defmodule StarlightBot.Input.KeyboardTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Input.Keyboard

  describe "char_to_keycode/1" do
    test "maps digits 0-9 to their key_N keycodes, no shift" do
      assert Keyboard.char_to_keycode("0") == {11, false}
      assert Keyboard.char_to_keycode("1") == {2, false}
      assert Keyboard.char_to_keycode("9") == {10, false}
    end

    test "maps lowercase letters without shift, uppercase with shift" do
      assert Keyboard.char_to_keycode("a") == {30, false}
      assert Keyboard.char_to_keycode("A") == {30, true}
    end

    test "maps space, newline, and tab" do
      assert Keyboard.char_to_keycode(" ") == {57, false}
      assert Keyboard.char_to_keycode("\n") == {28, false}
      assert Keyboard.char_to_keycode("\t") == {15, false}
    end

    test "returns nil for characters with no mapping" do
      assert Keyboard.char_to_keycode("!") == nil
      assert Keyboard.char_to_keycode("#") == nil
    end
  end
end
