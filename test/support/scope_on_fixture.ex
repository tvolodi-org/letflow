defmodule Letflow.Support.ScopeOnFixture do
  @moduledoc """
  Test-only helpers shared by the REQ-517 / GH #2535 PR 2b tests that exercise the `on` stored
  mode (design `lib/letflow/design/req517-scoped-grants-admin-plane.md` sections 4.2 to 4.6; spec
  `test/specs/REQ-517-2b.md`): callers whose TENANT_ADMIN role is held in different shapes
  (tenant-wide through the default group row, only through a scoped row, through no row at all),
  the `auth_context` carrying the per-request enforcement mode, and a collector for the
  `[:letflow, :scope, :enforce, :denied]` telemetry event `Letflow.Api.Scope.Enforce` emits on a
  deny.

  Everything builds on `Letflow.Support.ScopedGrantsFixture` (a dedicated provisioned tenant with
  the default platform-role groups seeded and a tenant-wide TENANT_ADMIN under `fx.admin`).
  Callers are `async: false` (committed writes, VM-global telemetry handlers).
  """

  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopedGrantsFixture, as: S
  alias Letflow.Support.ScopeEnforcementFixture

  @enforce_denied [:letflow, :scope, :enforce, :denied]

  @type fixture :: map()
  @type mode :: :off | :shadow | :on

  @doc "The telemetry event emitted by `Letflow.Api.Scope.Enforce` on a deny."
  @spec enforce_denied_event() :: [atom()]
  def enforce_denied_event, do: @enforce_denied

  @doc """
  A user who is NOT a member of any group and holds `role` only through ONE scoped user row (a
  fresh root node): the `{:nodes, [node]}` shape, i.e. `{:deny, :not_tenant_wide}` on a
  tenant-wide resource. Returns the user.
  """
  @spec scoped_holder!(fixture(), String.t()) :: Letflow.Identity.User.t()
  def scoped_holder!(fx, role) do
    user = RSG.user!(fx.schema_name)
    node = RSG.node!(fx.schema_name)
    :ok = RSG.raw_user_row!(fx.schema_name, user.id, role, node)
    user
  end

  @doc """
  A user who claims `role` (the context says so) but has no group membership and no row at all:
  `{:deny, :no_grant_rows}` under `on`.
  """
  @spec rowless_holder!(fixture()) :: Letflow.Identity.User.t()
  def rowless_holder!(fx), do: RSG.user!(fx.schema_name)

  @doc "An `:oidc` `auth_context` of a real user carrying the per-request enforcement `mode`."
  @spec ctx(fixture(), Ecto.UUID.t(), [String.t()], mode()) :: map()
  def ctx(fx, user_id, roles, mode) do
    fx |> S.ctx(user_id, roles, :oidc) |> Map.put(:scope_enforcement, mode)
  end

  @doc "Dispatches one request into `router` as `user_id` holding `roles`, with `mode` in the context."
  @spec call(
          module(),
          atom(),
          String.t(),
          fixture(),
          Ecto.UUID.t(),
          [String.t()],
          mode(),
          map() | nil
        ) ::
          Plug.Conn.t()
  def call(router, method, path, fx, user_id, roles, mode, body) do
    S.call(router, method, path, fx, ctx(fx, user_id, roles, mode), body)
  end

  @doc "Stores `mode` in the tenant row (`ScopeEnforcementFixture`), the only way to reach `on`."
  @spec store_mode!(fixture(), mode()) :: :ok
  def store_mode!(fx, mode), do: ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, mode)

  @doc false
  @spec handle_event([atom()], map(), map(), {pid(), reference()}) :: :ok
  def handle_event(_event, measurements, metadata, {pid, ref}) do
    send(pid, {:enforce_denied, ref, measurements, metadata})
    :ok
  end

  @doc """
  Attaches a collector for the `Enforce` deny event in the calling test (detached on exit);
  returns the reference `drain/1` filters on.
  """
  @spec attach_enforce_denied!() :: reference()
  def attach_enforce_denied! do
    ref = make_ref()

    :telemetry.attach(
      {__MODULE__, ref},
      @enforce_denied,
      &__MODULE__.handle_event/4,
      {self(), ref}
    )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end

  @doc "Every `{measurements, metadata}` collected so far for `ref`, oldest first; empties the mailbox of them."
  @spec drain(reference()) :: [{map(), map()}]
  def drain(ref), do: drain(ref, [])

  defp drain(ref, acc) do
    receive do
      {:enforce_denied, ^ref, measurements, metadata} ->
        drain(ref, [{measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
