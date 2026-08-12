defmodule StarlightBot.Navigation.DSL do
  defmacro __using__(_) do
    quote do
      import StarlightBot.Navigation.DSL
      Module.register_attribute(__MODULE__, :nav_screens, accumulate: true)
      Module.register_attribute(__MODULE__, :nav_transitions, accumulate: true)
      Module.register_attribute(__MODULE__, :nav_actions, accumulate: true)
      Module.register_attribute(__MODULE__, :current_screen_name, [])
      Module.register_attribute(__MODULE__, :current_transition_to, [])
      @before_compile StarlightBot.Navigation.DSL
    end
  end

  defmacro screen(name, opts, do: body) do
    identity = Keyword.fetch!(opts, :identity)
    refines = Keyword.get(opts, :refines)
    catch_all = Keyword.get(opts, :catch_all, false)

    quote do
      @current_screen_name unquote(name)
      @nav_screens {unquote(name), unquote(identity), unquote(refines), unquote(catch_all)}
      unquote(body)
    end
  end

  defmacro screen(name, do: body) do
    raise ArgumentError,
          "screen #{inspect(name)} requires `identity: hook_atom` option"
    _ = body
  end

  defmacro screen(name, opts) when is_list(opts) do
    identity = Keyword.fetch!(opts, :identity)
    refines = Keyword.get(opts, :refines)
    catch_all = Keyword.get(opts, :catch_all, false)

    quote do
      @current_screen_name unquote(name)
      @nav_screens {unquote(name), unquote(identity), unquote(refines), unquote(catch_all)}
    end
  end

  defmacro transition(opts, do: body) do
    to = Keyword.fetch!(opts, :to)
    name = Keyword.get(opts, :name, to)
    fun_name = :"__nav_transition_steps_#{:erlang.unique_integer([:positive, :monotonic])}__"

    quote do
      @current_transition_to unquote(to)
      defp unquote(fun_name)(), do: unquote(body)
      @nav_transitions {@current_screen_name, unquote(to), unquote(name), unquote(fun_name)}
    end
  end

  defmacro transition(opts) when is_list(opts) do
    {body, rest} = Keyword.pop(opts, :do)
    to = Keyword.fetch!(rest, :to)
    name = Keyword.get(rest, :name, to)
    fun_name = :"__nav_transition_steps_#{:erlang.unique_integer([:positive, :monotonic])}__"

    quote do
      @current_transition_to unquote(to)
      defp unquote(fun_name)(), do: unquote(body)
      @nav_transitions {@current_screen_name, unquote(to), unquote(name), unquote(fun_name)}
    end
  end

  defmacro action(name, do: body) do
    fun_name = :"__nav_action_steps_#{:erlang.unique_integer([:positive, :monotonic])}__"

    quote do
      defp unquote(fun_name)(), do: unquote(body)
      @nav_actions {@current_screen_name, unquote(name), unquote(fun_name)}
    end
  end

  @default_scroll_clicks 3

  def click(hook) when is_atom(hook), do: {:click, hook}

  def move_to(hook) when is_atom(hook), do: {:move_to, hook}

  def drag(hook, dx, dy, duration_ms \\ nil)
      when is_atom(hook) and is_number(dx) and is_number(dy) do
    {:drag, hook, dx, dy, duration_ms}
  end

  def scroll_down(clicks \\ @default_scroll_clicks) when is_number(clicks) do
    {:scroll, 0, clicks}
  end

  def scroll_up(clicks \\ @default_scroll_clicks) when is_number(clicks) do
    {:scroll, 0, -clicks}
  end

  def key(key) when is_atom(key), do: {:key, key}

  def type(text) when is_binary(text), do: {:type, text}

  def custom(fun) when is_function(fun, 2), do: {:custom, fun}

  def await(hook, opts \\ []) when is_atom(hook) or is_list(hook) or is_tuple(hook) do
    {:await, hook, Keyword.get(opts, :timeout, 5_000)}
  end

  def await_any(hooks, opts \\ []) when is_list(hooks) do
    {:await_any, hooks, Keyword.get(opts, :timeout, 5_000)}
  end

  def branch(clauses) when is_list(clauses) do
    {default, checks} = Keyword.pop(clauses, :default, [])
    {:branch, checks, default}
  end

  def sleep(ms) when is_integer(ms), do: {:sleep, ms}

  def not_hook(hook), do: {:not, hook}

  def await_then_gone(hook, opts \\ [])
      when is_atom(hook) or is_list(hook) or is_tuple(hook) do
    appear_timeout = Keyword.get(opts, :appear_timeout, 5_000)
    gone_timeout = Keyword.get(opts, :gone_timeout, 30_000)

    [
      await(hook, timeout: appear_timeout),
      await(not_hook(hook), timeout: gone_timeout)
    ]
  end

  def loading(opts \\ []) do
    opts = Keyword.merge([appear_timeout: 10_000, gone_timeout: 20_000], opts)
    await_then_gone(:loading_stage_1, opts) ++ await_then_gone(:loading_stage_2, opts) ++ [sleep(1000)] # TODO: make transitions work fine even if they have to wait for their hook to appear for a bit. Alternatively, make them re-localize on exponential backoff before claiming the navigation failed
  end

  def retry_until(hook, steps, opts \\ [])
      when (is_atom(hook) or is_list(hook) or is_tuple(hook)) and is_list(steps) do
    timeout_ms = Keyword.get(opts, :timeout, 5_000)
    every_ms = Keyword.get(opts, :every, 500)
    tries = Keyword.get(opts, :tries)
    {:retry_until, hook, steps, timeout_ms, every_ms, tries}
  end

  def wait_until(hook, opts \\ [])
      when is_atom(hook) or is_list(hook) or is_tuple(hook) do
    retry_until(hook, [], opts)
  end

  def reclick_until_gone(hook, opts \\ [])
      when is_atom(hook) or is_list(hook) or is_tuple(hook) do
    retry_until(not_hook(hook), [click(hook)], opts)
  end

  defmacro retry_until_arrived(steps, opts \\ []) do
    quote do
      case StarlightBot.Navigation.Catalog.find_screen(@current_transition_to) do
        %StarlightBot.Navigation.Screen{identity_hook: hook} when not is_nil(hook) ->
          StarlightBot.Navigation.DSL.retry_until(hook, unquote(steps), unquote(opts))

        _ ->
          raise ArgumentError,
                "retry_until_arrived: transition target #{inspect(@current_transition_to)} " <>
                  "has no identity hook to retry against"
      end
    end
  end

  defmacro reclick_until_arrived(hook, opts \\ []) do
    quote do
      StarlightBot.Navigation.DSL.retry_until_arrived(
        [StarlightBot.Navigation.DSL.click(unquote(hook))],
        unquote(opts)
      )
    end
  end

  defmacro repress_until_arrived(key, opts \\ []) do
    quote do
      StarlightBot.Navigation.DSL.retry_until_arrived(
        [StarlightBot.Navigation.DSL.key(unquote(key))],
        unquote(opts)
      )
    end
  end

  defmacro wait_until_arrived(opts \\ []) do
    quote do
      StarlightBot.Navigation.DSL.retry_until_arrived([], unquote(opts))
    end
  end

  defmacro __before_compile__(env) do
    raw_screens = Module.get_attribute(env.module, :nav_screens) |> Enum.reverse()
    raw_transitions = Module.get_attribute(env.module, :nav_transitions) |> Enum.reverse()
    raw_actions = Module.get_attribute(env.module, :nav_actions) |> Enum.reverse()

    screen_list =
      Macro.escape(
        Enum.map(raw_screens, fn {name, identity, refines, catch_all} ->
          %StarlightBot.Navigation.Screen{
            name: name,
            identity_hook: identity,
            refines: refines,
            catch_all: catch_all
          }
        end)
      )

    raw_transitions
    |> Enum.group_by(fn {from, _to, name, _fun} -> {from, name} end)
    |> Enum.each(fn {{from, name}, group} ->
      if length(group) > 1 do
        raise CompileError,
          file: env.file,
          description:
            "screen #{inspect(from)} has #{length(group)} transitions named #{inspect(name)} — " <>
              "add `name:` to disambiguate multiple paths to the same screen"
      end
    end)

    transition_list =
      Enum.map(raw_transitions, fn {from, to, name, fun_name} ->
        quote do
          %StarlightBot.Navigation.Transition{
            from: unquote(from),
            to: unquote(to),
            name: unquote(name),
            steps: unquote(fun_name)()
          }
        end
      end)

    action_list =
      Enum.map(raw_actions, fn {screen, name, fun_name} ->
        quote do
          %StarlightBot.Navigation.Action{
            screen: unquote(screen),
            name: unquote(name),
            steps: unquote(fun_name)()
          }
        end
      end)

    quote do
      def __nav_screens__, do: unquote(screen_list)
      def __nav_transitions__, do: unquote(transition_list)
      def __nav_actions__, do: unquote(action_list)
    end
  end
end
