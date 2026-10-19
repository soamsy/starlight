defmodule StarlightBot.Navigation.Screen do
  @enforce_keys [:name, :identity_hook]
  defstruct [:name, :identity_hook, refines: nil, catch_all: false, settle: true]

  @type hook_spec :: atom() | {:not, hook_spec()} | {:all, [hook_spec()]} | {:any, [hook_spec()]}

  @type t :: %__MODULE__{
    name: atom(),
    identity_hook: hook_spec() | nil,
    refines: atom() | nil,
    catch_all: boolean(),
    settle: boolean()
  }
end

defmodule StarlightBot.Navigation.Transition do
  alias StarlightBot.Navigation.Screen

  @enforce_keys [:from, :to, :name, :steps]
  defstruct [:from, :to, :name, :steps]

  @type step ::
    {:click, atom()}
    | {:click, atom(), keyword()}
    | {:move_to, atom()}
    | {:premove, atom()}
    | {:drag, atom(), number(), number(), pos_integer() | nil}
    | {:scroll, number(), number()}
    | {:key, atom()}
    | {:type, String.t()}
    | {:await, Screen.hook_spec(), pos_integer()}
    | {:await, Screen.hook_spec(), pos_integer(), [premove: false]}
    | {:await_any, [Screen.hook_spec()], pos_integer()}
    | {:branch, [{Screen.hook_spec(), [step()]}], [step()]}
    | {:branch, [{Screen.hook_spec(), [step()]}], [step()], pos_integer()}
    | {:sleep, pos_integer()}
    | {:retry_until, Screen.hook_spec(), [step()], pos_integer(), pos_integer()}
    | {:retry_until, Screen.hook_spec(), [step()], pos_integer(), pos_integer(), pos_integer() | nil, Screen.hook_spec()}

  @type t :: %__MODULE__{
    from: atom(),
    to: atom(),
    name: atom(),
    steps: [step()]
  }
end

defmodule StarlightBot.Navigation.Action do
  alias StarlightBot.Navigation.Transition

  @enforce_keys [:screen, :name, :steps]
  defstruct [:screen, :name, :steps]

  @type t :: %__MODULE__{
    screen: atom(),
    name: atom(),
    steps: [Transition.step()]
  }
end
