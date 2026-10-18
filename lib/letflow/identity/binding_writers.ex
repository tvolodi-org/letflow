defmodule Letflow.Identity.BindingWriters do
  @moduledoc """
  The registry of every binding / grant-row writer and what each does in a tenant whose scope
  enforcement is `on` (REQ-519 2e-a, GH #2535, design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` section 3.4, AC 1).

  DATA ONLY: no DB access, no side effects. Two kinds of row:

    * SCANNED rows (`binding_rows/0` entries with a `:site`) are keyed by the CALL SITE of one
      of the six entry points the completeness scan looks for (`entry_points/0`): the only
      ways a binding's grant row is written or removed. A call site that is not registered
      here is an unclassified writer, and the scan test fails.
    * INDIRECT rows (`indirect: true`) name a writer that reaches a scanned site through
      `upsert_role/4`, `rebind_role/4`, the seeding or the HTTP route. They are not subject to
      the completeness scan; a second check asserts each named function still exists and still
      reaches a scanned site.

  The states: `:refused` (the write is refused with `scope_required`, a `binding.refused`
  audit entry follows the rollback), `:no_row` (the binding is written without a grant row and
  the skip is reported), `:unchanged` (removal or a move that never widens; behaviour is the
  same in every mode).
  """

  @type state :: :refused | :no_row | :unchanged
  @type transition ::
          :nil_to_p | :not_p_to_p | :p_to_p_same | :p_to_p_other | :p_to_not_p | :p_to_nil | :none
  # No positional index: a file may hold several call sites in one function; the scan compares
  # the MULTISET of {file, function}, and the registry list order is the documentation order.
  @type site :: %{file: String.t(), function: {atom(), arity()}}
  @type row :: %{
          id: atom(),
          site: site() | nil,
          indirect: boolean(),
          transition: transition(),
          state: state(),
          why: String.t()
        }

  @role_registry "lib/letflow/identity/role_registry.ex"
  @tam "lib/letflow/identity/tenant_admin_migration.ex"
  @backfill "lib/letflow/identity/role_scope_grants/backfill.ex"
  @identity "lib/letflow/identity.ex"
  @mix_task "lib/mix/tasks/letflow.backfill_role_scope_grants.ex"
  @router "lib/letflow/routers/identity.ex"

  @entry_points [
    {:reconcile_binding!, 3},
    {:ensure_tenant_wide_group_row!, 3},
    {:repair_group_row!, 3},
    {:move_group_rows!, 4},
    {:delete_group_principal_rows!, 2},
    {:run, 1}
  ]

  @doc "The six scanned entry points as `{function, arity}` (`run/1` is `Backfill.run/1`)."
  @spec entry_points() :: [{atom(), arity()}]
  def entry_points, do: @entry_points

  @doc "Every writer row (scanned and indirect), in registry order."
  @spec binding_rows() :: [row()]
  def binding_rows do
    [
      scanned(:w_a, @role_registry, {:insert_role, 6}, :nil_to_p, :refused, "new binding"),
      scanned(
        :w_b,
        @role_registry,
        {:converge_existing_role, 5},
        :not_p_to_p,
        :refused,
        "routing binding becomes platform (also p_to_not_p, which is unchanged: removal)"
      ),
      scanned(
        :w_c1,
        @role_registry,
        {:converge_existing_role, 5},
        :p_to_p_same,
        :no_row,
        "repair of a binding with no row"
      ),
      scanned(
        :w_c2,
        @role_registry,
        {:ensure_platform_role_binding, 2},
        :p_to_p_same,
        :no_row,
        "seeding repair"
      ),
      scanned(
        :w_c3,
        @tam,
        {:ensure_binding, 2},
        :p_to_p_same,
        :no_row,
        "unreachable in on through real_tenant (tenant skipped)"
      ),
      scanned(
        :w_d,
        @role_registry,
        {:move_role, 6},
        :p_to_p_other,
        :unchanged,
        "rows follow the binding; zero rows moved is NO-ROW (reported)"
      ),
      scanned(
        :w_e,
        @backfill,
        {:repair_rows!, 3},
        :p_to_p_same,
        :no_row,
        "an on tenant is skipped before this site (skipped_enforced)"
      ),
      scanned(
        :w_e2,
        @mix_task,
        {:run, 1},
        :none,
        :no_row,
        "Backfill.run: per-tenant skipped_enforced, never an error"
      ),
      scanned(
        :w_f1,
        @tam,
        {:remove_legacy_binding, 2},
        :p_to_nil,
        :unchanged,
        "removal never widens"
      ),
      scanned(
        :w_f2,
        @identity,
        {:delete_group, 2},
        :p_to_nil,
        :unchanged,
        "removal never widens"
      ),
      indirect(
        :w_g1,
        @role_registry,
        {:ensure_platform_role_binding, 2},
        :nil_to_p,
        :no_row,
        "seeding nil branch: binding created WITHOUT a row, audit key rows=skipped_enforced"
      ),
      indirect(
        :w_g2,
        @tam,
        {:ensure_binding, 2},
        :nil_to_p,
        :no_row,
        "TAM nil branch: the whole tenant is skipped (skipped_enforced)"
      ),
      indirect(
        :w_h,
        @router,
        {:upsert_role, 5},
        :nil_to_p,
        :refused,
        "POST /roles: 409 scope_required"
      )
    ]
  end

  defp scanned(id, file, function, transition, state, why) do
    %{
      id: id,
      site: %{file: file, function: function},
      indirect: false,
      transition: transition,
      state: state,
      why: why
    }
  end

  defp indirect(id, file, function, transition, state, why) do
    %{
      id: id,
      site: %{file: file, function: function},
      indirect: true,
      transition: transition,
      state: state,
      why: why
    }
  end
end
