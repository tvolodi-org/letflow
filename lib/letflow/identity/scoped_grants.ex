defmodule Letflow.Identity.ScopedGrants do
  @moduledoc """
  The write service behind the org-scoped role grant admin plane (REQ-517 / GH #2535 PR 2a,
  decision 0051 D1/D8/D11; design `lib/letflow/design/req517-scoped-grants-admin-plane.md`
  sections 3.3 to 3.11). `Letflow.Routers.TenantRoleScopeGrants` parses and maps errors; this
  module validates, runs the transaction, applies the guards and writes the audit entry.

  It never touches the grants table itself: every table access goes through
  `Letflow.Identity.RoleScopeGrants` (the single writer, `mix
  letflow.check_role_scope_grants_writers`), its reads of the identity tables go through
  `Letflow.Identity` read functions, and locks are taken through
  `Letflow.Identity.lock_tenant_admins!/1` (rank A, ALWAYS the first statement of a write),
  `Letflow.Identity.TenantAdminGuard.lock_admin_binding!/1` (rank R, TENANT_ADMIN rows only)
  and `Letflow.ScopeNodePaths.lock_active_node_for_share!/2` (rank N).

  Every write is ONE transaction that also writes its `grant.*` audit entry (an audit failure
  rolls the row back). Refusals roll the transaction back; the refusal events
  (`tenant_admin.guard_refused`, `grant.self_grant_refused`) are written afterwards in their
  OWN transaction and never raise. Bodies are parsed field by field; unknown keys are
  `:invalid_body`.
  """

  alias Letflow.Api.Authorization
  alias Letflow.Api.Pagination
  alias Letflow.Audit
  alias Letflow.Identity
  alias Letflow.Identity.RoleScopeGrants
  alias Letflow.Identity.TenantAdminGuard
  alias Letflow.Repo
  alias Letflow.ScopeNodePaths

  require Logger

  @tenant_admin_role "TENANT_ADMIN"
  @create_keys ["principal_type", "principal_id", "role", "scope_node_id"]
  @make_tenant_wide_keys ["principal_type", "principal_id", "role"]
  @cursor_prefix "RG:"

  @type principal_type :: :user | :group
  @type actor :: %{
          required(:user_id) => Ecto.UUID.t(),
          required(:trace_id) => String.t() | nil,
          optional(:credential) => String.t() | nil
        }
  @type grant_view :: %{
          id: Ecto.UUID.t(),
          principal_type: principal_type(),
          principal_id: Ecto.UUID.t(),
          role: String.t(),
          scope_node_id: String.t() | nil,
          tenant_wide: boolean(),
          effective: boolean()
        }
  @type write_error ::
          :invalid_body
          | :invalid_role
          | :invalid_principal
          | :no_binding
          | :invalid_scope_node
          | :tenant_wide_row_exists
          | :grant_exists
          | :self_grant_refused
          | :last_scoped_row
          | :last_admin_binding_row
          | :last_tenant_wide_admin
          | :last_interactive_tenant_wide_admin
          | :not_found
          | {:audit_failed, term()}
          | {:transaction_failed, Exception.t()}

  # --- pure parsing ------------------------------------------------------------

  @doc "Parses and validates a create body (no DB access). Step 1 to 3 of design 3.3."
  @spec parse_create(body :: term()) ::
          {:ok, map()} | {:error, :invalid_body | :invalid_role | :invalid_principal}
  def parse_create(body) do
    with {:ok, map} <- exact_string_keys(body, @create_keys),
         {:ok, role} <- parse_role(map["role"]),
         {:ok, type, id} <- parse_principal(map["principal_type"], map["principal_id"]) do
      {:ok,
       %{principal_type: type, principal_id: id, role: role, scope_node_id: map["scope_node_id"]}}
    end
  end

  @doc "Parses and validates a make-tenant-wide body (no DB access)."
  @spec parse_make_tenant_wide(body :: term()) ::
          {:ok, map()} | {:error, :invalid_body | :invalid_role | :invalid_principal}
  def parse_make_tenant_wide(body) do
    with {:ok, map} <- exact_string_keys(body, @make_tenant_wide_keys),
         {:ok, role} <- parse_role(map["role"]),
         {:ok, type, id} <- parse_principal(map["principal_type"], map["principal_id"]) do
      {:ok, %{principal_type: type, principal_id: id, role: role}}
    end
  end

  defp exact_string_keys(body, keys) when is_map(body) do
    if Enum.sort(Map.keys(body)) == Enum.sort(keys) and
         Enum.all?(keys, &is_binary(Map.get(body, &1))),
       do: {:ok, body},
       else: {:error, :invalid_body}
  end

  defp exact_string_keys(_body, _keys), do: {:error, :invalid_body}

  @spec parse_role(term()) :: {:ok, String.t()} | {:error, :invalid_role}
  defp parse_role(role) when is_binary(role) do
    if role != "PLATFORM_ADMIN" and role in role_names(),
      do: {:ok, role},
      else: {:error, :invalid_role}
  end

  defp parse_role(_other), do: {:error, :invalid_role}

  defp role_names, do: Enum.map(Authorization.roles(), &Atom.to_string/1)

  defp parse_principal(type, id) do
    with {:ok, type} <- parse_principal_type(type),
         {:ok, id} <- parse_uuid(id) do
      {:ok, type, id}
    else
      :error -> {:error, :invalid_principal}
    end
  end

  defp parse_principal_type("user"), do: {:ok, :user}
  defp parse_principal_type("group"), do: {:ok, :group}
  defp parse_principal_type(_other), do: :error

  defp parse_uuid(id) when is_binary(id), do: Ecto.UUID.cast(id)
  defp parse_uuid(_other), do: :error

  # --- create ------------------------------------------------------------------

  @doc "Creates one scoped row (design 3.3 steps 4 to 11)."
  @spec create(attrs :: map(), actor(), prefix :: String.t()) ::
          {:ok, grant_view()} | {:error, write_error()}
  def create(attrs, actor, prefix) when is_map(attrs) and is_binary(prefix) do
    %{principal_type: type, principal_id: pid, role: role, scope_node_id: node_id} = attrs

    run(prefix, fn ->
      lock_writers!(role, prefix)
      check_principal!(type, pid, role, prefix)
      lock_node!(node_id, prefix)
      check_not_self!(type, pid, actor, prefix)
      check_create_rows!(type, pid, role, node_id, prefix)

      before_count =
        if role == @tenant_admin_role, do: TenantAdminGuard.count_before!(prefix, :explicit)

      row =
        case RoleScopeGrants.insert_scoped(type, pid, role, node_id, prefix) do
          {:ok, row} -> row
          {:error, reason} -> Repo.rollback(reason)
        end

      if role == @tenant_admin_role,
        do:
          TenantAdminGuard.ensure_admins_remain!(
            prefix,
            :scope_tenant_admin,
            pid,
            before_count,
            :explicit
          )

      audit!(prefix, actor, "grant.created", row.id, nil, row_state(row, actor))
      view(row, RoleScopeGrants.effective?(type, pid, role, prefix))
    end)
    |> after_refusal(actor, prefix, "create", attrs)
  end

  # --- delete ------------------------------------------------------------------

  @doc """
  Deletes one row by id (design 3.8, 3.9). An uncastable or unknown id is `:not_found`.

  GH #2869 (a): deleting a tenant-wide TENANT_ADMIN row in a tenant stored `on` is also
  refused with `{:error, :last_interactive_tenant_wide_admin}` when it takes the interactive
  explicit tenant-wide admin count from at least one to none (after the N1 guard).
  """
  @spec delete(row_id :: String.t(), actor(), prefix :: String.t()) ::
          :ok | {:error, write_error()}
  def delete(row_id, actor, prefix) when is_binary(prefix) do
    case parse_uuid(row_id) do
      :error ->
        {:error, :not_found}

      {:ok, id} ->
        run(prefix, fn ->
          Identity.lock_tenant_admins!(prefix)
          row = RoleScopeGrants.get_row(id, prefix) || Repo.rollback(:not_found)
          if row.role == @tenant_admin_role, do: TenantAdminGuard.lock_admin_binding!(prefix)

          rows = RoleScopeGrants.rows_for(row.principal_type, row.principal_id, row.role, prefix)
          check_delete_rule!(row, rows)

          guarded? = row.role == @tenant_admin_role and row.tenant_wide

          before_count =
            if guarded?, do: TenantAdminGuard.count_before!(prefix, :explicit)

          # GH #2869 (a): the interactive before-count, same trigger.
          interactive_before =
            if guarded?, do: TenantAdminGuard.count_before!(prefix, :interactive_explicit)

          :ok = RoleScopeGrants.delete_row!(row.id, prefix)

          if guarded? do
            TenantAdminGuard.ensure_admins_remain!(
              prefix,
              :revoke_tenant_admin_grant,
              row.principal_id,
              before_count,
              :explicit
            )

            # GH #2869 (a): the second guard, after the N1 guard.
            TenantAdminGuard.ensure_interactive_admin_remains!(
              prefix,
              :revoke_tenant_admin_grant,
              row.principal_id,
              interactive_before
            )
          end

          audit!(prefix, actor, "grant.revoked", row.id, row_keys(row), nil)
          :ok
        end)
        |> after_refusal(actor, prefix, "delete", nil)
    end
  end

  # G2 (CDV round 2): when the sole remaining row of a group's TENANT_ADMIN set is SCOPED,
  # `last_scoped_row` wins; `last_admin_binding_row` applies only when that sole row is
  # tenant-wide.
  defp check_delete_rule!(row, rows) do
    case {rows, row} do
      {[_only], %{tenant_wide: false}} ->
        Repo.rollback(:last_scoped_row)

      {[_only], %{tenant_wide: true, principal_type: :group, role: @tenant_admin_role}} ->
        Repo.rollback(:last_admin_binding_row)

      _allowed ->
        :ok
    end
  end

  # --- make tenant-wide ----------------------------------------------------------

  @doc "Replaces every scoped row of (principal, role) with ONE tenant-wide row (design 3.3)."
  @spec make_tenant_wide(attrs :: map(), actor(), prefix :: String.t()) ::
          {:ok, %{id: Ecto.UUID.t(), removed_scoped_ids: [Ecto.UUID.t()]}}
          | {:error, write_error()}
  def make_tenant_wide(attrs, actor, prefix) when is_map(attrs) and is_binary(prefix) do
    %{principal_type: type, principal_id: pid, role: role} = attrs

    run(prefix, fn ->
      lock_writers!(role, prefix)
      check_principal!(type, pid, role, prefix)
      check_not_self!(type, pid, actor, prefix)

      rows = RoleScopeGrants.rows_for(type, pid, role, prefix)
      if Enum.any?(rows, & &1.tenant_wide), do: Repo.rollback(:tenant_wide_row_exists)

      removed_ids = RoleScopeGrants.delete_scoped_rows!(type, pid, role, prefix)

      removed =
        for row <- rows, row.id in removed_ids do
          %{"id" => row.id, "scope_node_id" => row.scope_node_id}
        end

      new_row =
        case RoleScopeGrants.insert_tenant_wide(type, pid, role, prefix) do
          {:ok, row} -> row
          {:error, reason} -> Repo.rollback(reason)
        end

      after_state =
        new_row
        |> row_state(actor)
        |> Map.put("removed_scoped_ids", removed_ids)

      audit!(
        prefix,
        actor,
        "grant.made_tenant_wide",
        new_row.id,
        %{"removed" => removed},
        after_state
      )

      %{id: new_row.id, removed_scoped_ids: removed_ids}
    end)
    |> after_refusal(actor, prefix, "make_tenant_wide", attrs)
  end

  # --- list --------------------------------------------------------------------

  @doc """
  One page of rows. `filters` are the raw query values (`"principal_type"`, `"principal_id"`,
  `"role"`, all optional); `cursor` is the raw `cursor` query value or `nil`.
  """
  @spec list(filters :: map(), limit :: pos_integer(), cursor :: String.t() | nil, String.t()) ::
          {:ok, %{items: [grant_view()], next_cursor: String.t() | nil}}
          | {:error, :invalid_role | :invalid_principal | :invalid_cursor}
  def list(filters, limit, cursor, prefix)
      when is_map(filters) and is_integer(limit) and limit > 0 and is_binary(prefix) do
    with {:ok, parsed} <- parse_filters(filters),
         {:ok, after_key} <- decode_cursor(cursor) do
      %{rows: rows, next_key: next_key} =
        RoleScopeGrants.list_page(parsed, limit, after_key, prefix)

      {:ok,
       %{
         items: Enum.map(rows, fn %{row: row, effective: effective} -> view(row, effective) end),
         next_cursor: encode_cursor(next_key)
       }}
    end
  end

  defp parse_filters(filters) do
    with {:ok, acc} <- put_type_filter(%{}, Map.get(filters, "principal_type")),
         {:ok, acc} <- put_id_filter(acc, Map.get(filters, "principal_id")),
         {:ok, acc} <- put_role_filter(acc, Map.get(filters, "role")) do
      {:ok, acc}
    end
  end

  defp put_type_filter(acc, nil), do: {:ok, acc}

  defp put_type_filter(acc, value) do
    case parse_principal_type(value) do
      {:ok, type} -> {:ok, Map.put(acc, :principal_type, type)}
      :error -> {:error, :invalid_principal}
    end
  end

  defp put_id_filter(acc, nil), do: {:ok, acc}

  defp put_id_filter(acc, value) do
    case parse_uuid(value) do
      {:ok, id} -> {:ok, Map.put(acc, :principal_id, id)}
      :error -> {:error, :invalid_principal}
    end
  end

  defp put_role_filter(acc, nil), do: {:ok, acc}

  defp put_role_filter(acc, value) do
    case parse_role(value) do
      {:ok, role} -> {:ok, Map.put(acc, :role, role)}
      {:error, :invalid_role} -> {:error, :invalid_role}
    end
  end

  # Payload "RG:<mint_us>:<inserted_at_us>:<id>"; the mint time sits in the expiry-checked
  # slot (same deliberate repurposing as the group-member listing's cursor).
  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(raw) when is_binary(raw) do
    prefix_len = byte_size(@cursor_prefix)

    with {:ok, %Pagination.Cursor{inner: inner}} <-
           Pagination.decode_cursor(raw, @cursor_prefix, prefix_len),
         rest = binary_part(inner, prefix_len, byte_size(inner) - prefix_len),
         [_mint, inserted_at_us, id] <- String.split(rest, ":", parts: 3),
         {us, ""} <- Integer.parse(inserted_at_us),
         {:ok, ts} <- DateTime.from_unix(us, :microsecond),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {ts, id}}
    else
      _invalid -> {:error, :invalid_cursor}
    end
  end

  defp decode_cursor(_other), do: {:error, :invalid_cursor}

  defp encode_cursor(nil), do: nil

  defp encode_cursor({%DateTime{} = ts, id}) do
    @cursor_prefix
    |> Pagination.build_raw_cursor_timestamp_key(
      System.system_time(:microsecond),
      DateTime.to_unix(ts, :microsecond),
      id
    )
    |> Pagination.encode_cursor()
  end

  @doc """
  The authenticated caller of a request, for the audit entries (never a request value):
  user id, trace id and the credential mechanism (`"oidc"` or `"api_token"`).
  """
  @spec actor_from_conn(Plug.Conn.t()) :: actor()
  def actor_from_conn(%Plug.Conn{} = conn) do
    ctx = conn.assigns.auth_context

    %{
      user_id: ctx.user_id,
      trace_id: conn.assigns[:trace_id],
      credential: credential_name(Map.get(ctx, :credential))
    }
  end

  defp credential_name(credential) when is_atom(credential) and not is_nil(credential),
    do: Atom.to_string(credential)

  defp credential_name(_other), do: nil

  # --- shared transaction steps ----------------------------------------------------

  # Lock A first, then R for TENANT_ADMIN rows.
  defp lock_writers!(role, prefix) do
    Identity.lock_tenant_admins!(prefix)
    if role == @tenant_admin_role, do: TenantAdminGuard.lock_admin_binding!(prefix)
    :ok
  end

  # Step 5: the principal exists; a group needs a `:platform_role` binding for the role.
  defp check_principal!(:user, id, _role, prefix) do
    if Identity.user_exists?(id, prefix), do: :ok, else: Repo.rollback(:invalid_principal)
  end

  defp check_principal!(:group, id, role, prefix) do
    cond do
      not Identity.group_exists?(id, prefix) -> Repo.rollback(:invalid_principal)
      not Identity.group_bound_to_platform_role?(id, role, prefix) -> Repo.rollback(:no_binding)
      true -> :ok
    end
  end

  # Step 6: the node row share lock; unknown, retired or malformed all answer one code.
  defp lock_node!(node_id, prefix) do
    case ScopeNodePaths.lock_active_node_for_share!(node_id, prefix) do
      {:ok, _node} -> :ok
      {:error, _reason} -> Repo.rollback(:invalid_scope_node)
    end
  end

  # Step 7: widening a principal that is the caller, or a group the caller is a member of.
  defp check_not_self!(type, principal_id, actor, prefix) do
    if self?(type, principal_id, actor.user_id, prefix), do: Repo.rollback(:self_grant_refused)
    :ok
  end

  defp self?(:user, principal_id, caller_id, _prefix),
    do: Identity.same_user_id?(principal_id, caller_id)

  defp self?(:group, group_id, caller_id, prefix),
    do: Identity.group_member?(group_id, caller_id, prefix)

  # Steps 8 and 9.
  defp check_create_rows!(type, pid, role, node_id, prefix) do
    rows = RoleScopeGrants.rows_for(type, pid, role, prefix)

    cond do
      Enum.any?(rows, & &1.tenant_wide) -> Repo.rollback(:tenant_wide_row_exists)
      Enum.any?(rows, &(&1.scope_node_id == node_id)) -> Repo.rollback(:grant_exists)
      true -> :ok
    end
  end

  # --- transaction wrapper and refusal events ----------------------------------------

  defp run(prefix, fun) do
    Repo.transaction(fun, prefix: prefix)
  rescue
    exception -> {:error, {:transaction_failed, exception}}
  end

  defp after_refusal({:ok, value}, _actor, _prefix, _act, _attrs), do: unwrap(value)

  defp after_refusal({:error, {:tenant_admin_guard, refusal}}, actor, prefix, _act, _attrs),
    do: TenantAdminGuard.refuse(prefix, refusal, guard_context(actor))

  defp after_refusal({:error, :self_grant_refused}, actor, prefix, act, attrs) do
    record_self_grant_refused(self_info(act, attrs), actor, prefix)
    {:error, :self_grant_refused}
  end

  defp after_refusal({:error, _reason} = error, _actor, _prefix, _act, _attrs), do: error

  # `delete/3` returns `:ok`, the other writers a value map.
  defp unwrap(:ok), do: :ok
  defp unwrap(value), do: {:ok, value}

  defp guard_context(actor), do: %{actor_id: actor.user_id, trace_id: actor.trace_id}

  defp self_info(act, nil), do: %{act: act}
  defp self_info(act, attrs), do: Map.put(attrs, :act, act)

  @doc """
  Records `grant.self_grant_refused` in its OWN transaction (call it AFTER the refused
  transaction rolled back). `info` carries `act` (`"create"`, `"make_tenant_wide"`,
  `"add_member"`) and optionally `principal_type`, `principal_id`, `role`, `scope_node_id`.
  Never raises; a failure logs one constant line (no ids) and the refusal is still returned
  by the caller.
  """
  @spec record_self_grant_refused(info :: map(), actor(), prefix :: String.t()) :: :ok
  def record_self_grant_refused(info, actor, prefix) when is_map(info) and is_binary(prefix) do
    if Repo.in_transaction?() do
      Logger.error("grant_self_refusal_not_recorded reason=inside_transaction")
    else
      write_self_refusal(info, actor, prefix)
    end

    :ok
  rescue
    exception ->
      Logger.error("grant_self_refusal_not_recorded exception=#{inspect(exception.__struct__)}")
      :ok
  end

  defp write_self_refusal(info, actor, prefix) do
    principal_id = Map.get(info, :principal_id) || actor.user_id

    attrs = %{
      actor_id: actor.user_id,
      action: "grant.self_grant_refused",
      resource_type: "role_scope_grant",
      resource_id: principal_id,
      before_state: nil,
      after_state: %{
        "act" => Map.get(info, :act),
        "actor" => actor.user_id,
        "principal_type" => info |> Map.get(:principal_type) |> type_string(),
        "principal_id" => principal_id,
        "role" => Map.get(info, :role),
        "scope_node_id" => Map.get(info, :scope_node_id),
        "trace_id" => actor.trace_id,
        "credential" => Map.get(actor, :credential)
      },
      trace_id: actor.trace_id
    }

    case Audit.insert_entry(Repo, attrs, prefix) do
      {:ok, _entry} -> :ok
      {:error, _reason} -> Logger.error("grant_self_refusal_not_recorded reason=audit_failed")
    end
  end

  defp type_string(nil), do: nil
  defp type_string(type) when is_atom(type), do: Atom.to_string(type)

  # --- audit and views -----------------------------------------------------------------

  defp audit!(prefix, actor, action, row_id, before_state, after_state) do
    attrs = %{
      actor_id: actor.user_id,
      action: action,
      resource_type: "role_scope_grant",
      resource_id: row_id,
      before_state: before_state,
      after_state: with_credential(after_state, actor),
      trace_id: actor.trace_id
    }

    case Audit.insert_entry(Repo, attrs, prefix) do
      {:ok, _entry} -> :ok
      {:error, reason} -> Repo.rollback({:audit_failed, reason})
    end
  end

  # SEC D-3: every grant write is attributable to its credential mechanism. A revoke has no
  # after state, so it records the credential alone (and its before state carries the row).
  defp with_credential(nil, actor),
    do: %{
      "credential" => Map.get(actor, :credential),
      "actor" => actor.user_id,
      "trace_id" => actor.trace_id
    }

  defp with_credential(state, actor),
    do: Map.put(state, "credential", Map.get(actor, :credential))

  defp row_keys(row) do
    %{
      "id" => row.id,
      "principal_type" => Atom.to_string(row.principal_type),
      "principal_id" => row.principal_id,
      "role" => row.role,
      "scope_node_id" => row.scope_node_id,
      "tenant_wide" => row.tenant_wide
    }
  end

  defp row_state(row, actor), do: Map.put(row_keys(row), "trace_id", actor.trace_id)

  defp view(row, effective) do
    %{
      id: row.id,
      principal_type: row.principal_type,
      principal_id: row.principal_id,
      role: row.role,
      scope_node_id: row.scope_node_id,
      tenant_wide: row.tenant_wide,
      effective: effective
    }
  end
end
