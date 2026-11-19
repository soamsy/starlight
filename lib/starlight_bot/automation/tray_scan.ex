defmodule StarlightBot.Automation.TrayScan do
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.{BattlePlans, Ctx, SinnerProfiles}
  alias StarlightBot.Vision.{SinnerLocator, SkillTray}

  defstruct frame: nil, candidates: [], claims: [], defense: nil

  @type wanted :: %{sinners: [String.t()], defense: nil | :all | [String.t()]}

  @spec wanted([map], keyword) :: wanted
  def wanted(holders, opts \\ []) do
    chain = Enum.flat_map(holders, &BattlePlans.holders/1)

    %{
      sinners: chain |> Enum.reject(&(&1["who"] == "everyone")) |> Enum.flat_map(&(&1["sinners"] || [])) |> Enum.uniq(),
      defense: Enum.reduce(holders, if(Keyword.get(opts, :defense?, false), do: :all), &BattlePlans.merge_defense_need(BattlePlans.defense_need(&1), &2))
    }
  end

  @spec sinners_wanted([String.t()]) :: wanted
  def sinners_wanted(sinners), do: %{sinners: Enum.uniq(sinners), defense: nil}

  @spec candidates(wanted, [map], %{String.t() => [integer]}) :: [map]
  def candidates(%{defense: :all}, all, _planned), do: with_hooks(all)

  def candidates(%{sinners: sinners, defense: defense}, all, planned) do
    by_sinner = Enum.group_by(all, & &1.sinner)

    (sinners ++ List.wrap(defense))
    |> Enum.uniq()
    |> Enum.flat_map(fn sinner ->
      profiles = Map.get(by_sinner, sinner, [])

      case Enum.filter(profiles, &(&1.id in Map.get(planned, sinner, []))) do
        [] -> profiles
        subset -> subset
      end
    end)
    |> with_hooks()
  end

  defp with_hooks(profiles) do
    profiles |> Enum.filter(&(SinnerProfiles.locator_hooks(&1) != [])) |> Enum.uniq_by(& &1.id)
  end

  @spec build(wanted, term, SkillTray.t(), Ctx.t()) :: %__MODULE__{}
  def build(wanted, frame, %SkillTray{} = tray, ctx) do
    candidates = candidates(wanted, SinnerProfiles.list(), BattlePlans.profiles(RunMemory.battle_plan(ctx)))
    claims = if candidates == [], do: [], else: scan(frame, tray, candidates, wanted, ctx)
    defense = if wanted.defense, do: defense_sins(claims, tray)
    log_defense(wanted, claims, ctx)
    scan = %__MODULE__{frame: frame, candidates: candidates, claims: claims, defense: defense}
    report_misses(scan, wanted.sinners, ctx)
    scan
  end

  defp report_misses(scan, sinners, ctx) do
    missing = Enum.filter(sinners, &is_nil(claim(scan, &1)))

    for sinner <- missing do
      case hooks_for(scan, sinner) do
        [] ->
          Ctx.log(ctx, :error, "playbook: #{SinnerProfiles.label(sinner)} has no sinner profile with a locator hook")

        hooks ->
          Ctx.log(ctx, :info, "playbook: #{SinnerProfiles.label(sinner)} not found in the skill tray (scanned #{length(hooks)} hook(s))")
      end
    end

    if Enum.any?(missing, &(hooks_for(scan, &1) != [])), do: save_miss_frame(scan.frame, missing, ctx)
  end

  defp save_miss_frame(frame, sinners, ctx) do
    if Application.get_env(:starlight_bot, :save_timeout_frames, false) do
      stamp = NaiveDateTime.local_now() |> NaiveDateTime.to_string() |> String.replace([" ", ":", "."], "_")
      dir = Path.join(StarlightBot.Data.log_dir(), "timeouts")
      File.mkdir_p!(dir)
      path = Path.expand(Path.join(dir, "#{stamp}_tray_miss_#{Enum.join(sinners, "_")}.png"))
      Evision.imwrite(path, frame.mat)
      Ctx.log(ctx, :info, "saved the screen at the tray miss to #{path}")
    end
  end

  defp scan(frame, tray, candidates, wanted, ctx) do
    reason = if wanted.defense == :all, do: "every sinner profile (defense needed)", else: "sinner(s) #{Enum.map_join(Enum.uniq(wanted.sinners ++ List.wrap(wanted.defense)), ", ", &SinnerProfiles.label/1)}"
    hooks = candidates |> Enum.flat_map(&SinnerProfiles.locator_hooks/1) |> Enum.uniq() |> length()
    Ctx.log(ctx, :info, "playbook: scanning the skill tray for #{reason}, #{length(candidates)} profile(s), #{hooks} hook(s)")
    claims = SinnerLocator.locate(frame, tray, candidates)

    for claim <- claims do
      defense = if claim.profile.defense_affinity in SinnerProfiles.sins(), do: ", defense is #{claim.profile.defense_affinity}", else: ""
      Ctx.log(ctx, :info, "playbook: #{claim.profile.name} (#{claim.hook}, confidence #{:erlang.float_to_binary(claim.score * 1.0, decimals: 3)}) found at slot #{claim.column + 1}#{defense}")
    end

    claims
  end

  defp log_defense(%{defense: defense}, [], ctx) when not is_nil(defense), do: Ctx.log(ctx, :info, "playbook: no sinner profiles found in the skill tray, no defense skills available")
  defp log_defense(_wanted, _claims, _ctx), do: :ok

  defp defense_sins(claims, tray) do
    Enum.reduce(claims, List.duplicate(nil, length(tray.sinner_of_slot)), fn claim, acc ->
      if claim.profile.defense_affinity in SinnerProfiles.sins() do
        sin = String.to_existing_atom(claim.profile.defense_affinity)
        Enum.reduce(claim.columns, acc, &List.replace_at(&2, &1, sin))
      else
        acc
      end
    end)
  end

  @spec claim(%__MODULE__{}, String.t()) :: map | nil
  def claim(%__MODULE__{claims: claims}, sinner) do
    claims |> Enum.filter(&(&1.profile.sinner == sinner)) |> Enum.max_by(& &1.score, fn -> nil end)
  end

  @spec hooks_for(%__MODULE__{}, String.t()) :: [String.t()]
  def hooks_for(%__MODULE__{candidates: candidates}, sinner) do
    candidates |> Enum.filter(&(&1.sinner == sinner)) |> Enum.flat_map(&SinnerProfiles.locator_hooks/1) |> Enum.uniq()
  end
end
