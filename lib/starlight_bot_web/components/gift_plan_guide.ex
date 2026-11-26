defmodule StarlightBotWeb.Components.GiftPlanGuide do
  use Phoenix.Component
  import StarlightBotWeb.Components.Icon, only: [icon: 1]

  def gift_plan_guide(assigns) do
    ~H"""
      <section>
        <p>Define a list of gifts the bot should go for in the shop. The general idea is to set up a bunch of gifts you're interested in, set up some refresh conditions, and the bot will <span class="badge badge-sm align-middle whitespace-nowrap bg-base-300 border-base-content/20">work on getting gifts</span> <.icon name="lucide-arrow-right" class="size-3.5 inline-block align-middle" /> <span class="badge badge-sm align-middle whitespace-nowrap bg-base-300 border-base-content/20">refresh if possible</span> <.icon name="lucide-arrow-right" class="size-3.5 inline-block align-middle" /> <span class="badge badge-sm align-middle whitespace-nowrap bg-base-300 border-base-content/20">work on getting gifts</span> until it's out of refreshes. Each individual action in a run tries to do as much as possible, given the current shop's shelf and <span class="badge badge-sm align-middle whitespace-nowrap bg-base-300 border-base-content/20 gap-1">available cost<img src="/images/icons/md_cost.png" alt="" class="h-3.5 w-3.5 object-contain" /></span>.</p>
        <div class="mt-2 flex flex-col gap-2 text-xs">
          <svg viewBox="0 0 430 542" role="img" aria-label="Flowchart of one shop visit" class="w-full max-w-md self-center text-[11px]" style="fill: currentColor; stroke-width: 1.2">
            <defs>
              <marker id="gift-guide-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
                <path d="M0 0 L10 5 L0 10 z" style="fill: currentColor; stroke: none" />
              </marker>
            </defs>
            <g style="fill: none; stroke: currentColor" marker-end="url(#gift-guide-arrow)">
                <path d="M190 30 V44" />
                <path d="M190 74 V88" />
                <path d="M190 118 V132" />
                <path d="M190 162 V176" />
                <path d="M190 206 V220" />
                <path d="M190 250 V264" />
                <path d="M190 294 V308" />
                <path d="M190 338 V352" />
                <path d="M270 382 H300" />
                <path d="M190 412 V426" />
                <path d="M190 486 V512" />
                <path d="M110 456 H40 V59 H95" />
            </g>
            <rect x="95" y="4" width="190" height="26" rx="13" style="fill: var(--color-base-300); stroke: color-mix(in oklab, var(--color-base-content) 40%, transparent)" /><text x="190.0" y="21.0" text-anchor="middle">Enter shop</text>
            <rect x="95" y="44" width="190" height="30" rx="4" style="fill: var(--color-base-200); stroke: color-mix(in oklab, var(--color-base-content) 40%, transparent)" /><text x="190.0" y="63.0" text-anchor="middle">Sell</text>
            <rect x="95" y="88" width="190" height="30" rx="4" style="fill: var(--color-base-200); stroke: color-mix(in oklab, var(--color-base-content) 40%, transparent)" /><text x="190.0" y="107.0" text-anchor="middle">Heal, revive, team replace</text>
            <rect x="95" y="132" width="190" height="30" rx="4" style="fill: var(--color-base-200); stroke: color-mix(in oklab, var(--color-base-content) 40%, transparent)" /><text x="190.0" y="151.0" text-anchor="middle">Skill replace</text>
            <rect x="95" y="176" width="190" height="30" rx="4" style="fill: var(--color-base-200); stroke: color-mix(in oklab, var(--color-base-content) 40%, transparent)" /><text x="190.0" y="195.0" text-anchor="middle">Uptie</text>
            <rect x="95" y="220" width="190" height="30" rx="4" style="fill: var(--color-base-200); stroke: color-mix(in oklab, var(--color-base-content) 40%, transparent)" /><text x="190.0" y="239.0" text-anchor="middle">Buy</text>
            <rect x="95" y="264" width="190" height="30" rx="4" style="fill: var(--color-base-200); stroke: color-mix(in oklab, var(--color-base-content) 40%, transparent)" /><text x="190.0" y="283.0" text-anchor="middle">Fuse</text>
            <rect x="95" y="308" width="190" height="30" rx="4" style="fill: var(--color-base-200); stroke: color-mix(in oklab, var(--color-base-content) 40%, transparent)" /><text x="190.0" y="327.0" text-anchor="middle">Uptie again</text>
            <polygon points="190,352 270,382 190,412 110,382" style="fill: color-mix(in oklab, var(--color-primary) 15%, var(--color-base-200)); stroke: var(--color-primary)" /><text x="190" y="386" text-anchor="middle">Stage done?</text>
            <polygon points="190,426 270,456 190,486 110,456" style="fill: color-mix(in oklab, var(--color-primary) 15%, var(--color-base-200)); stroke: var(--color-primary)" /><text x="190" y="460" text-anchor="middle">Refresh case?</text>
            <rect x="300" y="366" width="110" height="32" rx="16" style="fill: var(--color-base-300); stroke: color-mix(in oklab, var(--color-base-content) 40%, transparent)" /><text x="355.0" y="386.0" text-anchor="middle">Next stage</text>
            <rect x="95" y="512" width="190" height="26" rx="13" style="fill: var(--color-base-300); stroke: color-mix(in oklab, var(--color-base-content) 40%, transparent)" /><text x="190.0" y="529.0" text-anchor="middle">Leave shop</text>
            <g style="font-size: 10px; opacity: 0.7">
              <text x="285" y="376" text-anchor="middle">yes</text>
              <text x="198" y="422">no</text>
              <text x="75" y="450" text-anchor="middle">refresh</text>
              <text x="198" y="504">leave, or no case</text>
              <text x="295" y="107">once per shop</text>
              <text x="355" y="416" text-anchor="middle">or leave shop</text>
              <text x="355" y="428" text-anchor="middle">after the last</text>
            </g>
          </svg>
        </div>
      </section>
      <section>
        <h1 class="mb-2">Shop actions</h1>
        <p class="mb-2">Actions are defined by adding the target gift to the list, and setting up what you want out of it.</p>
        <div class="flex flex-col gap-2 text-xs">
          <div class="flex items-center gap-2 rounded border border-base-content/20 bg-base-content/10 px-1 py-1 pointer-events-none w-fit">
            <img src="/images/ego_gifts/thumb/gift_55.webp" class="w-6 h-6 rounded object-cover shrink-0" draggable="false" />
            <span class="font-medium w-36 truncate">Thrill</span>
            <span class="join">
              <span class="btn btn-xs join-item btn-secondary">+</span>
              <span class="btn btn-xs join-item btn-outline">++</span>
            </span>
            <span class="btn btn-xs btn-secondary">Buy</span>
            <span class="join">
              <span class="btn btn-xs join-item btn-secondary">Fuse</span>
              <span class="btn btn-xs join-item btn-outline"><.icon name="lucide-settings" class="size-4" /></span>
            </span>
          </div>
          <div class="grid grid-cols-[3rem_1fr] items-baseline gap-x-2 gap-y-2">
            <span class="btn btn-xs btn-secondary pointer-events-none">Buy</span>
            <span>Buy on sight. Won't be sold or fused into a gift.</span>
            <span class="join pointer-events-none"><span class="btn btn-xs join-item btn-secondary">+</span><span class="btn btn-xs join-item btn-outline">++</span></span>
            <span>Uptie. Upgrades the gift once you own it, to + or ++.</span>
            <span class="btn btn-xs btn-secondary pointer-events-none">Fuse</span>
            <span>Fuse for this gift, buying ingredients if necessary. Some gifts need specific ingredients, others just need to combine the right tiers.</span>
          </div>
        </div>
      </section>
      <section>
        <div class="grid grid-cols-[14rem_1fr] items-center gap-2 text-xs">
          <div class="flex items-center gap-2 rounded border border-base-content/20 bg-base-content/10 px-1 py-1 pointer-events-none">
            <img src="/images/ego_gifts/thumb/gift_419.webp" class="w-6 h-6 rounded object-cover shrink-0" draggable="false" />
            <span class="font-medium flex-1 truncate">Bongy Plush</span>
            <span class="btn btn-xs btn-error">Sell</span>
          </div>
          <span>Sell this gift from your inventory before doing any buys/fusions/upties.</span>
        </div>
      </section>
      <section>
        <h1 class="font-semibold mb-2">Priority</h1>
        <p>The shopping list works from top to bottom if two entries use the same action (buy, uptie, etc.). In general this doesn't matter too much for most actions, but it will decide which fusion the bot goes for first.</p>
        <div class="grid grid-cols-[22rem_1fr] items-center gap-2 text-xs">
          <div class="flex flex-col gap-1 pointer-events-none">
            <div class="flex items-center gap-2 rounded border border-base-content/20 bg-base-content/10 px-1 py-1">
              <span class="flex w-24 shrink-0 items-center justify-between rounded border border-neutral bg-neutral px-1.5 py-0.5 text-[11px] text-neutral-content">Required<.icon name="lucide-chevron-down" class="size-3" /></span>
              <img src="/images/ego_gifts/thumb/gift_97.webp" class="w-6 h-6 rounded object-cover shrink-0" draggable="false" />
              <span class="font-medium flex-1 truncate">Clear Mirror, Calm Water</span>
              <span class="btn btn-xs btn-secondary">Fuse</span>
            </div>
            <div class="flex items-center gap-2 rounded border border-base-content/20 bg-base-content/10 px-1 py-1">
              <span class="flex w-24 shrink-0 items-center justify-between rounded border border-neutral bg-neutral px-1.5 py-0.5 text-[11px] text-neutral-content">Required<.icon name="lucide-chevron-down" class="size-3" /></span>
              <img src="/images/ego_gifts/thumb/gift_126.webp" class="w-6 h-6 rounded object-cover shrink-0" draggable="false" />
              <span class="font-medium flex-1 truncate">Fragment of Decay</span>
              <span class="btn btn-xs btn-secondary">Fuse</span>
            </div>
          </div>
          <span>Fuse for Clear Mirror, Calm Water first. Fragment of Decay will not be fused for until we've finished the fusions preceding it.</span>
        </div>
      </section>
      <section>
        <h4 class="font-semibold mb-2">Required, Optional and Goals</h4>
        <p class="mb-2">Each entry has a dropdown on the left that decides how much the stage cares about it.</p>
        <div class="flex flex-col gap-2 text-xs">
          <div class="flex items-center gap-1 flex-wrap">
            <div class="rounded-lg border border-base-content/20 bg-base-content/10 px-2 py-1 flex flex-col justify-center">
              <span class="text-[11px] font-semibold">Required</span>
              <span class="text-[10px] text-base-content/50">all of 1</span>
            </div>
            <div class="rounded-lg border border-sky-500/50 bg-sky-500/15 px-2 py-1 flex items-center gap-1">
              <span class="text-[11px] font-semibold">A:</span>
              <span class="text-[11px]">at least 1 of 2</span>
            </div>
            <span class="text-base-content/60">Stage header: what must be owned to move on</span>
          </div>
          <div class="grid grid-cols-[22rem_1fr] items-center gap-2">
            <div class="flex items-center gap-2 rounded border border-base-content/20 bg-base-content/10 px-1 py-1 pointer-events-none">
              <span class="flex w-24 shrink-0 items-center justify-between rounded border border-neutral bg-neutral px-1.5 py-0.5 text-[11px] text-neutral-content">Required<.icon name="lucide-chevron-down" class="size-3" /></span>
              <img src="/images/ego_gifts/thumb/gift_13.webp" class="w-6 h-6 rounded object-cover shrink-0" draggable="false" />
              <span class="truncate font-medium flex-1">Glimpse of Flames</span>
              <span class="join">
                <span class="btn btn-xs join-item btn-secondary">Buy</span>
                <span class="btn btn-xs join-item btn-outline">Sell</span>
              </span>
            </div>
            <span><span class="font-semibold">Required.</span> The stage is not done until you own it.</span>
          </div>
          <div class="grid grid-cols-[22rem_1fr] items-center gap-2">
            <div class="flex items-center gap-2 rounded border border-base-content/10 bg-base-300 px-1 py-1 pointer-events-none" style="background-image: radial-gradient(color-mix(in oklab, var(--color-base-content) 16%, transparent) 0.9px, transparent 1.2px), radial-gradient(color-mix(in oklab, var(--color-base-content) 16%, transparent) 0.9px, transparent 1.2px); background-size: 8px 8px; background-position: -2px -2px, 2px 2px; background-clip: padding-box">
              <span class="flex w-24 shrink-0 items-center justify-between rounded border border-base-300 bg-base-100 px-1.5 py-0.5 text-[11px]">Optional<.icon name="lucide-chevron-down" class="size-3" /></span>
              <img src="/images/ego_gifts/thumb/gift_104.webp" class="w-6 h-6 rounded object-cover shrink-0" draggable="false" />
              <span class="truncate font-medium flex-1">Ardent Flower</span>
              <span class="join">
                <span class="btn btn-xs join-item btn-secondary">Buy</span>
                <span class="btn btn-xs join-item btn-outline">Sell</span>
              </span>
            </div>
            <span><span class="font-semibold">Optional.</span> Progress continues with or without this, but simply having it listed as optional makes the bot refuse to sell or fuse with it. Buy on an optional will buy on sight, just like a required buy.</span>
          </div>
          <div class="grid grid-cols-[22rem_1fr] gap-2">
            <div class="flex flex-col gap-1">
              <div class="flex items-center gap-2 rounded border border-sky-500/50 bg-sky-500/15 px-1 py-1 pointer-events-none">
                <span class="flex w-24 shrink-0 items-center justify-between rounded border border-sky-700 bg-sky-600 px-1.5 py-0.5 text-[11px] text-white">Goal A<.icon name="lucide-chevron-down" class="size-3" /></span>
                <img src="/images/ego_gifts/thumb/gift_313.webp" class="w-6 h-6 rounded object-cover shrink-0" draggable="false" />
                <span class="truncate font-medium flex-1">Embers</span>
                <span class="join">
                  <span class="btn btn-xs join-item btn-secondary">Buy</span>
                  <span class="btn btn-xs join-item btn-outline">Sell</span>
                </span>
              </div>
              <div class="flex items-center gap-2 rounded border border-sky-500/50 bg-sky-500/15 px-1 py-1 pointer-events-none">
                <span class="flex w-24 shrink-0 items-center justify-between rounded border border-sky-700 bg-sky-600 px-1.5 py-0.5 text-[11px] text-white">Goal A<.icon name="lucide-chevron-down" class="size-3" /></span>
                <img src="/images/ego_gifts/thumb/gift_92.webp" class="w-6 h-6 rounded object-cover shrink-0" draggable="false" />
                <span class="truncate font-medium flex-1">Charred Disk</span>
                <span class="join">
                  <span class="btn btn-xs join-item btn-secondary">Buy</span>
                  <span class="btn btn-xs join-item btn-outline">Sell</span>
                </span>
              </div>
            </div>
            <span class="self-center"><span class="font-semibold">Goal.</span> Entries sharing a letter count as a group, and the stage needs at least N of them (here 1 of 2). Whichever the bot finds first counts, and it stops chasing the rest once N are owned.</span>
          </div>
        </div>
      </section>
      <section>
        <h4 class="font-semibold mb-1">Refresh</h4>
        <p>After doing work in the shop, we try to refresh. The first case whose condition is true runs: Refresh, Keyword (refresh to a chosen affinity), or Leave. With no matching case the bot leaves the shop. Cases apply to every stage.</p>
        <div class="mt-2 flex flex-col gap-1 text-xs">
          <div class="rounded border border-base-300 bg-base-200 px-1 py-1 flex items-center gap-2 pointer-events-none">
            <span class="text-base-content/40 select-none px-1">⠿</span>
            <span class="text-[11px] font-semibold text-base-content/70 w-12 shrink-0">if</span>
            <span class="btn btn-outline btn-xs bg-base-100 h-6 min-h-6 flex-1 justify-start font-normal normal-case"><span class="text-base-content/50">▸</span>on Stage 1</span>
            <span class="text-[11px] font-semibold text-base-content/70">then</span>
            <span class="join">
              <span class="join-item btn btn-xs">Leave</span>
              <span class="join-item btn btn-xs btn-primary">Refresh</span>
              <span class="join-item btn btn-xs">Keyword</span>
            </span>
            <span class="text-[11px] font-semibold text-base-content/70">up to</span>
            <span class="input input-bordered input-xs w-14 items-center text-base-content/50">∞</span>
            <span class="text-[11px] font-semibold text-base-content/70 whitespace-nowrap">cost after &gt;=</span>
            <span class="input input-bordered input-xs w-16 items-center">250</span>
          </div>
          <div class="rounded border border-dashed border-base-300 px-1 py-1 flex items-center gap-2 pointer-events-none">
            <span class="px-1 invisible">⠿</span>
            <span class="text-[11px] font-semibold text-base-content/70 w-12 shrink-0">else</span>
            <span class="text-[11px] text-base-content/60">leave the shop</span>
          </div>
          <span class="text-base-content/60">While the bot is on Stage 1 it refreshes, as many times as it can afford while keeping at least 250 left. Anywhere else no case matches, so it leaves the shop.</span>
        </div>
      </section>
      <section>
        <h4 class="font-semibold mb-1">Schedules</h4>
        <p>Entry settings can change by floor. Use <span class="badge badge-sm align-middle whitespace-nowrap bg-base-300 border-base-content/20">Add Schedule</span> to customize a gift's action and goal settings per floor.</p>
        <div class="mt-2 flex flex-col gap-3 text-xs">
          <div class="grid grid-cols-[22rem_1fr] items-center gap-2">
            <div class="flex flex-col pointer-events-none">
              <div class="flex items-end gap-0.5"><div class="flex items-center gap-0.5 rounded-t-lg border border-b-0 px-2 py-0.5 text-[11px] border-primary bg-primary text-primary-content font-semibold">F1-2<.icon name="lucide-chevron-down" class="size-3" /></div><div class="flex items-center gap-0.5 rounded-t-lg border border-b-0 px-2 py-0.5 text-[11px] border-primary/40 bg-primary/25">F3-4<.icon name="lucide-chevron-down" class="size-3" /></div><div class="flex items-center gap-0.5 rounded-t-lg border border-b-0 px-2 py-0.5 text-[11px] border-primary/40 bg-primary/25">F5+<.icon name="lucide-chevron-down" class="size-3" /></div><div class="rounded-t-lg border border-b-0 border-dashed border-primary/60 px-2 py-0.5 text-[11px] text-primary">+</div></div>
              <div class="p-1 border-2 border-primary rounded-b-lg rounded-tr-lg">
              <div class="flex items-center gap-2 rounded border border-base-content/20 bg-base-content/10 px-1 py-1">
                <span class="flex w-24 shrink-0 items-center justify-between rounded border border-neutral bg-neutral px-1.5 py-0.5 text-[11px] text-neutral-content">Required<.icon name="lucide-chevron-down" class="size-3" /></span>
                <img src="/images/ego_gifts/thumb/gift_81.webp" class="w-6 h-6 rounded object-cover shrink-0" draggable="false" />
                <span class="font-medium w-24 truncate">Grand Welcome</span>
                <span class="join">
                  <span class="btn btn-xs join-item btn-secondary">Buy</span>
                  <span class="btn btn-xs join-item btn-outline">Sell</span>
                </span>
              </div>
              </div>
            </div>
            <span><span class="font-semibold">F1-2.</span> Buy it on the first two floors.</span>
          </div>
          <div class="grid grid-cols-[22rem_1fr] items-center gap-2">
            <div class="flex flex-col pointer-events-none">
              <div class="flex items-end gap-0.5"><div class="flex items-center gap-0.5 rounded-t-lg border border-b-0 px-2 py-0.5 text-[11px] border-primary/40 bg-primary/25">F1-2<.icon name="lucide-chevron-down" class="size-3" /></div><div class="flex items-center gap-0.5 rounded-t-lg border border-b-0 px-2 py-0.5 text-[11px] border-primary bg-primary text-primary-content font-semibold">F3-4<.icon name="lucide-chevron-down" class="size-3" /></div><div class="flex items-center gap-0.5 rounded-t-lg border border-b-0 px-2 py-0.5 text-[11px] border-primary/40 bg-primary/25">F5+<.icon name="lucide-chevron-down" class="size-3" /></div><div class="rounded-t-lg border border-b-0 border-dashed border-primary/60 px-2 py-0.5 text-[11px] text-primary">+</div></div>
              <div class="p-1 border-2 border-primary rounded-b-lg rounded-tr-lg">
              <div class="flex items-center gap-2 rounded border border-base-content/20 bg-base-content/10 px-1 py-1">
                <span class="flex w-24 shrink-0 items-center justify-between rounded border border-base-300 bg-base-100 px-1.5 py-0.5 text-[11px] text-base-content">Optional<.icon name="lucide-chevron-down" class="size-3" /></span>
                <img src="/images/ego_gifts/thumb/gift_81.webp" class="w-6 h-6 rounded object-cover shrink-0" draggable="false" />
                <span class="font-medium w-24 truncate">Grand Welcome</span>
                <span class="join">
                  <span class="btn btn-xs join-item btn-outline">Buy</span>
                  <span class="btn btn-xs join-item btn-outline">Sell</span>
                </span>
              </div>
              </div>
            </div>
            <span><span class="font-semibold">F3-4.</span> Buy is off, so the bot stops requiring it here but keeps what it has.</span>
          </div>
          <div class="grid grid-cols-[22rem_1fr] items-center gap-2">
            <div class="flex flex-col pointer-events-none">
              <div class="flex items-end gap-0.5"><div class="flex items-center gap-0.5 rounded-t-lg border border-b-0 px-2 py-0.5 text-[11px] border-primary/40 bg-primary/25">F1-2<.icon name="lucide-chevron-down" class="size-3" /></div><div class="flex items-center gap-0.5 rounded-t-lg border border-b-0 px-2 py-0.5 text-[11px] border-primary/40 bg-primary/25">F3-4<.icon name="lucide-chevron-down" class="size-3" /></div><div class="flex items-center gap-0.5 rounded-t-lg border border-b-0 px-2 py-0.5 text-[11px] border-primary bg-primary text-primary-content font-semibold">F5+<.icon name="lucide-chevron-down" class="size-3" /></div><div class="rounded-t-lg border border-b-0 border-dashed border-primary/60 px-2 py-0.5 text-[11px] text-primary">+</div></div>
              <div class="p-1 border-2 border-primary rounded-b-lg rounded-tr-lg">
              <div class="flex items-center gap-2 rounded border border-base-300 bg-base-100 px-1 py-1" style="background-image: repeating-linear-gradient(135deg, color-mix(in oklab, var(--color-base-content) 14%, transparent) 0 4px, transparent 4px 10px)">
                <span class="flex w-24 shrink-0 items-center justify-between rounded border border-base-300 bg-base-100 px-1.5 py-0.5 text-[11px] text-base-content">Abandon<.icon name="lucide-chevron-down" class="size-3" /></span>
                <img src="/images/ego_gifts/thumb/gift_81.webp" class="w-6 h-6 rounded object-cover shrink-0" draggable="false" />
                <span class="font-medium w-24 truncate">Grand Welcome</span>
              </div>
              </div>
            </div>
            <span><span class="font-semibold">F5+.</span> Abandoned from floor 5, so the bot no longer cares about it. Can be sold or used for fusion fodder.</span>
          </div>
        </div>
      </section>
      <section>
        <h4 class="font-semibold mb-1">Stages</h4>
        <p>The bot finishes everything in the first stage, then moves to the next. Gifts already kept stay kept, and a gift can appear in several stages, with the later stage's settings applying once the earlier one is done. Any-tier or any-affinity entries don't carry over, while optional gifts do.</p>
        <div class="mt-2 flex flex-col gap-1 text-xs">
          <div class="grid grid-cols-[22rem_1fr] items-center gap-2">
            <div class="flex flex-col gap-1 rounded-xl border border-dashed border-base-content/30 p-1.5 pointer-events-none">
              <div class="flex items-stretch gap-2 rounded-xl border border-base-300 bg-base-200/60 p-1">
                <span class="self-center px-1 text-sm font-semibold">Stage 1</span>
                <div class="rounded-lg border border-base-content/20 bg-base-content/10 px-2 py-1 flex flex-col justify-center">
                  <span class="text-[11px] font-semibold">Required</span>
                  <span class="text-[10px] text-base-content/50">all of 1</span>
                </div>
              </div>
              <div class="flex items-center gap-2 rounded border border-base-content/20 bg-base-content/10 px-1 py-1 ml-2">
                <span class="flex w-24 shrink-0 items-center justify-between rounded border border-neutral bg-neutral px-1.5 py-0.5 text-[11px] text-neutral-content">Required<.icon name="lucide-chevron-down" class="size-3" /></span>
                <img src="/images/ego_gifts/thumb/gift_13.webp" class="w-6 h-6 rounded object-cover shrink-0" draggable="false" />
                <span class="truncate font-medium flex-1">Glimpse of Flames</span>
                <span class="btn btn-xs btn-secondary">Buy</span>
              </div>
            </div>
            <span>Worked on first. The bot shops and refreshes until its Required entries and goals are owned.</span>
          </div>
          <div class="flex items-center gap-1 pl-2 text-base-content/60"><.icon name="lucide-arrow-down" class="size-3.5" />once Stage 1 is done</div>
          <div class="grid grid-cols-[22rem_1fr] items-center gap-2">
            <div class="flex flex-col gap-1 rounded-xl border border-dashed border-base-content/30 p-1.5 pointer-events-none">
              <div class="flex items-stretch gap-2 rounded-xl border border-base-300 bg-base-200/60 p-1">
                <span class="self-center px-1 text-sm font-semibold">Stage 2</span>
                <div class="rounded-lg border border-base-content/20 bg-base-content/10 px-2 py-1 flex flex-col justify-center">
                  <span class="text-[11px] font-semibold">Required</span>
                  <span class="text-[10px] text-base-content/50">all of 1</span>
                </div>
              </div>
              <div class="flex items-center gap-2 rounded border border-base-content/20 bg-base-content/10 px-1 py-1 ml-2">
                <span class="flex w-24 shrink-0 items-center justify-between rounded border border-neutral bg-neutral px-1.5 py-0.5 text-[11px] text-neutral-content">Required<.icon name="lucide-chevron-down" class="size-3" /></span>
                <img src="/images/ego_gifts/thumb/gift_55.webp" class="w-6 h-6 rounded object-cover shrink-0" draggable="false" />
                <span class="truncate font-medium flex-1">Thrill</span>
                <span class="btn btn-xs btn-secondary">Buy</span>
              </div>
            </div>
            <span>Worked on next. Everything kept in Stage 1 stays kept.</span>
          </div>
          <div class="flex gap-2 pointer-events-none">
            <span class="btn btn-xs btn-outline">+ Add stage</span>
            <span class="btn btn-xs btn-outline">+ Keep shopping</span>
          </div>
        </div>
        <p class="mt-1">Stages are useful if you completely want to change priorities once a set of gifts have been acquired, but if you need more granularity (for example, you only want to prioritize 1 more gift after certain conditions are met) it's recommended to use schedules instead. Schedules allow conditionals along with their floor settings, so it's possible to say "Once this gift is owned pursue this other gift". This is a useful to ensure order while letting the bot still care about things outside the schedule.</p>
      </section>
    """
  end
end
