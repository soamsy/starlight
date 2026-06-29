defmodule StarlightBot.Ctx do
  defstruct on_log: &__MODULE__.ignore/1, on_pause: &__MODULE__.ignore/0

  @type t :: %__MODULE__{
          on_log: ({:ok | :info | :error, String.t()} -> :ok),
          on_pause: (-> :ok)
        }

  def new(fields \\ []), do: struct(__MODULE__, fields)

  def log(%__MODULE__{on_log: on_log}, kind, text), do: on_log.({kind, text})

  def pause(%__MODULE__{on_pause: on_pause}), do: on_pause.()

  def ignore(_), do: :ok
  def ignore, do: :ok
end
