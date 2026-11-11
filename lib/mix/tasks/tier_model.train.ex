defmodule Mix.Tasks.TierModel.Train do
  use Mix.Task

  alias StarlightBot.Vision.TierModel.Trainer

  @lambdas [100.0, 300.0, 1000.0, 3000.0]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    Application.put_env(:starlight_bot, :start_hardware?, false)
    {:ok, _} = Application.ensure_all_started(:starlight_bot)
    {opts, _} = OptionParser.parse!(args, strict: [cv: :boolean, write: :boolean, lambda: :float])
    lambda = Keyword.get(opts, :lambda, Trainer.lambda())

    rows = Trainer.suite_rows()
    Mix.shell().info("#{length(rows)} labeled cells from #{rows |> Enum.map(& &1.id) |> Enum.uniq() |> length()} suite captures, lambda #{lambda}")
    Mix.shell().info("hand-tuned thresholds: #{Trainer.errors(rows, :rule)} tier errors")

    if opts[:cv] do
      for candidate <- Enum.uniq([lambda | @lambdas]) do
        Mix.shell().info("lambda #{candidate}: #{rows |> Trainer.cross_validate(candidate) |> Trainer.errors(:predicted)} tier errors held out by hour")
      end
    end

    if opts[:write] do
      path = rows |> Trainer.fit(lambda) |> Trainer.write_model()
      Mix.shell().info("wrote #{path}")
    end
  end
end
