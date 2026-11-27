defmodule Letflow.PlatformFunctions.Entry do
  @moduledoc """
  One entry of the compiled platform function catalogue (T-2588, gap G2 of the
  "Register a tenant" pilot; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`).

  An entry is a DECLARATION, not an implementation. It says what a platform
  function is called, what it reads, what it returns, who may switch it on and
  where it may run. The body of the function and the dispatcher that runs it
  belong to the step library (gap G1); this catalogue is the closed list the
  designer reads and the activation fence checks against, so an entry exists
  only if it is compiled into the build (option (a) of the decision record: no
  write route, no run-time registration).

  ## Fields

    * `name` -- the function name a definition's `platform_call` step names
      (`"tenant.create"`);
    * `family` -- `:platform` for the core platform family, or a module id;
    * `version` -- the entry's own version;
    * `inputs` -- typed inputs, each with a SOURCE CLASS (see `Input`);
    * `outputs` -- the typed names the next steps may read;
    * `permission` -- the atom the ACTIVATOR and the STARTER must hold
      (`:TenantsManage` for the tenant family);
    * `side_effects` -- plain words plus a class, shown in the designer;
    * `idempotency_key` -- the input names that make a repeat the same call;
    * `platform_tenant_only` -- true for the platform family: the call may run
      only in the platform tenant (INV-10).

  ## Families

  The `family` says WHO owns the function: `:platform` for the core platform
  family, or the id of the MODULE that owns it (D-204, the module-process
  conversion, section 1.2). A module family entry is derived from the module's
  own write-handler registration (see `Letflow.PlatformFunctions.ModuleFamily`),
  never written by hand.

  The two families have two different TENANT RULES, and the entry says which:

    * the platform family (`platform_tenant_only: true`) may run only in the
      platform tenant (INV-10);
    * a module family entry (`platform_tenant_only: false`) may run only in a
      tenant that has the module INSTALLED, with the compiled module's
      manifest hash accepted (the check
      `Letflow.Definitions.ModuleWrites` does today for the owner stamp, moved
      from the stamp to the entry -- see
      `Letflow.PlatformFunctions.ModuleTenantRule`).

  ## Source classes

  `:start` -- the value comes from the start form of the person who started
  the instance (a trusted input, because the starter must hold the entry's
  permission); `:step` -- the value comes from an earlier platform step's
  output; `:person` -- the value may come from a human task's completer.

  A WRITE-LIKE input (one the entry's `side_effects` name as a write) may
  never be `:person`: the T-2430 rule carries over by source class, so a
  human task cannot decide what a platform function writes.
  """

  defmodule Input do
    @moduledoc """
    One typed input of a catalogue entry, with its source class.

    `source_class` is `:start`, `:step` or `:person`; see the parent module's
    "Source classes".
    """

    @enforce_keys [:name, :type, :required, :source_class]
    defstruct [:name, :type, :required, :source_class]

    @typedoc "Where a value of this input may come from."
    @type source_class :: :start | :step | :person

    @type t :: %__MODULE__{
            name: String.t(),
            type: atom(),
            required: boolean(),
            source_class: source_class()
          }
  end

  defmodule Output do
    @moduledoc "One typed output of a catalogue entry."

    @enforce_keys [:name, :type]
    defstruct [:name, :type]

    @type t :: %__MODULE__{name: String.t(), type: atom()}
  end

  defmodule SideEffect do
    @moduledoc """
    One side effect of a catalogue entry, in plain words plus a class.

    The classes are closed: `:read`, `:write_tenant_registry`, `:ddl`,
    `:outbound`, and -- since D-204 (the module-process conversion, section
    1.2) -- the two MODULE classes `:write_module_record` and `:ledger_post`.

    The module classes say what a module function does inside its own tenant:
    it writes a record of the module's own types, or it posts a ledger entry.
    Both are WRITE-LIKE: a human task may never decide what they write (see
    the parent module's "Source classes").
    """

    @enforce_keys [:text, :class]
    defstruct [:text, :class]

    @type class ::
            :read
            | :write_tenant_registry
            | :ddl
            | :outbound
            | :write_module_record
            | :ledger_post

    @type t :: %__MODULE__{text: String.t(), class: class()}
  end

  @doc """
  The closed set of side-effect classes, sorted. The designer shows them and
  the entry validation refuses any other one.
  """
  @spec side_effect_classes() :: [SideEffect.class()]
  def side_effect_classes, do: [:ddl, :ledger_post, :outbound, :read, :write_module_record, :write_tenant_registry]

  @enforce_keys [
    :name,
    :family,
    :version,
    :inputs,
    :outputs,
    :permission,
    :side_effects,
    :idempotency_key,
    :platform_tenant_only
  ]
  defstruct [
    :name,
    :family,
    :version,
    :inputs,
    :outputs,
    :permission,
    :side_effects,
    :idempotency_key,
    :platform_tenant_only
  ]

  @type family :: :platform | String.t()

  @type t :: %__MODULE__{
          name: String.t(),
          family: family(),
          version: String.t(),
          inputs: [Input.t()],
          outputs: [Output.t()],
          permission: atom(),
          side_effects: [SideEffect.t()],
          idempotency_key: [String.t()],
          platform_tenant_only: boolean()
        }

  @doc """
  The inputs of `entry` a human completer may NOT write: every input whose
  source class is not `:person`. These are the keys `Letflow.Engine.WriteTargets`
  refuses in a task completion body.
  """
  @spec trusted_inputs(t()) :: [Input.t()]
  def trusted_inputs(%__MODULE__{inputs: inputs}) when is_list(inputs) do
    Enum.filter(inputs, &(&1.source_class != :person))
  end

  @doc """
  True when the entry is WRITE-LIKE: every side effect it declares is more
  than a read (a write, a DDL or an outbound call that carries data out). The
  inputs of such an entry may never come from a person.
  """
  @spec write_like?(t()) :: boolean()
  def write_like?(%__MODULE__{side_effects: side_effects}) when is_list(side_effects) do
    Enum.any?(side_effects, &(&1.class != :read))
  end

  @doc """
  True when the entry belongs to a MODULE family (D-204): its family names the
  module that owns the function, not the platform.
  """
  @spec module_family?(t()) :: boolean()
  def module_family?(%__MODULE__{family: family}), do: family != :platform

  @doc """
  The id of the module that owns a MODULE-family entry, or `nil` for the
  platform family. The module id is what the tenant rule looks up: the module
  must be installed in the instance's tenant.
  """
  @spec module_id(t()) :: String.t() | nil
  def module_id(%__MODULE__{family: :platform}), do: nil
  def module_id(%__MODULE__{family: family}) when is_binary(family), do: family

  @doc """
  The compile-time checks of a whole catalogue: no duplicate name, and every
  entry well formed. Raises when the catalogue could not be trusted at run
  time (the catalogue is code, and code that does not compile does not ship).
  """
  @spec validate_catalogue!([t()]) :: :ok
  def validate_catalogue!(entries) when is_list(entries) do
    names = Enum.map(entries, & &1.name)

    if Enum.uniq(names) != names do
      raise "duplicate platform function entry: #{inspect(names -- Enum.uniq(names))}"
    end

    Enum.each(entries, &validate!/1)
    :ok
  end

  @doc """
  One entry's own checks: a name, a permission, the platform flag, the family
  the flag belongs to, the side-effect classes, inputs whose source class is one
  of the three known ones, and no `:person` input on a write-like entry.
  """
  @spec validate!(t()) :: :ok
  def validate!(%__MODULE__{} = entry) do
    unless is_binary(entry.name) and entry.name != "" do
      raise "platform function entry without a name"
    end

    unless is_atom(entry.permission) and not is_nil(entry.permission) do
      raise "platform function entry #{entry.name} without a permission"
    end

    unless is_boolean(entry.platform_tenant_only) do
      raise "platform function entry #{entry.name} without platform_tenant_only"
    end

    validate_family!(entry)
    validate_side_effects!(entry)

    Enum.each(entry.inputs, fn
      %Input{source_class: source_class} when source_class in [:start, :step, :person] ->
        :ok

      other ->
        raise "platform function entry #{entry.name} has a malformed input: #{inspect(other)}"
    end)

    if write_like?(entry) and Enum.any?(entry.inputs, &(&1.source_class == :person)) do
      raise "platform function entry #{entry.name} is write-like and may not declare a :person input"
    end

    :ok
  end

  # The two families and the two tenant rules belong together: the platform
  # flag says which rule the entry runs under, and the family says who owns it.
  # An entry that claims the platform rule but names a module (or the other way
  # round) is a contradiction, and a catalogue that carries one cannot be
  # trusted at run time.
  defp validate_family!(%__MODULE__{family: :platform, platform_tenant_only: true}), do: :ok

  defp validate_family!(%__MODULE__{family: :platform}),
    do: raise("a platform family entry must be platform_tenant_only")

  defp validate_family!(%__MODULE__{family: family, platform_tenant_only: false})
       when is_binary(family) and family != "",
       do: :ok

  defp validate_family!(%__MODULE__{family: family, platform_tenant_only: true}),
    do: raise("a module family entry #{family} must not be platform_tenant_only")

  defp validate_family!(%__MODULE__{family: family}),
    do: raise("platform function entry with a malformed family: #{inspect(family)}")

  defp validate_side_effects!(%__MODULE__{side_effects: side_effects}) when is_list(side_effects) do
    classes = side_effect_classes()

    Enum.each(side_effects, fn
      %SideEffect{class: class} when is_atom(class) ->
        unless class in classes do
          raise "platform function entry with an unknown side-effect class: #{inspect(class)}"
        end

      other ->
        raise "platform function entry has a malformed side effect: #{inspect(other)}"
    end)
  end

  defp validate_side_effects!(%__MODULE__{side_effects: side_effects}),
    do: raise("platform function entry with malformed side effects: #{inspect(side_effects)}")
end
