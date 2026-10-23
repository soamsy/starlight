defmodule StarlightBot.Ctx do
  defstruct log_to: nil,
            paused_to: nil,
            pause_flag: nil,
            run_memory_to: nil,
            run_memory: nil

  @type t :: %__MODULE__{
          log_to: {pid(), term()} | nil,
          paused_to: {pid(), term()} | nil,
          pause_flag: :atomics.atomics_ref() | nil,
          run_memory_to: {pid(), term()} | nil,
          run_memory: pid() | nil
        }

  def new(fields \\ []), do: struct(__MODULE__, fields)

  def log(%__MODULE__{log_to: log_to}, kind, text) do
    StarlightBot.LogStore.append(kind, text)
    with {pid, tag} <- log_to, do: send(pid, {tag, kind, text})
    :ok
  end

  def pause(%__MODULE__{paused_to: paused_to}) do
    with {pid, message} <- paused_to, do: send(pid, message)
    :ok
  end

  def pause_requested?(%__MODULE__{pause_flag: nil}), do: false
  def pause_requested?(%__MODULE__{pause_flag: pause_flag}), do: :atomics.get(pause_flag, 1) == 1

  def run_memory_changed(%__MODULE__{run_memory_to: run_memory_to}, snapshot) do
    with {pid, tag} <- run_memory_to, do: send(pid, {tag, snapshot})
    :ok
  end
end
