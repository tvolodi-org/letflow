defmodule Letflow.Entities.HandlerContext do
  @moduledoc """
  GH #2590 / REQ-501 R4a (design `lib/letflow/design/gh2590-req501-module-write-handlers.md`
  4.6): the value a module write handler receives as its second argument. Ids and names only.
  It carries NO authority, NO `repo`, NO `Owner` (F-4): every write goes through
  `Letflow.Entities.HandlerWrites.create/3`, which re-derives the `Owner` from `handler` on
  every call through `Letflow.Entities.ManagedTypes.owner_for_handler/2`.

  The struct is built only in `Letflow.Entities.HandlerWrites` (scan H2,
  `test/letflow/entities/handler_writes_callers_test.exs`).

  ## The handler contract (pinned by tests)

  A handler is `fun(multi, ctx, args)` returning `{:ok, multi}` or
  `{:error, :invalid_arguments | :not_permitted}`, registered in its module's manifest, resolved
  only by the Catalog and called only by the platform inside the step transaction. The context
  it receives is bound to that one call: `create/3` refuses a copy that differs in any field.

    1. The handler BUILDS Multi steps by calling `HandlerWrites.create/3` and does nothing
       else: it reads no table, holds no `repo`, never calls `Repo.transaction` or
       `Repo.rollback`, never rescues a database error, never starts a process or performs
       network or file I/O, never writes a table other than through `create/3`. Pure argument
       checking (returning `:invalid_arguments`) is its only logic. The scan H4 is a tripwire
       for this; the boundary is that the API hands the handler nothing dangerous.
    2. `create/3` is the ONLY writer. It builds the `StepSource` (with `handler` and the next
       `write_ordinal`), derives the key and namespace, refuses a type outside the handler's
       registered targets (`:target_not_registered`) and a call with more than 49 `create`
       additions (`:too_many_writes`), applies the field restrictions of `subject_id`, and
       writes through `Letflow.Entities.Records.command_multi/3` with the Owner the platform
       built from the Catalog registration. A `:policy` step then re-reads the type's
       definition row under its sequence lock and requires `managed_by` to equal the
       registering module and the type to be unscoped.
    3. The handler receives resolved argument VALUES, never the instance variables map.
    4. Step names are assigned by `HandlerWrites`; a returned Multi containing a name outside
       the call's own `{:line, key, _}` range is a contract violation (`:handler_shape`).

  `origin` is `{:task, task_id}` on the HUMAN path (`{:dispatch, id}` is reserved for the
  service-task path); `subject_id` is the user whose field restrictions apply (the completer,
  equal to `actor_id` on the HUMAN path).
  """

  @enforce_keys [
    :prefix,
    :instance_id,
    :origin,
    :node_id,
    :definition_id,
    :definition_version,
    :line_index,
    :actor_id,
    :subject_id,
    :activator_id,
    :handler
  ]
  defstruct [
    :prefix,
    :instance_id,
    :origin,
    :node_id,
    :definition_id,
    :definition_version,
    :line_index,
    :actor_id,
    :subject_id,
    :activator_id,
    :handler
  ]

  @type origin :: {:task, Ecto.UUID.t()} | {:dispatch, Ecto.UUID.t()}

  @type t :: %__MODULE__{
          prefix: String.t(),
          instance_id: Ecto.UUID.t(),
          origin: origin(),
          node_id: String.t(),
          definition_id: Ecto.UUID.t(),
          definition_version: String.t(),
          line_index: non_neg_integer(),
          actor_id: Ecto.UUID.t(),
          subject_id: Ecto.UUID.t(),
          activator_id: Ecto.UUID.t(),
          handler: %{module_id: String.t(), name: String.t(), targets: [String.t()]}
        }
end
