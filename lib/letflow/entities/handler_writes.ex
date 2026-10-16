defmodule Letflow.Entities.HandlerWrites do
  @moduledoc """
  GH #2590 / REQ-501 R4a (decision 0054 D6; design
  `lib/letflow/design/gh2590-req501-module-write-handlers.md` 4.6, 6.1, 7.2): the platform side
  of a module write handler's entity writes. Nothing here is reachable from the engine yet
  (R4b integrates it); this PR ships the write path and its static scans only.

  ## Handler-facing API: `create/3` only

  A module's handler builds Multi steps by calling `create/3` and nothing else (the contract is
  in `Letflow.Entities.HandlerContext`). `create/3` is the single place where every platform
  check lives (F-2), so "enforced twice" (the writer's target assertion plus the narrowed
  `Owner`) holds for the whole handler-visible API:

    1. the context and the command are well formed (`:invalid_write_command`);
    2. the type is one of the handler's REGISTERED targets (`:target_not_registered`), checked
       against the Catalog's registration, not only against the context;
    3. at most 49 `create` additions per handler call (`:too_many_writes`);
    4. the write-side field restrictions of `ctx.subject_id`;
    5. the `Owner` is derived on EVERY call by `ManagedTypes.owner_for_handler/2` from the
       Catalog registration (never taken from the context, F-4; which is also why this file is
       an `@authority_callers` file: the third argument of `Records.command_multi/3` is a
       non-literal here);
    6. `Records.command_multi/3` with that Owner, a server-built `StepSource` (handler,
       `write_ordinal`) and a `{:line, key, :policy}` step that re-reads the type's
       definition row under its sequence lock and requires `managed_by == handler.module_id`
       (F-7: the registration only names the type in the MANIFEST) and an unscoped type
       (INV-6, until decision 0051).

  A build-time refusal of 4 or 6 (a restricted field, a managed-type refusal, an unknown
  type) is surfaced as a failing `{:line, key, :build}` step, exactly as `StepWrites` does, so
  the transaction rolls back and the engine's failure mapping applies; the three contract
  errors of 1-3 are returned to the handler.

  ## Platform-facing functions (not for handler code; scan H4 forbids them in handler files)

    * `build_call/4`: ONE handler call of a `module_writes` line, as the steps
      `{:line, k0, :owner_recheck}` and a lazily built handler Multi (`k0 =
      StepSource.call_key(line_index)`). The recheck re-reads the install row's manifest hash
      with NO lock (TOCTOU) and requires installed == compiled == the stamp's hash: the R3
      interim guard's removal note ("the executor re-verifies the install row and the hash at
      execution time"). The handler is resolved by the Catalog from the PINNED line's module
      and handler strings (string comparison, no atom creation); the arguments are resolved
      from the line (`var` from the merged variables, `const` as is, never `_sys`) and
      re-checked against the CURRENT registration; the handler is invoked through
      `Catalog.call_write_handler/4`; its return is shape-checked and every step name it
      added must lie in the call's own `{:line, k0 + 1 .. k0 + 49, _}` range. A handler that
      raises while building is reduced to the closed reason `:handler_raised` (build time
      only; no database state exists to corrupt); a database error inside a step is never
      rescued here.
    * `lock_types/3`: the type locks (`EventStore.lock_instance_sequence/3`), one step per
      type in ASCENDING byte order, to be placed before any write step (0054 D3 rule 4), so a
      handler can neither reorder nor skip them.

  Neither function authorizes the stamp or the body hash (R4b's pre-transaction
  `authorize_module_writes/2` does, INV-3); `build_call/4` re-verifies only the install row
  and hash. Replay never reaches this module: it has no caller outside a completion's Multi
  build (D-R.19).
  """

  alias Ecto.Multi
  alias Letflow.Engine.VariableMerge
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.HandlerContext
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.Entities.Records
  alias Letflow.Entities.StepSource
  alias Letflow.Entities.StepWrites
  alias Letflow.EventStore
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Installs

  require Logger

  @max_writes_per_call 49

  # Per-call token (SECURITY review of R4a, S1/S2): `invoke/4` stores the exact context it built,
  # and the entries `create/3` produced, in the calling process for the duration of the handler
  # call. `create/3` refuses any context that is not that exact struct, so a handler cannot forge
  # `prefix` / `handler` / actor fields by updating the context it was given; `check_built/3`
  # accepts only entries `create/3` produced, so a handler cannot smuggle in a `Multi.run` with a
  # live repo. The process dictionary is reachable from handler code; scan H4 flags `Process`,
  # `:erlang` and context-key updates as a tripwire (modules are compiled-in code: the residual is
  # stated in decision 0054's R4a amendment).
  @token_key {__MODULE__, :call}

  @type write_command :: %{required(:entity_type) => String.t(), required(:field_values) => map()}
  @type handler_error :: :invalid_arguments | :not_permitted

  @typedoc """
  What the platform supplies for one handler call (an atom-keyed map): the `HandlerContext`
  fields except `handler`, plus the stamp's `manifest_hash` for the run-time recheck.
  `subject_id` defaults to `actor_id`.
  """
  @type call_attrs :: %{
          required(:prefix) => String.t(),
          required(:instance_id) => Ecto.UUID.t(),
          required(:origin) => HandlerContext.origin(),
          required(:node_id) => String.t(),
          required(:definition_id) => Ecto.UUID.t(),
          required(:definition_version) => String.t(),
          required(:line_index) => non_neg_integer(),
          required(:actor_id) => Ecto.UUID.t(),
          required(:activator_id) => Ecto.UUID.t(),
          required(:manifest_hash) => String.t(),
          optional(:subject_id) => Ecto.UUID.t()
        }

  # ---------------------------------------------------------------------
  # create/3 (the handler-facing writer)
  # ---------------------------------------------------------------------

  @doc """
  Appends one create to `multi` for `command` (`%{entity_type, field_values}`; nothing else is
  accepted). See the moduledoc for the checks. Returns `{:ok, multi}` or one of the three
  closed contract errors.
  """
  @spec create(Multi.t(), HandlerContext.t(), write_command()) ::
          {:ok, Multi.t()}
          | {:error, :target_not_registered | :too_many_writes | :invalid_write_command}
  def create(%Multi{} = multi, %HandlerContext{} = ctx, command) do
    with {:ok, token} <- fetch_token(ctx),
         {:ok, entity_type, field_values} <- check_command(ctx, command),
         {:ok, owner} <- check_target(ctx, entity_type),
         {:ok, ordinal} <- next_ordinal(token) do
      written = build_write(multi, ctx, owner, ordinal, entity_type, field_values)
      record_produced(token, Multi.to_list(written) -- Multi.to_list(multi))
      {:ok, written}
    end
  end

  def create(_multi, _ctx, _command), do: {:error, :invalid_write_command}

  # The context must be EXACTLY the one the platform built for the handler call now running in
  # this process; anything else (a forged copy, a call outside a handler call) is refused.
  defp fetch_token(ctx) do
    case Process.get(@token_key) do
      %{ctx: ^ctx} = token -> {:ok, token}
      _forged_or_absent -> {:error, :invalid_write_command}
    end
  end

  defp record_produced(token, entries) do
    Process.put(@token_key, %{token | produced: token.produced ++ entries})
  end

  defp check_command(
         %HandlerContext{} = ctx,
         %{entity_type: type, field_values: values} = command
       )
       when map_size(command) == 2 and is_binary(type) and is_map(values) and
              not is_struct(values) do
    if valid_context?(ctx), do: {:ok, type, values}, else: {:error, :invalid_write_command}
  end

  defp check_command(_ctx, _command), do: {:error, :invalid_write_command}

  defp valid_context?(%HandlerContext{
         prefix: prefix,
         origin: {tag, origin_id},
         line_index: line_index,
         handler: %{module_id: module_id, name: name, targets: targets}
       }) do
    is_binary(prefix) and tag in [:task, :dispatch] and is_binary(origin_id) and
      is_integer(line_index) and line_index >= 0 and is_binary(module_id) and
      is_binary(name) and is_list(targets)
  end

  defp valid_context?(_ctx), do: false

  # Registered target, checked twice: the context's list AND the Owner re-derived from the
  # Catalog (F-4). An unresolvable handler fails closed as an unregistered target.
  defp check_target(
         %HandlerContext{handler: %{module_id: module_id, name: name, targets: targets}},
         type
       ) do
    with true <- type in targets,
         {:ok, %{manages: manages} = owner} <- ManagedTypes.owner_for_handler(module_id, name),
         true <- MapSet.member?(manages, type) do
      {:ok, owner}
    else
      _not_registered -> {:error, :target_not_registered}
    end
  end

  # The ordinal is the number of distinct keys `create/3` already produced in this call, plus
  # one. It is taken from the per-call token, not from the Multi the handler passes in, so a
  # handler cannot reset the count by passing a fresh Multi.
  defp next_ordinal(%{produced: produced}) do
    used =
      produced
      |> Enum.flat_map(fn
        {{:line, key, _step}, _op} -> [key]
        _other -> []
      end)
      |> Enum.uniq()
      |> length()

    if used >= @max_writes_per_call, do: {:error, :too_many_writes}, else: {:ok, used + 1}
  end

  defp build_write(multi, ctx, owner, ordinal, entity_type, field_values) do
    key = StepSource.call_key(ctx.line_index) + ordinal
    {origin_tag, origin_id} = ctx.origin

    origin_attrs =
      if origin_tag == :task, do: %{task_id: origin_id}, else: %{dispatch_id: origin_id}

    with :ok <- check_restrictions(ctx, entity_type, field_values),
         {:ok, source} <-
           StepSource.new(
             Map.merge(origin_attrs, %{
               instance_id: ctx.instance_id,
               node_id: ctx.node_id,
               definition_id: ctx.definition_id,
               definition_version: ctx.definition_version,
               line_index: ctx.line_index,
               activator_id: ctx.activator_id,
               handler: %{module_id: ctx.handler.module_id, name: ctx.handler.name},
               write_ordinal: ordinal
             })
           ),
         {:ok, line_multi} <-
           Records.command_multi(
             %{
               kind: :create,
               entity_type: entity_type,
               field_values: field_values,
               actor_id: ctx.actor_id,
               source: source
             },
             ctx.prefix,
             owner
           ) do
      module_id = ctx.handler.module_id

      multi
      |> Multi.append(line_multi)
      |> Multi.run({:line, key, :policy}, fn _repo, changes ->
        policy(Map.fetch!(changes, {:line, key, :recheck_definition}), module_id)
      end)
    else
      {:error, reason} -> Multi.error(multi, {:line, key, :build}, reason)
    end
  end

  defp check_restrictions(ctx, entity_type, field_values) do
    subject = Map.get(ctx, :subject_id) || ctx.actor_id

    case FieldGrants.load_restrictions(subject, entity_type, ctx.prefix) do
      {:ok, restricted} ->
        if Enum.any?(Map.keys(field_values), &MapSet.member?(restricted, &1)),
          do: {:error, :field_restricted},
          else: :ok

      {:error, _reason} ->
        {:error, :field_restricted}
    end
  end

  # Reads the row `:recheck_definition` returned under the type's sequence lock (F-7, INV-6).
  defp policy(%EntityDefinition{managed_by: managed_by} = row, module_id) do
    cond do
      managed_by != module_id -> {:error, :target_not_managed_by_module}
      StepWrites.scoped_type?(row) -> {:error, :scoped_type}
      true -> {:ok, :allowed}
    end
  end

  defp policy(_other, _module_id), do: {:error, :target_not_managed_by_module}

  # ---------------------------------------------------------------------
  # Platform-facing: type locks and one handler call
  # ---------------------------------------------------------------------

  @doc """
  Appends one `{:type_lock, type}` step per distinct type, in ascending byte order, each taking
  the type's `instance_sequences` row lock (`EventStore.lock_instance_sequence/3`). The caller
  passes the union of the declarative and handler-target types and places the result before any
  write step. A type without a synthetic instance fails the step with
  `{:entity_type_instance_missing, type}`.
  """
  @spec lock_types(Multi.t(), [String.t()], prefix :: String.t()) :: Multi.t()
  def lock_types(%Multi{} = multi, types, prefix) when is_list(types) and is_binary(prefix) do
    types
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce(multi, fn type, acc ->
      Multi.run(acc, {:type_lock, type}, fn repo, _changes ->
        case EntityTypeInstance.fetch_instance_id(type, prefix) do
          {:ok, instance_id} -> EventStore.lock_instance_sequence(repo, instance_id, prefix)
          {:error, :not_found} -> {:error, {:entity_type_instance_missing, type}}
        end
      end)
    end)
  end

  @doc """
  Appends the steps of ONE `module_writes` line to `multi` (see the moduledoc). `line` is the
  PINNED string-keyed line (`module`, `handler`, `args`); `variables` the merged instance
  variables (a closure over the transaction's changes is the caller's business: pass the map
  as read inside the transaction, or use `build_call/4` from within a `Multi.merge`).

  Build failures are failing `{:line, k0, :build}` steps with a closed reason:
  `:handler_unknown`, `:handler_invalid_arguments`, `:handler_not_permitted`,
  `:handler_shape`, `:handler_raised`. The recheck step fails with `:hash_mismatch`.
  """
  @spec build_call(Multi.t(), call_attrs(), map(), %{optional(String.t()) => term()}) :: Multi.t()
  def build_call(
        %Multi{} = multi,
        %{line_index: line_index, prefix: prefix} = attrs,
        line,
        variables
      )
      when is_integer(line_index) and line_index >= 0 and is_binary(prefix) and is_map(line) and
             is_map(variables) do
    k0 = StepSource.call_key(line_index)
    module_id = Map.get(line, "module")
    stamp_hash = Map.get(attrs, :manifest_hash)

    multi
    |> Multi.run({:line, k0, :owner_recheck}, fn _repo, _changes ->
      owner_recheck(module_id, prefix, stamp_hash)
    end)
    |> Multi.merge(fn _changes -> invoke(attrs, line, variables, k0) end)
  end

  # The install row and both hashes, re-read with NO lock at execution time (TOCTOU defence).
  # `tenant_modules` has no status column in this build (a row IS an installed module; there is
  # no disabled/uninstalled state), so row existence is the whole "installed and enabled" check.
  # Uninstall (decision 0055) must delete the row or add a status this function then checks.
  defp owner_recheck(module_id, prefix, stamp_hash)
       when is_binary(module_id) and is_binary(stamp_hash) do
    with {:ok, installed} <- Installs.installed_manifest_hash(module_id, prefix: prefix),
         {:ok, compiled} <- Catalog.manifest_hash(module_id),
         true <- installed == compiled and installed == stamp_hash do
      {:ok, :verified}
    else
      _mismatch -> {:error, :hash_mismatch}
    end
  end

  defp owner_recheck(_module_id, _prefix, _stamp_hash), do: {:error, :hash_mismatch}

  defp invoke(attrs, line, variables, k0) do
    with {:ok, handler} <- resolve(line),
         {:ok, args} <- resolve_args(Map.get(line, "args", %{}), handler.args, variables),
         ctx = build_context(attrs, handler),
         {:ok, built, produced} <- call_handler(handler, ctx, args),
         :ok <- check_built(built, produced, k0) do
      built
    else
      {:error, reason} -> Multi.error(Multi.new(), {:line, k0, :build}, reason)
    end
  end

  defp resolve(%{"module" => module_id, "handler" => name}) do
    case Catalog.write_handler(module_id, name) do
      {:ok, handler} -> {:ok, handler}
      {:error, :not_found} -> {:error, :handler_unknown}
    end
  end

  defp resolve(_line), do: {:error, :handler_unknown}

  defp build_context(attrs, handler) do
    %HandlerContext{
      prefix: attrs.prefix,
      instance_id: attrs.instance_id,
      origin: attrs.origin,
      node_id: attrs.node_id,
      definition_id: attrs.definition_id,
      definition_version: attrs.definition_version,
      line_index: attrs.line_index,
      actor_id: attrs.actor_id,
      subject_id: Map.get(attrs, :subject_id, attrs.actor_id),
      activator_id: attrs.activator_id,
      handler: %{module_id: handler.module_id, name: handler.name, targets: handler.targets}
    }
  end

  # Arguments: names must be declared, every `required` one present after resolution (a `var`
  # absent from the variables, or a reserved `_sys` key, resolves to nothing).
  defp resolve_args(args, declared, variables) when is_map(args) and not is_struct(args) do
    resolved =
      Enum.reduce_while(args, {:ok, %{}}, fn
        {name, source}, {:ok, acc} when is_binary(name) ->
          cond do
            not Map.has_key?(declared, name) -> {:halt, {:error, :handler_invalid_arguments}}
            true -> {:cont, {:ok, put_arg(acc, name, source, variables)}}
          end

        _bad, _acc ->
          {:halt, {:error, :handler_invalid_arguments}}
      end)

    with {:ok, values} <- resolved do
      missing? =
        Enum.any?(declared, fn {name, spec} ->
          spec.required and not Map.has_key?(values, name)
        end)

      if missing?, do: {:error, :handler_invalid_arguments}, else: {:ok, values}
    end
  end

  defp resolve_args(_args, _declared, _variables), do: {:error, :handler_invalid_arguments}

  defp put_arg(acc, name, %{"const" => value}, _variables), do: Map.put(acc, name, value)

  defp put_arg(acc, name, %{"var" => var}, variables) when is_binary(var) do
    if VariableMerge.reserved_key?(var) do
      acc
    else
      case Map.fetch(variables, var) do
        {:ok, value} -> Map.put(acc, name, value)
        :error -> acc
      end
    end
  end

  defp put_arg(acc, _name, _source, _variables), do: acc

  # Rescues BUILD-time exceptions of (pure) handler code only; ids and names are logged, never
  # the exception text (INV-4).
  defp call_handler(handler, ctx, args) do
    case safe_call(handler, ctx, args) do
      {{:ok, %Multi{} = built}, produced} ->
        {:ok, built, produced}

      {{:error, :invalid_arguments}, _produced} ->
        {:error, :handler_invalid_arguments}

      {{:error, :not_permitted}, _produced} ->
        {:error, :handler_not_permitted}

      {{:raised, exception_module}, _produced} ->
        Logger.error(
          "module write handler raised at build: module=#{handler.module_id} " <>
            "handler=#{handler.name} exception=#{inspect(exception_module)}"
        )

        {:error, :handler_raised}

      _other ->
        {:error, :handler_shape}
    end
  end

  # Runs the handler with the per-call token set (and always cleared). Returns the handler's raw
  # return paired with the entries `create/3` produced during the call.
  defp safe_call(handler, ctx, args) do
    Process.put(@token_key, %{ctx: ctx, produced: []})

    try do
      raw = Catalog.call_write_handler(handler, Multi.new(), ctx, args)
      {raw, Map.fetch!(Process.get(@token_key), :produced)}
    rescue
      exception -> {{:raised, exception.__struct__}, []}
    after
      Process.delete(@token_key)
    end
  end

  # Every entry the handler returned must be one `create/3` produced during this call (same step
  # name AND same operation, so a handler's own `Multi.run`/`insert` with a live repo is refused),
  # and its step name must lie in the call's own `{:line, key, _}` range.
  defp check_built(%Multi{} = built, produced, k0) do
    ok? =
      built
      |> Multi.to_list()
      |> Enum.all?(fn
        {{:line, key, step}, _op} = entry when is_integer(key) and is_atom(step) ->
          key > k0 and key <= k0 + @max_writes_per_call and entry in produced

        _other ->
          false
      end)

    if ok?, do: :ok, else: {:error, :handler_shape}
  end
end
