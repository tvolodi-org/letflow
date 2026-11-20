defmodule Letflow.Modules.Stock.Access do
  @moduledoc """
  REQ-712 / GH #3749: the guard of the stock document routes. `Letflow.Ledger.authorize/3` knows only
  the purposes `:read` and `:reconcile`; this module answers the same question for the document routes:
  may this request read or write stock documents, tenant-wide?

  `check/2` returns `{:ok, %{prefix: prefix, actor_id: uuid}}` only when the principal is an interactive
  OIDC user (an API token is a different kind), holds the permission through one of its roles, and the
  permission is granted tenant-wide (`Letflow.Api.Scope.allowed_set/2` is `{:ok, :all}`). Everything
  else, a scope error included (`ScopeSetError` fails closed, INV-8), is `:error`, which the router turns
  into the 404 of a tenant without the module (INV-5). The `authz_*` macro of the router has already
  answered 403 to a caller whose roles do not hold the permission at all. For :post and :reverse a scoped principal is
  accepted (REQ-831, `check_scoped/2`); for :read it still gets the same 404. The body is
  `Letflow.Api.ModuleGuard.check/2` (CORE slice S8).

  The tenant is `principal.prefix`, derived from the token by the plug stack, never from the request.
  """

  alias Letflow.Api.ModuleGuard
  alias Letflow.Modules.Stock.Documents
  alias Letflow.Modules.Stock.Documents.Kinds

  @doc "The permission each purpose needs (the ledger registration names the same atoms)."
  @spec permission(:read | :post | :reverse | :quick_count | :workbook_apply | :approve) :: atom()
  def permission(:read), do: :StockRead
  def permission(:post), do: :StockPost
  def permission(:reverse), do: :StockReverse
  def permission(:quick_count), do: :StockQuickCount
  def permission(:workbook_apply), do: :StockWorkbookApply
  def permission(:approve), do: :StockApprove

  @doc """
  `:read` is tenant-wide only. `:post` and `:reverse` (REQ-831) also accept a scoped principal: the
  answer then carries `scope: {:nodes, ids}` and the router checks every org unit of the document
  against it; a tenant-wide principal gets `scope: :all`.
  """
  @spec check(Plug.Conn.t(), :read | :post | :reverse | :quick_count | :workbook_apply | :approve) ::
          {:ok,
           %{
             required(:prefix) => String.t(),
             required(:actor_id) => String.t(),
             optional(:scope) => term()
           }}
          | :error
  def check(%Plug.Conn{} = conn, :read), do: ModuleGuard.check(conn, permission(:read))

  # REQ-854: the quick count reads the book quantity of the key, so it is tenant-wide only (a scoped
  # principal or an API token gets the same 404 as a tenant without the module).
  def check(%Plug.Conn{} = conn, :quick_count),
    do: ModuleGuard.check(conn, permission(:quick_count))

  # T-2239: the Excel load is a quick count written from a workbook; same tenant-wide rule, its own permission.
  def check(%Plug.Conn{} = conn, :workbook_apply),
    do: ModuleGuard.check(conn, permission(:workbook_apply))

  # Decision 0093 F2: the approver's own probe; tenant-wide only, like the other single-permission purposes.
  def check(%Plug.Conn{} = conn, :approve), do: ModuleGuard.check(conn, permission(:approve))

  def check(%Plug.Conn{} = conn, purpose) when purpose in [:post, :reverse],
    do: ModuleGuard.check_scoped(conn, permission(purpose))

  @doc """
  REQ-831: the resource scope of a stock document map (the route's resolver). `{:node, org_unit_id}`
  for a non-empty string `org_unit_id`, `:unresolvable` otherwise. Pure.
  """
  @spec document_scope(term()) :: Letflow.Api.Scope.resource_scope()
  def document_scope(%{org_unit_id: id}) when is_binary(id) and id != "", do: {:node, id}
  def document_scope(%{"org_unit_id" => id}) when is_binary(id) and id != "", do: {:node, id}
  def document_scope(_other), do: :unresolvable

  @unit_keys ~w(org_unit_id to_org_unit_id from_org_unit_id)

  @doc """
  REQ-831: may the caller (`access` from `check/2`) act on the document the request names? A
  tenant-wide caller always. A scoped caller only when every org unit of the document (header keys
  `org_unit_id`, `to_org_unit_id`, `from_org_unit_id` its kind has) is in the set, and never for the
  opening kind. `mode`: `:create` (the parsed body), `:stored` (the stored document `id`),
  `:replace` (the stored document and the new body, decision 0051 M9). A document that does not
  exist or a body that does not parse is `true` here: the handler then answers its own not-found or
  validation refusal and writes nothing, so a missing document and one outside the set look alike.
  """
  @spec units_allowed?(map(), :create | :stored | :replace, term(), term()) :: boolean()
  def units_allowed?(%{scope: {:nodes, ids}} = access, mode, id, body) do
    case mode do
      :create -> body_ok?(body, :create, ids)
      :stored -> stored_ok?(access, id, ids)
      :replace -> stored_ok?(access, id, ids) and replace_body_ok?(access, id, body, ids)
    end
  end

  def units_allowed?(_tenant_wide, _mode, _id, _body), do: true

  defp body_ok?(body, parse_mode, ids) do
    case Kinds.parse(body, parse_mode) do
      {:ok, %{kind: "opening"}} -> false
      {:ok, %{header: header}} -> units_in?(header, ids)
      _unparsed -> true
    end
  end

  defp stored_ok?(access, id, ids) do
    case Documents.fetch(access.prefix, id) do
      {:ok, %{kind: "opening"}} -> false
      {:ok, view} -> units_in?(Kinds.header_of(Kinds.get(view.kind), view), ids)
      {:error, _not_found} -> true
    end
  end

  defp replace_body_ok?(access, id, body, ids) do
    case Documents.fetch(access.prefix, id) do
      {:ok, view} -> body_ok?(body, {:replace, view.kind}, ids)
      {:error, _not_found} -> true
    end
  end

  defp units_in?(header, ids) do
    header
    |> Map.take(@unit_keys)
    |> Map.values()
    |> Enum.reject(&is_nil/1)
    |> Enum.all?(&(&1 in ids))
  end
end
