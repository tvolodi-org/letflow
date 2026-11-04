defmodule Letflow.LedgerFixture do
  @moduledoc """
  REQ-621 / GH #3469 part A: the neutral TEST registration and the helpers of the ledger posting
  tests. Lives in `test/support`, not `lib/`, so the neutral-vocabulary scan and the table-name
  scan do not see it. No production module builds a capability in this slice; the tests build the
  struct literal here.

  Every test using this module is `async: false` and runs in Sandbox `:auto` mode (real commits):
  call `setup_auto_mode!/0` from `setup`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Letflow.EntityWritesFixture
  alias Letflow.Ledger
  alias Letflow.Ledger.Capability
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.Test.SandboxAutoMode

  @ledger_id "test_ledger"

  def ledger_id, do: @ledger_id

  @doc "Sandbox `:auto` for the test, restored on exit."
  def setup_auto_mode! do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    :ok
  end

  @doc "A committed tenant; returns its schema name. Dropped on exit."
  @spec tenant!() :: String.t()
  def tenant! do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "ledger", teardown: false)
    on_exit(fn -> EntityWritesFixture.drop_committed_tenant!(tenant.tenant_id) end)
    tenant.schema_name
  end

  @doc """
  The test registration (shape of note 14.3 restricted to slots, causes, key_bounds, units,
  max_event_lateness_hours). Options: `:key_bounds`, `:units`.
  """
  @spec registration(keyword()) :: map()
  def registration(opts \\ []) do
    %{
      slots: [
        %{name: "k_primary", format: :token, required: true},
        %{name: "k_second", format: :token, required: false},
        %{name: "k_third", format: :token, required: false}
      ],
      causes: %{
        "receipt" => %{sign_rule: :positive, reason_required: false},
        "issue" => %{sign_rule: :negative, reason_required: false},
        "transfer" => %{sign_rule: :zero_sum_by_slot_1, reason_required: false},
        "adjust" => %{sign_rule: :any, reason_required: false}
      },
      key_bounds: Keyword.get(opts, :key_bounds, []),
      units: Keyword.get(opts, :units),
      max_event_lateness_hours: 96
    }
  end

  @doc "A declared leg."
  def leg(k, quantity, unit \\ "u1", extra \\ %{}) do
    Map.merge(
      %{k: k, quantity: dec(quantity), unit_ref: unit, attrs: nil, document_line_id: nil},
      extra
    )
  end

  def dec(%Decimal{} = d), do: d
  def dec(n) when is_integer(n), do: Decimal.new(n)
  def dec(s) when is_binary(s), do: Decimal.new(s)
  def dec(other), do: other

  @doc "The capability struct literal for `cause` and `legs`."
  @spec capability(String.t(), String.t(), [map()], keyword()) :: Capability.t()
  def capability(schema, cause, legs, opts \\ []) do
    unique = System.unique_integer([:positive])

    %Capability{
      prefix: schema,
      registration_name: "test",
      registration: Keyword.get_lazy(opts, :registration, &registration/0),
      command: Map.merge(%{client_op_id: "op-#{unique}"}, Keyword.get(opts, :command, %{})),
      posting:
        Map.merge(
          %{ledger_id: Keyword.get(opts, :ledger_id, @ledger_id), cause: cause, legs: legs},
          Keyword.get(opts, :posting, %{})
        ),
      subject_id: Keyword.get(opts, :subject_id, Ecto.UUID.generate()),
      actor_id: Ecto.UUID.generate(),
      origin_key: Keyword.get(opts, :origin_key, "origin-#{unique}")
    }
  end

  @doc """
  Runs `Ledger.post/1` in a transaction. A refusal rolls the transaction back (as the L3 Multi
  will), so it leaves nothing: returns `{:ok, posted}` or `{:error, refusal}`.
  """
  @spec post_tx(Capability.t()) :: {:ok, map()} | {:error, term()}
  def post_tx(%Capability{} = cap) do
    Repo.transaction(fn ->
      case Ledger.post(cap) do
        {:ok, posted} -> posted
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Posts and returns the posted map; raises on a refusal."
  def post!(%Capability{} = cap) do
    {:ok, posted} = post_tx(cap)
    posted
  end

  @doc """
  A reversal capability for `target_id` (REQ-637 part A). The target and reason are also put in
  the command, so a changed target is `idempotency_key_reuse`. Options as `capability/4` plus
  `:reason` (default "r1"); `:posting` is merged over the reversal posting.
  """
  @spec reversal_capability(String.t(), String.t() | nil, keyword()) :: Capability.t()
  def reversal_capability(schema, target_id, opts \\ []) do
    {reason, opts} = Keyword.pop(opts, :reason, "r1")

    posting =
      Map.merge(
        %{reverses_entry_id: target_id, reason_code: reason},
        Keyword.get(opts, :posting, %{})
      )

    command =
      Map.merge(%{reverses: target_id, reason: reason}, Keyword.get(opts, :command, %{}))

    capability(schema, "reversal", [], Keyword.merge(opts, posting: posting, command: command))
  end

  @doc "The entry row of `entry_id` as a map (columns used by the reversal tests)."
  def entry_row(schema, entry_id) do
    %{rows: [row]} =
      Repo.query!(
        ~s|SELECT cause, sign_rule, reverses_entry_id::text, ledger_id, posting_seq, reason_code, document_type, document_id, correlation_id, chain_hash, entry_digest FROM "#{schema}".ledger_entry WHERE id = $1|,
        [Ecto.UUID.dump!(entry_id)]
      )

    keys =
      ~w(cause sign_rule reverses_entry_id ledger_id posting_seq reason_code document_type document_id correlation_id chain_hash entry_digest)a

    Map.new(Enum.zip(keys, row))
  end

  @doc "The legs of `entry_id` ordered by leg_no: `{leg_no, [k1..k8], quantity, unit_ref, attrs}`."
  def leg_rows(schema, entry_id) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT leg_no, ARRAY[k1,k2,k3,k4,k5,k6,k7,k8], quantity, unit_ref, attrs FROM "#{schema}".ledger_leg WHERE entry_id = $1 ORDER BY leg_no|,
        [Ecto.UUID.dump!(entry_id)]
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  @doc "Sum of `on_hand` over every balance row of `ledger_id` (one SQL aggregate)."
  def total_on_hand(schema, ledger_id \\ @ledger_id) do
    %{rows: [[total]]} =
      Repo.query!(
        ~s|SELECT COALESCE(sum(on_hand), 0) FROM "#{schema}".ledger_balance WHERE ledger_id = $1|,
        [ledger_id]
      )

    total
  end

  @doc "Seeds `quantity` on_hand for `k` by posting a receipt through `post/1`."
  def seed_on_hand!(schema, k, quantity, opts \\ []) do
    post!(capability(schema, "receipt", [leg(k, quantity)], opts))
  end

  @doc "Inserts an empty balance row directly (the L1 trigger only accepts on_hand 0)."
  def insert_balance!(schema, k, unit, max_on_hand) do
    [k1, k2, k3, k4, k5, k6, k7, k8] = pad(k)

    Repo.query!(
      ~s|INSERT INTO "#{schema}".ledger_balance (ledger_id, k1, k2, k3, k4, k5, k6, k7, k8, on_hand, unit_ref, max_on_hand, last_posting_seq) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 0, $10, $11, 0)|,
      [@ledger_id, k1, k2, k3, k4, k5, k6, k7, k8, unit, dec(max_on_hand)]
    )

    :ok
  end

  def pad(k), do: k ++ List.duplicate("", 8 - length(k))

  @doc "The balance row of `k` as a map, or nil."
  def balance(schema, k) do
    [k1, k2, k3, k4, k5, k6, k7, k8] = pad(k)

    %{rows: rows} =
      Repo.query!(
        ~s|SELECT on_hand, unit_ref, max_on_hand, last_posting_seq FROM "#{schema}".ledger_balance WHERE ledger_id = $1 AND k1 = $2 AND k2 = $3 AND k3 = $4 AND k4 = $5 AND k5 = $6 AND k6 = $7 AND k7 = $8 AND k8 = $9|,
        [@ledger_id, k1, k2, k3, k4, k5, k6, k7, k8]
      )

    case rows do
      [[on_hand, unit, max, seq]] ->
        %{on_hand: on_hand, unit_ref: unit, max_on_hand: max, last_posting_seq: seq}

      [] ->
        nil
    end
  end

  @doc "`last_seq` of the ledger counter (0 when there is no row)."
  def last_seq(schema, ledger_id \\ @ledger_id) do
    case Repo.query!(~s|SELECT last_seq FROM "#{schema}".ledger_counter WHERE ledger_id = $1|, [
           ledger_id
         ]) do
      %{rows: [[seq]]} -> seq
      %{rows: []} -> 0
    end
  end

  @doc "An authorized value as part B will mint it (REQ-637 part C builds the literal)."
  def authorized(schema, purpose \\ :reconcile, ledger_id \\ @ledger_id) do
    %Ledger.Authorized{
      prefix: schema,
      ledger_id: ledger_id,
      registration_name: "test",
      purpose: purpose,
      slot_names: Enum.map(registration().slots, & &1.name)
    }
  end

  @doc "Every result of a reconciliation run, chunk by chunk (stops on an error tuple)."
  def reconcile_chunks(authorized, opts \\ %{}) do
    case Ledger.reconcile(authorized, opts) do
      {:ok, %{next_cursor: nil} = result} ->
        [result]

      {:ok, %{next_cursor: cursor} = result} ->
        [result | reconcile_chunks(authorized, Map.put(opts, :cursor, cursor))]

      {:error, _} = error ->
        [error]
    end
  end

  @doc "The last result of a run with the mismatches of all its chunks."
  def reconcile_all(authorized, opts \\ %{}) do
    case reconcile_chunks(authorized, opts) do
      [{:error, _} = error] ->
        error

      results ->
        last = List.last(results)
        {:ok, %{last | mismatches: Enum.flat_map(results, & &1.mismatches)}}
    end
  end

  @doc "True when the connection role owns the ledger tables (owner-tamper tests need it)."
  def table_owner?(schema) do
    %{rows: rows} =
      Repo.query!(
        "SELECT tableowner = current_user FROM pg_tables WHERE schemaname = $1 AND tablename = 'ledger_entry'",
        [schema]
      )

    rows == [[true]]
  end

  @doc "Disables the user triggers of a ledger table as its owner (residual D-L2a of decision 0073)."
  def disable_guards!(schema, table) when table in ~w(ledger_entry ledger_leg ledger_counter) do
    Repo.query!(~s|ALTER TABLE "#{schema}".#{table} DISABLE TRIGGER USER|)
    :ok
  end

  @doc "Runs a statement as the table owner with its bound parameters (test tampering)."
  def exec!(sql, params \\ []), do: Repo.query!(sql, params)

  @doc "Row count of a ledger table in `schema`."
  def count(schema, table)
      when table in ~w(ledger_entry ledger_leg ledger_counter ledger_balance) do
    %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}".#{table}|)
    n
  end

  @doc """
  Runs `fun` and returns `{result, statements}`: every SQL text the repo ran in the calling
  process while it ran, as `{sql, params}`.
  """
  def record(fun) do
    id = {__MODULE__, make_ref()}
    me = self()

    :ok =
      :telemetry.attach(
        id,
        Repo.config()[:telemetry_prefix] ++ [:query],
        fn _event, _measure, meta, _config ->
          if self() == me, do: send(me, {:stmt, id, meta.query, meta.params})
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain(id, [])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain(id, acc) do
    receive do
      {:stmt, ^id, sql, params} -> drain(id, [{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ---- read side (REQ-637 part B) --------------------------------------------------------------

  @doc """
  The test registry value of `Ledger.registration_for/1`: the test ledger id with the test
  registration and two EXISTING tenant-scope permission atoms (read: TENANT_ADMIN and
  PROCESS_DESIGNER; reconcile: TENANT_ADMIN only).
  """
  def registry do
    %{
      @ledger_id => %{
        name: "test",
        registration: registration(),
        read_permission: :ScriptsWrite,
        reconcile_permission: :ScriptsPublish
      }
    }
  end

  @doc "Installs `registry` (default `registry/0`) as the ledger registry for the test; restored on exit."
  def put_registry!(registry \\ registry()) do
    previous = Application.fetch_env(:letflow, :ledger_registry)
    Application.put_env(:letflow, :ledger_registry, registry)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:letflow, :ledger_registry, value)
        :error -> Application.delete_env(:letflow, :ledger_registry)
      end
    end)

    :ok
  end

  @doc "A committed tenant with the default role groups seeded; returns `%{tenant_id, schema_name}`."
  def tenant_fixture! do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "ledger", teardown: false)
    on_exit(fn -> EntityWritesFixture.drop_committed_tenant!(tenant.tenant_id) end)

    {:ok, _roles} =
      Letflow.Identity.RoleRegistry.seed_default_platform_role_groups(prefix: tenant.schema_name)

    tenant
  end

  @doc "A real active user of the tenant holding `roles` by group membership."
  def user!(fx, roles),
    do: Letflow.Support.TokenMintFixture.role_holder!(fx.schema_name, roles)

  @doc "A conn as the auth plug leaves it for `user` (claiming `roles`) with `credential`."
  def conn_for(fx, user, roles, credential \\ :oidc) do
    :get
    |> Plug.Test.conn("/")
    |> Plug.Conn.assign(:auth_context, %{
      user_id: user.id,
      tenant_id: fx.tenant_id,
      roles: roles,
      credential: credential
    })
    |> Plug.Conn.assign(:scoped_opts, prefix: fx.schema_name)
  end

  @doc "Writes `settings` (string keys) straight into the tenant record, past the settings cast."
  def put_tenant_settings!(fx, settings) do
    Repo.query!("UPDATE tenants SET settings = $1 WHERE id = $2", [
      settings,
      Ecto.UUID.dump!(fx.tenant_id)
    ])

    :ok
  end

  @doc "An `Authorized` value for `fx` built through `Ledger.authorize/3` as a TENANT_ADMIN."
  def authorized!(fx, purpose \\ :read) do
    user = user!(fx, ["TENANT_ADMIN"])
    {:ok, auth} = Ledger.authorize(conn_for(fx, user, ["TENANT_ADMIN"]), @ledger_id, purpose)
    auth
  end
end
