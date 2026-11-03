defmodule Mix.Tasks.EnemyTargets.Train do
  use Mix.Task

  alias StarlightBot.Vision.EnemyTargets.Trainer

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:evision)
    {opts, _} = OptionParser.parse!(args, strict: [cv: :boolean, write: :boolean, lambda: :float])
    lambda = Keyword.get(opts, :lambda, Trainer.lambda())

    frames = Trainer.suite_frames()
    Mix.shell().info("#{length(frames)} labeled enemy captures, #{frames |> Enum.map(&length(&1.rects)) |> Enum.sum()} targets, lambda #{lambda}")

    if opts[:cv], do: report(Trainer.cross_validate(frames, lambda))

    if opts[:write] do
      path = frames |> Trainer.fit(lambda) |> Trainer.write_model()
      Mix.shell().info("wrote #{path}")
    end
  end

  defp report(rows) do
    rows
    |> Enum.group_by(& &1.threshold)
    |> Enum.sort()
    |> Enum.each(fn {threshold, group} ->
      perfect = Enum.count(group, & &1.ok?)
      missed = group |> Enum.map(& &1.missed) |> Enum.sum()
      extra = group |> Enum.map(& &1.extra) |> Enum.sum()
      Mix.shell().info("threshold #{threshold}: #{perfect}/#{length(group)} captures perfect, #{missed} missed, #{extra} extra")
    end)
  end
end
