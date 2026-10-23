defmodule StarlightBot.FakeWorld do
  use GenServer

  alias StarlightBot.Vision.{Frame, Hook}

  @capture StarlightBot.Vision.Capture
  @size 24
  @width 1920
  @height 1080
  @window {0, 0, @width, @height}

  defmodule Input do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

    @impl true
    def init(nil), do: {:ok, nil}

    @impl true
    def handle_call(msg, _from, state), do: {:reply, GenServer.call(StarlightBot.Vision.Capture, {:input, msg}), state}

    @impl true
    def handle_cast(_msg, state), do: {:noreply, state}
  end

  def start!(opts \\ []) do
    hooks = Keyword.get(opts, :hooks, [])
    ExUnit.Callbacks.start_supervised!({__MODULE__, opts})
    ExUnit.Callbacks.start_supervised!(Supervisor.child_spec({Input, StarlightBot.Input.Mouse}, id: :fake_mouse))
    ExUnit.Callbacks.start_supervised!(Supervisor.child_spec({Input, StarlightBot.Input.Keyboard}, id: :fake_keyboard))
    ExUnit.Callbacks.on_exit(fn -> Enum.each(hooks, &:ets.delete(:hook_registry, &1)) end)
    :ok
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: @capture)

  def show(hooks), do: GenServer.call(@capture, {:change, show: List.wrap(hooks)})
  def hide(hooks), do: GenServer.call(@capture, {:change, hide: List.wrap(hooks)})
  def focus(focused?), do: GenServer.call(@capture, {:focus, focused?})
  def react(input, changes), do: GenServer.call(@capture, {:react, input, changes})
  def inputs, do: GenServer.call(@capture, :inputs)

  @impl true
  def init(opts) do
    hooks = Keyword.get(opts, :hooks, [])

    {slots, patches} =
      hooks
      |> Enum.with_index()
      |> Enum.map(fn {name, i} -> {{name, slot(i)}, {name, patch(i)}} end)
      |> Enum.unzip()

    slots = Map.new(slots)
    patches = Map.new(patches)
    Enum.each(hooks, &:ets.insert(:hook_registry, {&1, hook(&1, slots[&1], patches[&1])}))

    {:ok,
     %{
       focused?: Keyword.get(opts, :focused?, true),
       visible: MapSet.new(Keyword.get(opts, :visible, [])),
       slots: slots,
       patches: patches,
       reactions: [],
       inputs: []
     }}
  end

  @impl true
  def handle_call(:focused?, _from, state), do: {:reply, state.focused?, state}
  def handle_call(:window_rect, _from, state), do: {:reply, @window, state}
  def handle_call(:grab_frame, _from, state), do: {:reply, {:ok, frame(state)}, state}
  def handle_call(:inputs, _from, state), do: {:reply, Enum.reverse(state.inputs), state}
  def handle_call({:focus, focused?}, _from, state), do: {:reply, :ok, %{state | focused?: focused?}}
  def handle_call({:change, changes}, _from, state), do: {:reply, :ok, apply_changes(state, changes)}

  def handle_call({:react, input, changes}, _from, state),
    do: {:reply, :ok, %{state | reactions: state.reactions ++ [{input, changes}]}}

  def handle_call({:input, msg}, _from, state) do
    input = describe(msg, state)
    state = %{state | inputs: [input | state.inputs]}

    state =
      state.reactions
      |> Enum.filter(fn {wanted, _} -> wanted == input end)
      |> Enum.reduce(state, fn {_, changes}, acc -> react_now_or_later(acc, changes) end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:apply, changes}, state), do: {:noreply, apply_changes(state, changes)}

  defp react_now_or_later(state, changes) do
    case Keyword.pop(changes, :after) do
      {nil, changes} ->
        apply_changes(state, changes)

      {ms, changes} ->
        Process.send_after(self(), {:apply, changes}, ms)
        state
    end
  end

  defp apply_changes(state, changes) do
    visible =
      state.visible
      |> MapSet.union(MapSet.new(Keyword.get(changes, :show, [])))
      |> MapSet.difference(MapSet.new(Keyword.get(changes, :hide, [])))

    %{state | visible: visible}
  end

  defp describe({:click, x, y, _button, _opts}, state), do: {:click, hook_at(state, x, y)}
  defp describe({:press, key, _count}, _state), do: {:key, key}
  defp describe({:type, text}, _state), do: {:type, text}
  defp describe({:button, _button, true}, _state), do: {:mouse, :down}
  defp describe({:button, _button, false}, _state), do: {:mouse, :up}
  defp describe(msg, _state), do: msg

  defp hook_at(state, x, y) do
    Enum.find_value(state.slots, {x, y}, fn {name, {sx, sy}} ->
      if x >= sx and x < sx + @size and y >= sy and y < sy + @size, do: name
    end)
  end

  defp slot(i), do: {40 + rem(i, 20) * 80, 40 + div(i, 20) * 80}

  defp patch(i) do
    :rand.seed(:exsss, {i + 1, 7, 13})
    for _ <- 1..(@size * @size), into: <<>>, do: (v = :rand.uniform(255); <<v, v, v>>)
  end

  defp hook(name, {x, y}, patch) do
    mat = Evision.Mat.from_binary(patch, {:u, 8}, @size, @size, 3)
    %Hook{name: name, mat: mat, gray_mat: Evision.cvtColor(mat, 6), region: {x, y, @size, @size}, method: :gray, confidence: 0.9}
  end

  defp frame(state) do
    placed = for name <- state.visible, Map.has_key?(state.slots, name), do: {state.slots[name], state.patches[name]}

    binary =
      for r <- 0..(@height - 1), into: <<>> do
        placed
        |> Enum.filter(fn {{_x, y}, _} -> r >= y and r < y + @size end)
        |> Enum.map(fn {{x, y}, patch} -> {x, binary_part(patch, (r - y) * @size * 3, @size * 3)} end)
        |> Enum.sort()
        |> row(0, <<>>)
      end

    Frame.from_capture(binary, @window)
  end

  defp row([], cursor, acc), do: <<acc::binary, 0::size((@width - cursor) * 24)>>
  defp row([{x, line} | rest], cursor, acc), do: row(rest, x + @size, <<acc::binary, 0::size((x - cursor) * 24), line::binary>>)
end
