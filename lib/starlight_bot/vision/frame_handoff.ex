defmodule StarlightBot.Vision.FrameHandoff do
  @key {__MODULE__, :mat}

  def put(mat), do: :persistent_term.put(@key, mat)

  def take do
    mat = :persistent_term.get(@key, nil)
    if mat, do: :persistent_term.erase(@key)
    mat
  end
end
