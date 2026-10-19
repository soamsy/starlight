defmodule StarlightBot.Ctx do
  defstruct on_log: &__MODULE__.ignore/1,
            on_pause: &__MODULE__.ignore/0,
            pause_requested?: &__MODULE__.never/0,
            on_run_memory_change: &__MODULE__.ignore/1,
            run_memory: nil

  @type t :: %__MODULE__{
          on_log: ({:ok | :info | :error, String.t()} -> :ok),
          on_pause: (-> :ok),
          pause_requested?: (-> boolean()),
          on_run_memory_change: (map() -> :ok),
          run_memory: pid() | nil
        }

  def new(fields \\ []), do: struct(__MODULE__, fields)

  def log(%__MODULE__{on_log: on_log}, kind, text) do
    StarlightBot.LogStore.append(kind, text)
    on_log.({kind, text})
  end

  def pause(%__MODULE__{on_pause: on_pause}), do: on_pause.()

  def pause_requested?(%__MODULE__{pause_requested?: pause_requested?}), do: pause_requested?.()

  def run_memory_changed(%__MODULE__{on_run_memory_change: on_run_memory_change}, snapshot),
    do: on_run_memory_change.(snapshot)

  def ignore(_), do: :ok
  def ignore, do: :ok
  def never, do: false
end
