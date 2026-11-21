defmodule StarlightBotWeb.Components.BattlePlanGuide do
  use Phoenix.Component

  def battle_plan_guide(assigns) do
    ~H"""
      <section>
        <h4 class="font-semibold mb-1">Three parts</h4>
        <p><span class="font-medium">Lineups</span> choose which sinners fight and in what order. <span class="font-medium">Playbooks</span> choose what the bot does each turn. Both are painted onto a floor grid, so different floors and fights can use different ones.</p>
      </section>
      <section>
        <h4 class="font-semibold mb-1">Lineups</h4>
        <ul class="list-disc pl-5 flex flex-col gap-1">
          <li>Click sinners to add them in order. The first 7 are the front line (red), the rest are backups (blue).</li>
          <li>Pick a profile under each sinner so playbook checks for that sinner can run. Without one, those checks are skipped.</li>
          <li>The grid has a row per venue: MD Battle, MD Boss and Lux. Select a lineup, then click a floor to start it there. It carries on to later floors until the next change point. Cells marked <span class="font-mono text-warning">?</span> have no lineup yet.</li>
          <li>Until every venue has a lineup the bot leaves the in-game sinner order alone.</li>
        </ul>
      </section>
      <section>
        <h4 class="font-semibold mb-1">Playbooks</h4>
        <p>A <span class="font-medium">chain</span> playbook handles chain battles and a <span class="font-medium">focused</span> playbook handles focused battles with a single target. Each has its own set of actions.</p>
        <ul class="mt-1 list-disc pl-5 flex flex-col gap-1">
          <li>Select a playbook in the list, then click cells in the track grid to start it there. Tracks are normal, hard and Lux, each split into chain and focused. It runs until the next change point on that track.</li>
          <li>Right click a cell, or use the eraser, to remove a change point. Drag the handle to reorder playbooks.</li>
          <li><span class="font-medium">Floors 6-15</span> is collapsed into one column. Tick floors 6-15 at the top to paint them individually.</li>
          <li>Copy and Paste move a playbook through the clipboard as JSON. Duplicate makes a copy in place.</li>
          <li>Click an action to select it, shift or ctrl click to select more. Drag moves the whole selection, Ctrl+C copies it and Ctrl+V pastes after the last selected action. Chain actions and schedules that don't fit the target are skipped.</li>
        </ul>
      </section>
      <section>
        <h4 class="font-semibold mb-1">Actions</h4>
        <p>Actions run top to bottom and each one handles its slots, so later rows only see what is left. Hover an action name for what it does. <span class="font-medium">If</span> checks a condition once against a fresh frame and runs its then or else actions. <span class="font-medium">Remaining skills</span> at the bottom covers every slot nothing above captured.</p>
      </section>
      <section>
        <h4 class="font-semibold mb-1">Retries</h4>
        <p>Retries per battle is how many times a lost battle is retried before the run gives up. The Retry battle action respects it.</p>
      </section>
    """
  end
end
