defmodule Letflow.Release.TenantOnboardingCheck do
  @moduledoc """
  T-2220 -- the read-only product check of one onboarded tenant, step 8 of
  `docs/runbooks/production-tenant-onboarding.md`. Run through the release by infra:

      bin/letflow eval 'Letflow.Release.tenant_onboarding_check("<slug>", host: "<host>", tenant_type: "production")'

  Do not call it through `rpc`: the wrapper halts the VM on failure and would stop the node.

  Why it exists: the product has no HTTP read of `document_types`, and the tables a module
  install creates are only visible in the database. Infra proved them with raw psql; this check
  proves, for one tenant and without a token, that the tenant, realm, host row, modules (at the
  versions of the RUNNING build), the `stock_opening` / `stock_quick_count` document types and
  the `entity_stock_quick_count` / `entity_stock_quick_count_line` tables are present. Stock process
  definitions must be active or untouched module-owned drafts ready for automatic activation on first use.

  ## Options

    * `:realm` -- expected realm id (default the slug)
    * `:host` -- expected hostname (default nil: exactly one host row)
    * `:tenant_type` -- expected `test` / `production` (default nil: not checked)
    * `:modules` -- expected module ids (default `default_modules/0`)

  ## Scoping (INV-1, INV-6, INV-7)

  The tenant schema comes only from the registration of the tenant found by slug, never from an
  argument. Every read is an Ecto query with bound values, or the parameterised
  `TenantProvisioning.entity_table_exists?/2`. The check writes nothing.

  ## Output (INV-4)

  Slug, realm id, hostname, module ids and versions, document keys, table names and fixed tokens
  only: no tenant id, schema name, token, user or record data. A raise inside a check becomes the
  token `read_failed` for that check.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.OwnerStamp
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Documents.DocumentType
  alias Letflow.Identity
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Installs
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @default_modules ~w(org locations catalog_items codes stock)
  @document_types ~w(stock_opening stock_quick_count)
  @tables ~w(entity_stock_quick_count entity_stock_quick_count_line)
  @processes ~w(stock_receipt stock_issue stock_transfer stock_return stock_handover stock_writeoff
                stock_opening stock_quick_count stock_reversal stock_count_posting)

  @type check :: %{name: String.t(), result: :ok | {:fail, atom()}, detail: String.t() | nil}
  @type report :: %{slug: String.t(), checks: [check()]}

  @doc "The default module list, in install order."
  @spec default_modules() :: [String.t()]
  def default_modules, do: @default_modules

  @doc "Document type keys the stock module registers."
  @spec document_types() :: [String.t()]
  def document_types, do: @document_types

  @doc "Entity tables the stock module creates."
  @spec tables() :: [String.t()]
  def tables, do: @tables

  @doc "Runs the checks for one tenant. `{:error, report}` when any check failed."
  @spec run(term(), keyword()) :: {:ok, report()} | {:error, report()}
  def run(slug, opts \\ []) do
    checks =
      case find_tenant(slug) do
        {:ok, tenant} -> tenant_checks(tenant, opts)
        {:fail, token} -> [check("tenant", {:fail, token}, nil)]
      end

    report = %{slug: if(is_binary(slug), do: slug, else: ""), checks: checks}
    if Enum.all?(checks, &(&1.result == :ok)), do: {:ok, report}, else: {:error, report}
  end

  @doc "One line per check, then the verdict line."
  @spec format_lines(report()) :: [String.t()]
  def format_lines(%{slug: slug, checks: checks}) do
    failed = Enum.count(checks, &(&1.result != :ok))

    verdict =
      if failed == 0,
        do: "tenant_onboarding_check #{slug}: PASS",
        else: "tenant_onboarding_check #{slug}: FAIL (#{failed} failed)"

    Enum.map(checks, &format_check/1) ++ [verdict]
  end

  defp format_check(%{name: name, result: :ok, detail: detail}),
    do: join([name, "ok", detail])

  defp format_check(%{name: name, result: {:fail, token}, detail: detail}),
    do: join([name, "FAIL", Atom.to_string(token), detail])

  defp join(parts), do: parts |> Enum.reject(&is_nil/1) |> Enum.join(" ")

  defp find_tenant(slug) when is_binary(slug) and byte_size(slug) in 1..255 do
    case guarded(fn -> Identity.get_tenant_by_slug(slug) end) do
      {:ok, {:ok, %{status: :active} = tenant}} -> {:ok, tenant}
      {:ok, {:ok, _inactive}} -> {:fail, :tenant_not_active}
      {:ok, {:error, :not_found}} -> {:fail, :tenant_not_found}
      _ -> {:fail, :read_failed}
    end
  end

  defp find_tenant(_), do: {:fail, :tenant_not_found}

  defp tenant_checks(tenant, opts) do
    realm_check = check_realm(tenant, Keyword.get(opts, :realm, tenant.slug))
    type_check = check_type(tenant, Keyword.get(opts, :tenant_type))

    case guarded(fn -> TenantProvisioning.registered_schema(tenant.id) end) do
      {:ok, {:ok, schema}} ->
        [realm_check | type_check] ++
          [check_host(tenant, Keyword.get(opts, :host))] ++
          [check("schema", :ok, nil)] ++
          schema_checks(schema, Keyword.get(opts, :modules, @default_modules))

      _ ->
        [realm_check | type_check] ++ [check("schema", {:fail, :schema_not_registered}, nil)]
    end
  end

  defp check_realm(%{idp_realm_id: nil}, _), do: check("realm", {:fail, :realm_not_bound}, nil)
  defp check_realm(%{idp_realm_id: realm}, realm), do: check("realm", :ok, realm)
  defp check_realm(%{idp_realm_id: realm}, _), do: check("realm", {:fail, :realm_differs}, realm)

  defp check_type(_tenant, nil), do: []
  defp check_type(%{tenant_type: type}, type), do: [check("tenant_type", :ok, type)]

  defp check_type(%{tenant_type: type}, _),
    do: [check("tenant_type", {:fail, :tenant_type_differs}, type)]

  defp check_host(tenant, expected) do
    result =
      guarded(fn ->
        Repo.all(
          from(r in OnboardingRecord, where: r.tenant_id == ^tenant.id, select: r.hostname)
        )
      end)

    case {result, expected} do
      {{:ok, []}, _} -> check("host", {:fail, :host_missing}, nil)
      {{:ok, [_, _ | _]}, _} -> check("host", {:fail, :host_multiple}, nil)
      {{:ok, [host]}, nil} -> check("host", :ok, host)
      {{:ok, [host]}, host} -> check("host", :ok, host)
      {{:ok, [host]}, _} -> check("host", {:fail, :host_differs}, host)
      _ -> check("host", {:fail, :read_failed}, nil)
    end
  end

  defp schema_checks(schema, expected) do
    installed =
      case guarded(fn -> Installs.list_installed(prefix: schema) end) do
        {:ok, rows} -> Map.new(rows, &{&1.module_id, &1.version})
        _ -> :read_failed
      end

    module_checks(installed, expected) ++ stock_checks(schema, "stock" in expected)
  end

  defp module_checks(:read_failed, expected),
    do: Enum.map(expected, &check("module #{&1}", {:fail, :read_failed}, nil))

  defp module_checks(installed, expected) do
    wanted = Enum.map(expected, &module_check(&1, Map.fetch(installed, &1), true))

    others =
      installed
      |> Map.drop(expected)
      |> Enum.sort()
      |> Enum.map(fn {id, version} -> module_check(id, {:ok, version}, false) end)

    wanted ++ others
  end

  defp module_check(id, installed, required?) do
    name = "module #{id}"

    case {build_version(id), installed} do
      {{:error, _}, _} ->
        check(name, {:fail, :module_unknown_in_build}, nil)

      {_, :error} when required? ->
        check(name, {:fail, :module_missing}, nil)

      {{:ok, v}, {:ok, v}} ->
        check(name, :ok, v)

      {{:ok, b}, {:ok, i}} ->
        check(name, {:fail, :module_version_differs}, "installed #{i} build #{b}")
    end
  end

  defp build_version(id) do
    with {:ok, entry} <- Catalog.fetch(id), do: {:ok, entry.manifest().version}
  end

  defp stock_checks(_schema, false), do: []

  defp stock_checks(schema, true) do
    docs =
      for key <- @document_types do
        name = "document_type #{key}"

        case guarded(fn -> Repo.get(DocumentType, key, prefix: schema) end) do
          {:ok, nil} -> check(name, {:fail, :document_type_missing}, nil)
          {:ok, _} -> check(name, :ok, nil)
          _ -> check(name, {:fail, :read_failed}, nil)
        end
      end

    tables =
      for table <- @tables do
        name = "table #{table}"

        case guarded(fn -> TenantProvisioning.entity_table_exists?(schema, table) end) do
          {:ok, true} -> check(name, :ok, nil)
          {:ok, false} -> check(name, {:fail, :table_missing}, nil)
          _ -> check(name, {:fail, :read_failed}, nil)
        end
      end

    processes =
      for key <- @processes do
        name = "process_definition #{key}"

        case guarded(fn -> process_readiness(schema, key) end) do
          {:ok, status} when status in [:active, :draft] ->
            check(name, :ok, if(status == :active, do: "active", else: "draft auto-activation"))

          {:ok, _} ->
            check(name, {:fail, :process_definition_not_ready}, nil)

          _ ->
            check(name, {:fail, :read_failed}, nil)
        end
      end

    docs ++ tables ++ processes
  end

  defp process_readiness(schema, key) do
    rows =
      Repo.all(
        from(d in ProcessDefinition,
          where: d.name == ^key,
          order_by: [desc: d.created_at, desc: d.id]
        ),
        prefix: schema
      )

    own? = fn row ->
      case OwnerStamp.from_row(row) do
        {:ok, %{module_id: "stock", body_hash: hash}} -> OwnerStamp.graph_hash(row.graph) == hash
        _ -> false
      end
    end

    case Enum.find(rows, &(&1.status == :active)) do
      nil ->
        case rows do
          [%{status: :draft} | _] -> if Enum.all?(rows, own?), do: :draft, else: :not_ready
          _ -> :not_ready
        end

      row ->
        if own?.(row) and is_nil(row.needs_reactivation_at), do: :active, else: :not_ready
    end
  end

  defp check(name, result, detail), do: %{name: name, result: result, detail: detail}

  # INV-8: a raise or exit in one read becomes a token for that check; nothing is logged.
  defp guarded(fun) do
    {:ok, fun.()}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end
