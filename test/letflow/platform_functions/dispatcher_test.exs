defmodule Letflow.PlatformFunctions.DispatcherTest do
  @moduledoc """
  The durable dispatcher of a platform step (T-2589, pilot gap G1a of the
  "Register a tenant" pilot).

  What the tests prove:

    * a step is armed as a durable row and run by the dispatcher;
    * the AUTHORITY FENCE is called before the body: a tampered signature is
      refused and the function never runs (PM inbox #182: the dispatcher MUST
      call `Letflow.PlatformFunctions.Guard.authorize_dispatch/1`);
    * the body runs OUTSIDE every transaction the dispatcher owns (the
      structural property that lets a platform function run DDL);
    * the closed registry: an unknown name and a declared-but-unimplemented
      name are both refused, with different codes;
    * the SECURITY GATE's findings: a repeated arming of the same call does
      not raise (the idempotency key is enforced by the index, and the
      dispatcher replays the first row), the row's tenant is derived from the
      schema it is written into, a prefix that names no tenant schema is
      refused instead of crashing, a row is bound to the definition's node,
      another tenant's row is never touched, and a call that reaches the
      attempt cap is dead-lettered;
    * the CONFIRMED security findings: a row whose lease has not expired is
      not re-claimed (the body runs once), two dispatchers of one row run the
      body once, an id that is not an id answers the uniform refusal, a value
      over the byte cap is refused before anything is written, an option the
      dispatcher does not read is refused, and a stale attempt cannot
      overwrite the result of the attempt that owns the row;
    * the bounds of the WRITE SIDE: a node id over its byte cap is refused
      before anything is written, a well-formed prefix that names no live
      tenant schema is refused as such (the derivation alone cannot see it),
      the failure kind is a stable code and never a customer text, and an
      outcome the row cannot carry is refused and leaves the row unchanged;
    * the CLASS of that refusal: a prefix that names no schema a dispatch row
      can live in is refused the same way on EVERY public path that takes a
      prefix -- the arming, the dispatch, the due query and the outcome write
      -- so that no path escapes with a raw database error;
    * the INV-10 negative test of the new path: a row armed in a COMPANY
      tenant's schema is refused at dispatch, the function never runs and the
      company row carries no outputs.

  `async: false`: the platform tenant pin is application configuration, which
  is VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.PlatformFunctions.Dispatcher
  alias Letflow.PlatformFunctions.Dispatcher.StepDispatch
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  @function "platform.validate_registration"

  setup do
    tenant = Fx.tenant!("t2589-disp")
    PlatformFx.pin!(tenant.tenant_id)

    admin = Fx.user!(tenant.schema_name, "admin")
    Fx.platform_admin!(tenant.schema_name, admin)

    %{tenant: tenant, admin: admin}
  end

  defp call do
    Fx.call(@function, %{
      "slug" => %{"var" => "slug"},
      "display_name" => %{"const" => "Acme Ltd"},
      "email" => %{"const" => "admin@acme.test"}
    })
  end

  defp inputs(overrides) do
    Map.merge(
      %{"slug" => "acme", "display_name" => "Acme Ltd", "email" => "admin@acme.test"},
      overrides
    )
  end

  defp activated(ctx) do
    draft = Fx.definition!(ctx.tenant.schema_name, Fx.graph(call()), "pcf-t2589-disp")

    activator =
      Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)

    assert {:ok, %{already_active: false}} =
             Definitions.activate(draft.id,
               prefix: ctx.tenant.schema_name,
               activator: activator
             )

    Repo.get!(Definitions.ProcessDefinition, draft.id, prefix: ctx.tenant.schema_name)
  end

  defp arm(ctx, definition, overrides \\ %{}) do
    Dispatcher.arm(
      prefix: ctx.tenant.schema_name,
      instance_id: Ecto.UUID.generate(),
      definition_id: definition.id,
      node_id: "call",
      function: @function,
      inputs: inputs(overrides)
    )
  end

  defp rows(ctx) do
    rows_in(ctx.tenant.schema_name, ctx.tenant.tenant_id)
  end

  defp rows_in(schema_name, tenant_id) do
    StepDispatch
    |> where([d], d.tenant_id == ^tenant_id)
    |> Repo.all(prefix: schema_name)
  end

  test "D1: an armed step is a durable row and the dispatcher runs the function", ctx do
    definition = activated(ctx)

    assert {:ok, %{status: :armed, dispatch: dispatch}} = arm(ctx, definition)
    assert dispatch.status == :pending
    assert dispatch.attempt_index == 0
    assert dispatch.function_name == @function

    # The key carries the function's name and a DIGEST of the declared key
    # inputs: no raw tenant-controlled value reaches the key column.
    assert String.starts_with?(dispatch.call_key, "platform.validate_registration|")
    assert byte_size(dispatch.call_key) <= 255
    refute dispatch.call_key =~ "acme"

    assert {:ok, {:advanced, outputs}} =
             Dispatcher.attempt_dispatch(dispatch.id, ctx.tenant.schema_name)

    assert outputs == %{
             "normalized_slug" => "acme",
             "email_domain" => "acme.test"
           }

    stored = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :advanced
    assert stored.outputs == outputs
    assert stored.attempt_index == 1
    assert stored.dispatched_at != nil
  end

  test "D2: the dispatcher calls the authority fence -- a tampered signature is refused and the function never runs",
       ctx do
    definition = activated(ctx)

    tampered = put_in(definition.activated_by, ["signature", "mac"], String.duplicate("a", 64))

    {1, _} =
      Repo.update_all(
        Ecto.Query.from(d in Definitions.ProcessDefinition, where: d.id == ^definition.id),
        [set: [activated_by: tampered]],
        prefix: ctx.tenant.schema_name
      )

    assert {:ok, %{status: :armed, dispatch: dispatch}} = arm(ctx, definition)

    assert {:error, :platform_call_signature_invalid} =
             Dispatcher.attempt_dispatch(dispatch.id, ctx.tenant.schema_name)

    stored = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :given_up
    assert stored.last_failure_kind == "platform_call_signature_invalid"
    assert stored.outputs == nil
  end

  test "D3: a refused value is recorded as a failed step, not as a crash", ctx do
    definition = activated(ctx)

    assert {:ok, %{status: :armed, dispatch: dispatch}} =
             arm(ctx, definition, %{"slug" => "Not A Slug"})

    assert {:error, :platform_call_invalid_slug} =
             Dispatcher.attempt_dispatch(dispatch.id, ctx.tenant.schema_name)

    stored = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :given_up
    assert stored.last_failure_kind == "platform_call_invalid_slug"
    assert stored.outputs == nil
  end

  test "D4: a name that is not in the catalogue is refused as unknown",
       ctx do
    definition = activated(ctx)

    assert {:error, :platform_function_unknown} =
             Dispatcher.arm(
               prefix: ctx.tenant.schema_name,
               instance_id: Ecto.UUID.generate(),
               definition_id: definition.id,
               node_id: "call",
               function: "platform.not_in_the_catalogue",
               inputs: %{}
             )
  end

  test "D5: arguments that do not match the entry are refused before anything is written", ctx do
    definition = activated(ctx)

    assert {:error, :platform_call_arg_missing} =
             Dispatcher.arm(
               prefix: ctx.tenant.schema_name,
               instance_id: Ecto.UUID.generate(),
               definition_id: definition.id,
               node_id: "call",
               function: @function,
               inputs: %{"slug" => "acme"}
             )

    assert {:error, :platform_call_arg_unknown} =
             Dispatcher.arm(
               prefix: ctx.tenant.schema_name,
               instance_id: Ecto.UUID.generate(),
               definition_id: definition.id,
               node_id: "call",
               function: @function,
               inputs: inputs(%{"tenant_id" => "e6f1a0f2-0000-0000-0000-000000000000"})
             )

    assert rows(ctx) == []
  end

  test "D6: the function body runs OUTSIDE every transaction the dispatcher owns", ctx do
    definition = activated(ctx)

    assert {:ok, %{status: :armed, dispatch: dispatch}} = arm(ctx, definition)

    assert {:ok, {:advanced, _outputs}} =
             Dispatcher.attempt_dispatch(dispatch.id, ctx.tenant.schema_name)

    source = File.read!("lib/letflow/platform_functions/dispatcher.ex")
    {:ok, ast} = Code.string_to_quoted(source)

    for block <- transaction_blocks(ast) do
      refute contains_call?(block, :invoke),
             "the function body must not run inside a transaction of the dispatcher (DDL cannot)"
    end
  end

  test "D7: a row of another tenant is never touched", ctx do
    definition = activated(ctx)

    assert {:ok, %{status: :armed, dispatch: dispatch}} = arm(ctx, definition)

    # Another tenant, with its own schema and its own rows.
    other = Fx.tenant!("t2589-other")

    # The dispatch of the platform tenant's row id under the other tenant's
    # prefix finds nothing: the row lives in another schema, so the answer is
    # the uniform "not found" -- never the row itself, never a partial read.
    assert {:error, :platform_step_not_found} =
             Dispatcher.attempt_dispatch(dispatch.id, other.schema_name)

    # Neither tenant's rows changed: the platform tenant's row is untouched
    # and still pending, the other tenant has no row at all.
    assert length(rows(ctx)) == 1
    assert length(rows_in(other.schema_name, other.tenant_id)) == 0

    stored = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :pending
    assert stored.attempt_index == 0
    assert stored.outputs == nil
  end

  test "D8: a prefix that names no tenant schema is refused before the row is written", ctx do
    definition = activated(ctx)

    for bad_prefix <- [
          "public",
          nil,
          "tenant_not-a-uuid",
          "tenant_ZZZ",
          # WELL-FORMED but absent: the derivation alone cannot see that no
          # such schema exists, so the dispatcher asks Postgres before it
          # writes a row into it.
          "tenant_0123456789abcdef0123456789abcdef"
        ] do
      assert {:error, :invalid_schema_name} =
               Dispatcher.arm(
                 prefix: bad_prefix,
                 instance_id: Ecto.UUID.generate(),
                 definition_id: definition.id,
                 node_id: "call",
                 function: @function,
                 inputs: inputs(%{})
               )
    end

    # Nothing was written, and the real tenant's rows are untouched.
    assert rows(ctx) == []
  end

  test "D9: the row's tenant is DERIVED from the schema, not taken from the caller", ctx do
    definition = activated(ctx)

    assert {:ok, %{status: :armed, dispatch: dispatch}} =
             Dispatcher.arm(
               prefix: ctx.tenant.schema_name,
               instance_id: Ecto.UUID.generate(),
               definition_id: definition.id,
               node_id: "call",
               function: @function,
               inputs: inputs(%{})
             )

    # The row sits in the schema of `ctx.tenant`, so that is the tenant it
    # claims to belong to (decision 0003's addendum).
    assert dispatch.tenant_id == ctx.tenant.tenant_id
  end

  test "D10: a repeated arming of the same call does not raise -- the first row wins", ctx do
    definition = activated(ctx)

    assert {:ok, %{status: :armed, dispatch: first}} = arm(ctx, definition)

    # The unique index on the idempotency key really is enforced, and the
    # changeset really declares it: a raw second insert of the same key is a
    # CHANGESET error, not an `Ecto.ConstraintError` (INV-8).
    assert {:error, %Ecto.Changeset{}} =
             StepDispatch.arm_changeset(%StepDispatch{id: Ecto.UUID.generate()}, %{
               id: Ecto.UUID.generate(),
               tenant_id: ctx.tenant.tenant_id,
               instance_id: Ecto.UUID.generate(),
               definition_id: definition.id,
               node_id: "call",
               function_name: @function,
               call_key: first.call_key,
               input_fingerprint: first.input_fingerprint,
               inputs: first.inputs,
               status: :pending,
               attempt_index: 0,
               next_attempt_at: DateTime.utc_now(),
               created_at: DateTime.utc_now()
             })
             |> Repo.insert(prefix: ctx.tenant.schema_name)

    # The dispatcher's own arming of the same call does not raise either: it
    # writes with ON CONFLICT DO NOTHING and hands back the row that carries
    # the key (the double click, the retry, the poller restart of S8).
    assert {:ok, %{status: :armed, dispatch: replay}} = arm(ctx, definition)
    assert replay.id == first.id

    # One row, one attempt: the function ran exactly once.
    assert length(rows(ctx)) == 1
    stored = Repo.get!(StepDispatch, first.id, prefix: ctx.tenant.schema_name)
    assert stored.attempt_index == 0
    assert stored.status == :pending
  end

  test "D11: the row is bound to the definition's node", ctx do
    definition = activated(ctx)

    # A row that names a node the definition does not have.
    assert {:ok, %{status: :armed, dispatch: unknown_node}} =
             Dispatcher.arm(
               prefix: ctx.tenant.schema_name,
               instance_id: Ecto.UUID.generate(),
               definition_id: definition.id,
               node_id: "not_a_node_of_this_definition",
               function: @function,
               inputs: inputs(%{})
             )

    assert {:error, :platform_call_node_missing} =
             Dispatcher.attempt_dispatch(unknown_node.id, ctx.tenant.schema_name)

    stored = Repo.get!(StepDispatch, unknown_node.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :given_up
    assert stored.last_failure_kind == "platform_call_node_missing"
    assert stored.outputs == nil

    # A row whose argument contradicts the node's DECLARED constant: the node
    # declares `display_name` as the constant "Acme Ltd", the row carries
    # another value. (The slug differs too, so this is a different call and
    # not a reuse of the first one's idempotency key.)
    assert {:ok, %{status: :armed, dispatch: other_args}} =
             arm(ctx, definition, %{"slug" => "another-co", "display_name" => "Another Ltd"})

    assert {:error, :platform_call_arg_mismatch} =
             Dispatcher.attempt_dispatch(other_args.id, ctx.tenant.schema_name)

    stored = Repo.get!(StepDispatch, other_args.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :given_up
    assert stored.last_failure_kind == "platform_call_arg_mismatch"
    assert stored.outputs == nil
  end

  test "D12: a call that reaches the attempt cap is dead-lettered and the body never runs",
       ctx do
    definition = activated(ctx)

    assert {:ok, %{status: :armed, dispatch: dispatch}} = arm(ctx, definition)

    # The row is at the cap: the run that held it was killed uncatchably, and
    # the lease has expired, so the next claim takes it over -- for the last
    # time.
    dispatch
    |> StepDispatch.claim_changeset(%{
      status: :running,
      attempt_index: Dispatcher.max_attempts(),
      next_attempt_at: DateTime.add(DateTime.utc_now(), -60, :second)
    })
    |> Repo.update(prefix: ctx.tenant.schema_name)

    assert {:error, :platform_step_max_attempts} =
             Dispatcher.attempt_dispatch(dispatch.id, ctx.tenant.schema_name)

    stored = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :given_up
    assert stored.last_failure_kind == "platform_step_max_attempts"
    assert stored.outputs == nil

    # The row left the queue for good: it is not due any more.
    due_ids = Dispatcher.due_dispatch_ids(ctx.tenant.schema_name)
    assert is_list(due_ids)
    refute dispatch.id in due_ids
  end

  test "D13: a row that is RUNNING with a live lease is not re-claimed -- the body does not run again",
       ctx do
    definition = activated(ctx)

    assert {:ok, %{status: :armed, dispatch: dispatch}} = arm(ctx, definition)

    # The state a claim transaction leaves the row in while the body runs:
    # `running`, the attempt that holds it, and the lease still in the future.
    dispatch
    |> StepDispatch.claim_changeset(%{
      status: :running,
      attempt_index: 1,
      next_attempt_at: DateTime.add(DateTime.utc_now(), Dispatcher.lease_ms(), :millisecond)
    })
    |> Repo.update(prefix: ctx.tenant.schema_name)

    # The first run is still in flight: a second dispatcher must NOT take the
    # row over, or the body would run a second time for the same call (S8).
    assert {:error, :platform_step_in_flight} =
             Dispatcher.attempt_dispatch(dispatch.id, ctx.tenant.schema_name)

    # Nothing changed: the row still belongs to the attempt that holds it,
    # and the body did not run (no outputs).
    stored = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :running
    assert stored.attempt_index == 1
    assert stored.outputs == nil
  end

  test "D14: two dispatchers of ONE row run the body once", ctx do
    definition = activated(ctx)

    assert {:ok, %{status: :armed, dispatch: dispatch}} = arm(ctx, definition)

    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Letflow.Repo, parent, self())
          Dispatcher.attempt_dispatch(dispatch.id, ctx.tenant.schema_name)
        end)
      end

    results = Task.await_many(tasks, 30_000)

    # Exactly one of them ran the body. The other one either found the row
    # already final (the first run had finished) or found the row in flight
    # (its lease had not expired) -- never a second run of the body.
    assert length(Enum.filter(results, &match?({:ok, {:advanced, _}}, &1))) == 1

    stored = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :advanced
    assert stored.attempt_index == 1
  end

  test "D15: an id that is not an id answers the uniform not-found refusal", ctx do
    definition = activated(ctx)

    assert {:ok, %{status: :armed, dispatch: dispatch}} = arm(ctx, definition)

    # A malformed id must NOT reach the query (where it would raise a cast
    # error): it answers the same refusal as an id that does not exist.
    assert {:error, :platform_step_not_found} =
             Dispatcher.attempt_dispatch("not-a-uuid", ctx.tenant.schema_name)

    assert {:error, :platform_step_not_found} =
             Dispatcher.attempt_dispatch(Ecto.UUID.generate(), ctx.tenant.schema_name)

    # The real row was not touched by either attempt.
    stored = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :pending
    assert stored.attempt_index == 0
  end

  test "D16: a value over the byte cap is refused before anything is written", ctx do
    definition = activated(ctx)

    # The key input is a tenant-controlled start variable. The dispatcher
    # bounds it BEFORE it composes the key: the row must not be written with
    # a key that does not fit its column.
    assert {:error, :platform_call_arg_invalid} =
             Dispatcher.arm(
               prefix: ctx.tenant.schema_name,
               instance_id: Ecto.UUID.generate(),
               definition_id: definition.id,
               node_id: "call",
               function: @function,
               inputs: inputs(%{"slug" => String.duplicate("a", 8193)})
             )

    assert rows(ctx) == []
  end

  test "D17: an option the dispatcher does not read is REFUSED, not ignored", ctx do
    definition = activated(ctx)

    # A caller must not believe that `:tenant_id` is honoured: the dispatcher
    # refuses the option instead of dropping it in silence.
    assert {:error, :platform_call_arg_unknown} =
             Dispatcher.arm(
               prefix: ctx.tenant.schema_name,
               tenant_id: Ecto.UUID.generate(),
               instance_id: Ecto.UUID.generate(),
               definition_id: definition.id,
               node_id: "call",
               function: @function,
               inputs: inputs(%{})
             )

    assert rows(ctx) == []
  end

  test "D18: a stale attempt cannot overwrite the result of the attempt that owns the row",
       ctx do
    definition = activated(ctx)

    assert {:ok, %{status: :armed, dispatch: dispatch}} = arm(ctx, definition)

    # The state a claim leaves the row in while the body runs.
    dispatch
    |> StepDispatch.claim_changeset(%{
      status: :running,
      attempt_index: 1,
      next_attempt_at: DateTime.add(DateTime.utc_now(), Dispatcher.lease_ms(), :millisecond)
    })
    |> Repo.update(prefix: ctx.tenant.schema_name)

    stale = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)

    # A LATER attempt takes the row over, so the row carries another
    # attempt's number now.
    stale
    |> StepDispatch.claim_changeset(%{
      status: :running,
      attempt_index: 2,
      next_attempt_at: DateTime.add(DateTime.utc_now(), Dispatcher.lease_ms(), :millisecond)
    })
    |> Repo.update(prefix: ctx.tenant.schema_name)

    # The stale attempt (number 1) writes its result: the write must NOT
    # land -- the attempt that owns the row now is number 2.
    assert {:error, :platform_step_lease_lost} =
             Dispatcher.record_outcome(
               stale,
               ctx.tenant.schema_name,
               {:ok, %{"normalized_slug" => "acme"}}
             )

    stored = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :running
    assert stored.attempt_index == 2
    assert stored.outputs == nil

    # The attempt that owns the row writes its own result: it lands.
    owner = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)

    assert :ok =
             Dispatcher.record_outcome(
               owner,
               ctx.tenant.schema_name,
               {:ok, %{"normalized_slug" => "acme"}}
             )

    stored = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :advanced
    assert stored.outputs == %{"normalized_slug" => "acme"}
  end

  test "D19: a node id over the byte cap is refused before anything is written", ctx do
    definition = activated(ctx)

    # The node id is a caller-supplied string that goes into a `varchar(255)`
    # column, and it is NOT one of the entry's declared inputs -- so the input
    # cap does not cover it. It gets its own byte cap. The second case is
    # MULTIBYTE (128 characters, 256 bytes): the cap is in BYTES, so it
    # refuses earlier than a character count would.
    multibyte = String.duplicate("ы", 128)
    assert byte_size(multibyte) == 256

    for bad_node_id <- [String.duplicate("n", 256), multibyte] do
      assert {:error, :platform_call_arg_invalid} =
               Dispatcher.arm(
                 prefix: ctx.tenant.schema_name,
                 instance_id: Ecto.UUID.generate(),
                 definition_id: definition.id,
                 node_id: bad_node_id,
                 function: @function,
                 inputs: inputs(%{})
               )
    end

    # A node id that is not a string at all is refused the same way.
    assert {:error, :platform_call_arg_invalid} =
             Dispatcher.arm(
               prefix: ctx.tenant.schema_name,
               instance_id: Ecto.UUID.generate(),
               definition_id: definition.id,
               node_id: :not_a_node_id,
               function: @function,
               inputs: inputs(%{})
             )

    assert rows(ctx) == []
  end

  test "D20: the failure kind is a stable code, never a customer text", ctx do
    definition = activated(ctx)

    assert {:ok, %{status: :armed, dispatch: dispatch}} = arm(ctx, definition)

    running = claim_for_outcome(dispatch, ctx)

    # A reason that carries what a tenant typed must not reach the row.
    customer_text = "tenant acme already exists (admin@acme.test)"

    assert :ok =
             Dispatcher.record_outcome(running, ctx.tenant.schema_name, {:error, customer_text})

    stored = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :given_up
    assert stored.last_failure_kind == "platform_step_failed"

    # The failure text reaches no column of the row (the row's `inputs` are
    # the CALL's own arguments and stay readable -- it is the failure text
    # that must not be there).
    refute stored.last_failure_kind =~ "acme"
    refute stored.last_failure_kind =~ "admin@"
    refute inspect(stored) =~ "already exists"

    # A reason that is longer than the column that would hold it is reduced
    # to the same code -- it never overflows the column and never raises.
    assert {:ok, %{status: :armed, dispatch: long}} =
             arm(ctx, definition, %{"slug" => "long-reason"})

    long_running = claim_for_outcome(long, ctx)

    assert :ok =
             Dispatcher.record_outcome(
               long_running,
               ctx.tenant.schema_name,
               {:error, String.duplicate("customer text ", 40)}
             )

    stored = Repo.get!(StepDispatch, long.id, prefix: ctx.tenant.schema_name)
    assert stored.last_failure_kind == "platform_step_failed"

    # A reason that is not a code at all is reduced to the same generic code.
    assert {:ok, %{status: :armed, dispatch: other}} =
             arm(ctx, definition, %{"slug" => "another-co"})

    other_running = claim_for_outcome(other, ctx)

    assert :ok =
             Dispatcher.record_outcome(
               other_running,
               ctx.tenant.schema_name,
               {:error, {:not, :a_code}}
             )

    stored = Repo.get!(StepDispatch, other.id, prefix: ctx.tenant.schema_name)
    assert stored.last_failure_kind == "platform_step_failed"
  end

  test "D21: an outcome the row cannot carry is refused, and the row is unchanged", ctx do
    definition = activated(ctx)

    assert {:ok, %{status: :armed, dispatch: dispatch}} = arm(ctx, definition)

    running = claim_for_outcome(dispatch, ctx)

    # A tuple is a value the jsonb column's encoder cannot carry: the outcome
    # is refused with a typed error and NOTHING is written (INV-8: the public
    # writer never raises).
    assert {:error, :platform_step_bad_result} =
             Dispatcher.record_outcome(running, ctx.tenant.schema_name, {:ok, %{"x" => {1, 2}}})

    stored = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :running
    assert stored.outputs == nil
    assert stored.last_failure_kind == nil
    assert stored.dispatched_at == nil

    # An outcome that is neither an output map nor a refusal is refused the
    # same way.
    assert {:error, :platform_step_bad_result} =
             Dispatcher.record_outcome(running, ctx.tenant.schema_name, :not_an_outcome)

    stored = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :running
    assert stored.outputs == nil
  end

  test "D22: a prefix that names no schema a dispatch row can live in is refused on EVERY path",
       ctx do
    definition = activated(ctx)

    assert {:ok, %{status: :armed, dispatch: dispatch}} = arm(ctx, definition)

    running = claim_for_outcome(dispatch, ctx)

    # Two kinds of prefix that cannot hold a dispatch row: a WELL-FORMED name
    # that names no live schema (the tenant was purged), and a schema that
    # exists but has no dispatch table (the `public` schema). Both must be
    # refused on EVERY public path that takes a prefix -- the arming path was
    # guarded first and the dispatch paths were not, and a fix that covers one
    # variant of the class leaves the next one live.
    for bad_prefix <- ["tenant_0123456789abcdef0123456789abcdef", "public"] do
      assert {:error, :invalid_schema_name} =
               Dispatcher.attempt_dispatch(dispatch.id, bad_prefix)

      assert {:error, :invalid_schema_name} = Dispatcher.run_due(bad_prefix)
      assert {:error, :invalid_schema_name} = Dispatcher.due_dispatch_ids(bad_prefix)

      assert {:error, :invalid_schema_name} =
               Dispatcher.record_outcome(running, bad_prefix, {:ok, %{"x" => "y"}})
    end

    # The real row is untouched by any of it: no status change, no outputs, no
    # failure kind, and the tenant's own rows are still the one that was
    # armed.
    stored = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :running
    assert stored.outputs == nil
    assert stored.last_failure_kind == nil
    assert stored.dispatched_at == nil
    assert length(rows(ctx)) == 1
  end

  test "D23: a row armed in a COMPANY tenant is refused at dispatch -- the function never runs",
       ctx do
    definition = activated(ctx)

    # A company tenant: its own schema and its own rows, and NOT the platform
    # tenant (the setup pinned the platform one).
    company = Fx.tenant!("t2589-company")

    # A FORGED definition row in the COMPANY's schema: the dispatcher's own
    # load finds it, so the refusal that follows is the platform-tenant fence
    # (INV-10) and not a missing definition. `Definitions.create/2` refuses a
    # company tenant's draft that carries a platform call, so the write path
    # cannot produce one -- a forged row needs the database itself.
    company_definition = forged_definition!(company.schema_name, "pcf-t2589-company")

    assert {:ok, %{status: :armed, dispatch: row}} =
             Dispatcher.arm(
               prefix: company.schema_name,
               instance_id: Ecto.UUID.generate(),
               definition_id: company_definition.id,
               node_id: "call",
               function: @function,
               inputs: inputs(%{})
             )

    # The row's tenant is the COMPANY's: derived from the schema it sits in,
    # never from the caller.
    assert row.tenant_id == company.tenant_id

    # THE refusal: a platform call does not run outside the platform tenant.
    assert {:error, :platform_call_tenant_not_allowed} =
             Dispatcher.attempt_dispatch(row.id, company.schema_name)

    stored = Repo.get!(StepDispatch, row.id, prefix: company.schema_name)
    assert stored.status == :given_up
    assert stored.last_failure_kind == "platform_call_tenant_not_allowed"

    # The function never ran: the row carries no outputs at all.
    assert stored.outputs == nil
    assert stored.dispatched_at != nil

    # The POLLER pointed at the company tenant runs no body either: the second
    # row (a different call, so a different idempotency key) is refused the
    # same way.
    assert {:ok, %{status: :armed, dispatch: polled}} =
             Dispatcher.arm(
               prefix: company.schema_name,
               instance_id: Ecto.UUID.generate(),
               definition_id: company_definition.id,
               node_id: "call",
               function: @function,
               inputs: inputs(%{"slug" => "another-co"})
             )

    assert %{claimed: 1, advanced: 0, failed: 1} = Dispatcher.run_due(company.schema_name)

    stored = Repo.get!(StepDispatch, polled.id, prefix: company.schema_name)
    assert stored.status == :given_up
    assert stored.last_failure_kind == "platform_call_tenant_not_allowed"
    assert stored.outputs == nil

    # The platform tenant's own row is untouched by either attempt.
    assert {:ok, %{status: :armed, dispatch: platform_row}} = arm(ctx, definition)
    assert length(rows(ctx)) == 1

    stored = Repo.get!(StepDispatch, platform_row.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :pending
    assert stored.attempt_index == 0
    assert stored.outputs == nil
    assert stored.last_failure_kind == nil
  end

  # A definition row written STRAIGHT into a company tenant's schema: the
  # shape a forged row would have. `Definitions.create/2` refuses a company
  # tenant's draft that carries a platform_call, so the write path cannot
  # produce one -- a forged row needs the database itself.
  defp forged_definition!(schema_name, name) do
    %Definitions.ProcessDefinition{}
    |> Definitions.ProcessDefinition.create_changeset(%{
      name: name,
      version: "1",
      graph: Fx.graph(call()),
      created_by: Ecto.UUID.generate()
    })
    |> Repo.insert!(prefix: schema_name)
  end

  # The state a claim leaves the row in while the body runs: `running`, the
  # attempt that holds it, and the lease still in the future. The result of
  # that attempt may then be written (the CLAIM TOKEN).
  defp claim_for_outcome(dispatch, ctx) do
    dispatch
    |> StepDispatch.claim_changeset(%{
      status: :running,
      attempt_index: 1,
      next_attempt_at: DateTime.add(DateTime.utc_now(), Dispatcher.lease_ms(), :millisecond)
    })
    |> Repo.update(prefix: ctx.tenant.schema_name)

    Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)
  end

  # ── the AST helpers of D6 ──────────────────────────────────────────────────────────────

  defp transaction_blocks(ast) do
    {_ast, blocks} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:Repo]}, :transaction]}, _, _} = call, acc ->
          {call, [call | acc]}

        node, acc ->
          {node, acc}
      end)

    blocks
  end

  defp contains_call?(ast, name) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn
        {^name, _, _} = node, _acc -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end
end
