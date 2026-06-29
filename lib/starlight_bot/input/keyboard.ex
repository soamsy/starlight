defmodule StarlightBot.Input.Keyboard do
  use GenServer
  require Logger
  alias StarlightBot.Native

  @keycodes %{
    esc: 1,
    key_1: 2,
    key_2: 3,
    key_3: 4,
    key_4: 5,
    key_5: 6,
    key_6: 7,
    key_7: 8,
    key_8: 9,
    key_9: 10,
    key_0: 11,
    minus: 12,
    equal: 13,
    backspace: 14,
    tab: 15,
    q: 16,
    w: 17,
    e: 18,
    r: 19,
    t: 20,
    y: 21,
    u: 22,
    i: 23,
    o: 24,
    p: 25,
    a: 30,
    s: 31,
    d: 32,
    f: 33,
    g: 34,
    h: 35,
    j: 36,
    k: 37,
    l: 38,
    z: 44,
    x: 45,
    c: 46,
    v: 47,
    b: 48,
    n: 49,
    m: 50,
    enter: 28,
    space: 57,
    f1: 59,
    f2: 60,
    f3: 61,
    f4: 62,
    f5: 63,
    f6: 64,
    f7: 65,
    f8: 66,
    f9: 67,
    f10: 68,
    f11: 87,
    f12: 88,
    left: 105,
    right: 106,
    up: 103,
    down: 108,
    home: 102,
    end: 107,
    pageup: 104,
    pagedown: 109,
    insert: 110,
    delete: 111,
    lshift: 42,
    rshift: 54,
    lctrl: 29,
    rctrl: 97,
    lalt: 56,
    ralt: 100,
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def press(key) do
    GenServer.call(__MODULE__, {:press, key, 1})
  end

  def press(key, count) when is_integer(count) and count > 0 do
    GenServer.call(__MODULE__, {:press, key, count})
  end

  def hold(keys) when is_list(keys) do
    GenServer.call(__MODULE__, {:hold, keys})
  end

  def type(string) when is_binary(string) do
    GenServer.call(__MODULE__, {:type, string}, 10_000)
  end

  def release_all do
    GenServer.cast(__MODULE__, :release_all)
  end


  @impl true
  def init(_opts) do
    Logger.debug("Input.Keyboard starting", module: __MODULE__)
    {:ok, %{held_keys: []}}
  end

  @impl true
  def handle_call({:press, key, count}, _from, state) do
    keycode = resolve_key(key)
    Enum.each(1..count, fn _ ->
      key_event(keycode, true)
      :timer.sleep(30)
      key_event(keycode, false)
      :timer.sleep(15)
    end)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:hold, keys}, _from, state) do
    keycodes = Enum.map(keys, &resolve_key/1)
    Enum.each(keycodes, &key_event(&1, true))
    :timer.sleep(50)
    Enum.each(keycodes, &key_event(&1, false))
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:type, string}, _from, state) do
    string
    |> String.graphemes()
    |> Enum.each(fn char ->
      case char_to_keycode(char) do
        nil -> Logger.warning("No keycode for character: #{inspect(char)}", module: __MODULE__)
        {keycode, with_shift} ->
          if with_shift, do: key_event(@keycodes.lshift, true)
          key_event(keycode, true)
          :timer.sleep(20)
          key_event(keycode, false)
          if with_shift, do: key_event(@keycodes.lshift, false)
          :timer.sleep(10)
      end
    end)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:release_all, state) do
    keycodes = Enum.map(state.held_keys, &resolve_key/1)
    Native.release_all_inputs(keycodes)
    {:noreply, %{state | held_keys: []}}
  end

  defp key_event(keycode, pressed) do
    case Native.key_event(keycode, pressed) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "key_event(#{keycode}, #{pressed}) failed: #{inspect(reason)}",
          module: __MODULE__
        )

        :ok
    end
  end

  defp resolve_key(key) when is_atom(key) do
    Map.get(@keycodes, key) ||
      raise ArgumentError, "Unknown key atom: #{inspect(key)}. See @keycodes in Keyboard module."
  end
  defp resolve_key(key) when is_integer(key), do: key

  def char_to_keycode(char) do
    case char do
      " " -> {@keycodes.space, false}
      "\n" -> {@keycodes.enter, false}
      "\t" -> {@keycodes.tab, false}
      d when d in ~w(0 1 2 3 4 5 6 7 8 9) -> {Map.fetch!(@keycodes, :"key_#{d}"), false}
      _ ->
        lower = String.downcase(char)
        case Map.get(@keycodes, String.to_atom(lower)) do
          nil -> nil
          code -> {code, char != lower}
        end
    end
  end
end
