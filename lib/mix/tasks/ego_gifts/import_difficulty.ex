defmodule Mix.Tasks.EgoGifts.ImportDifficulty do
  @shortdoc "Set ego_gifts.hard_only / extreme_only from dante-planner.com"

  use Mix.Task

  @site "https://dante-planner.com"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    StarlightBot.Data.require_authoring!()
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    flags = fetch_flags()

    {matched, unmatched} =
      StarlightBot.BaseRepo.transaction(fn ->
        Enum.reduce(flags, {0, []}, fn {original_id, hard, extreme}, {matched, unmatched} ->
          %{num_rows: n} =
            Ecto.Adapters.SQL.query!(
              StarlightBot.BaseRepo,
              "UPDATE ego_gifts SET hard_only = ?, extreme_only = ? WHERE original_id = ?",
              [hard, extreme, original_id]
            )

          if n > 0, do: {matched + n, unmatched}, else: {matched, [original_id | unmatched]}
        end)
      end)
      |> elem(1)

    hard = Enum.count(flags, fn {_, h, _} -> h == 1 end)
    extreme = Enum.count(flags, fn {_, _, e} -> e == 1 end)

    Mix.shell().info(
      "dante-planner lists #{length(flags)} gifts (#{hard} hard only, #{extreme} extreme only); " <>
        "updated #{matched} row(s), #{length(unmatched)} dante-planner id(s) not in our db"
    )
  end

  defp fetch_flags do
    html = get!("#{@site}/ego-gift")
    [_, entry] = Regex.run(~r/<script[^>]+type="module"[^>]+src="(\/a\/[^"]+\.js)"/, html) || raise_shape("entry script")

    entry_js = get!(@site <> entry)

    [_, list_chunk] =
      Regex.run(~r/import\(`\.\/([^`]+\.js)`\)\.then\(\w+=>\w+\.\w+\)\.then\(\w+=>\w+\.EGO_GIFT_LIST/, entry_js) ||
        raise_shape("EGO_GIFT_LIST chunk")

    list_js = get!("#{@site}/a/#{list_chunk}")

    [_, spec_chunk] =
      Regex.run(~r/specImport:\(\)=>\w+\(\(\)=>import\(`\.\/([^`]+\.js)`\)/, list_js) ||
        raise_shape("spec chunk")

    spec_js = get!("#{@site}/a/#{spec_chunk}")

    [_, json] = Regex.run(~r/JSON\.parse\(`(.*)`\)/s, spec_js) || raise_shape("spec JSON")

    json
    |> Jason.decode!()
    |> Enum.map(fn {id, spec} ->
      {String.to_integer(id), flag(spec["hardOnly"]), flag(spec["extremeOnly"])}
    end)
  end

  defp flag(true), do: 1
  defp flag(_), do: 0

  defp raise_shape(what) do
    Mix.raise("dante-planner site layout changed: could not find #{what}")
  end

  defp get!(url) do
    request = {String.to_charlist(url), [{~c"user-agent", ~c"starlight-bot ego_gifts importer"}]}

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    case :httpc.request(:get, request, [ssl: ssl, timeout: 30_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} -> body
      other -> Mix.raise("GET #{url} failed: #{inspect(other)}")
    end
  end
end
