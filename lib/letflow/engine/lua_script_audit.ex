defmodule Letflow.Engine.LuaScriptAudit do
  @moduledoc """
  REQ-058 (LUA-07) -- the Lua script execution audit table, RETIRED by GH 2534 PR 7c-1
  (advisor Q11, decision C17; design `lib/letflow/design/gh2534-7c-script-handler.md`
  sections 3.2 and 10).

  Its only writer, `execute_script_for_audit/6`, had no production caller and has been
  removed: tenant-script runs are recorded per run on the instance stream instead
  (`SCRIPT_RUN_RECORDED`, built by `Letflow.Engine.ScriptTaskDispatcher.RunRecord`). The
  tenant table `lua_script_execution_audit` stays as READ-ONLY history: a ROW trigger
  (migration `20261015100002_lua_script_audit_read_only`) refuses every INSERT, UPDATE and
  DELETE with SQLSTATE `LF001`. There is deliberately no TRUNCATE trigger (the pooled
  test-schema reset depends on TRUNCATE, exactly as for `audit_entries`).

  Kept:

    * `AuditRecord` -- the read schema for the existing history rows (its
      `insert_changeset/2` is kept only so a dedicated test can seed history before the
      read-only migration runs; no `lib/` code inserts).
    * `Executor` -- the behaviour the concrete Lua executor module still implements.
  """

  defmodule AuditRecord do
    @moduledoc """
    `Ecto.Schema` for the `lua_script_execution_audit` table (design §3). Schema-per-tenant
    — no `@schema_prefix`; every `Repo` call passes `prefix:` explicitly (design §3, §5).
    No `tenant_id` column (Decision 0006 D2 — the per-tenant Postgres schema boundary
    alone provides tenant isolation).
    """

    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "lua_script_execution_audit" do
      field(:instance_id, Ecto.UUID)
      field(:manifest_hash, :string)
      field(:actor_id, Ecto.UUID)
      field(:executed_at, :utc_datetime_usec, read_after_writes: true)

      timestamps(type: :utc_datetime_usec)
    end

    @type t :: %__MODULE__{}

    @doc """
    Structural changeset for the single insert this module ever performs (design §3). Does
    no I/O.
    """
    @spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
    def insert_changeset(record, attrs) do
      record
      |> cast(attrs, [:instance_id, :manifest_hash, :actor_id])
      |> validate_required([:instance_id, :manifest_hash, :actor_id])
    end
  end

  defmodule Executor do
    @moduledoc """
    Injected script-execution dependency (design §4). Implementations are ordinary
    modules `use`ing `@behaviour Letflow.Engine.LuaScriptAudit.Executor`, passed to
    `execute_script_for_audit/6` as a plain module atom — never resolved via
    `Application.get_env/2`. No default/no-op implementation ships in this file; S5
    builds the real one, TEST-DESIGNER builds its own test-double module(s).
    """

    @typedoc """
    Deliberately opaque — decision 0014 adopted tv-labs/lua (pure-BEAM Lua 5.3, no NIF),
    but the concrete script-ref shape (body string, compiled bytecode, file path, etc.)
    remains an implementation detail of the real Executor. Pinning a concrete type here
    would constrain a decision that belongs to the Executor module.
    """
    @type script_ref :: term()

    @type manifest_result :: %{manifest_hash: String.t()}

    @doc """
    Executes `script_ref` and reports the manifest hash it produced.
    (The removed `execute_script_for_audit/6` compared the returned `manifest_hash`
    against its caller-supplied `registered_hash`; GH 2534 7c-1 retired that writer.)
    """
    @callback execute_with_manifest(script_ref(), registered_hash :: String.t()) ::
                {:ok, manifest_result()} | {:error, term()}
  end
end
