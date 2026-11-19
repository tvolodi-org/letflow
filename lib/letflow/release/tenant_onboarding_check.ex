defmodule Letflow.Release.TenantOnboardingCheck do
  @moduledoc """
  T-2220 / T-2257 -- the read-only first-use report for one onboarded tenant, step 8 of
  `docs/runbooks/production-tenant-onboarding.md`. Run through the release by infra:

      bin/letflow eval 'Letflow.Release.tenant_onboarding_check("<slug>", host: "<host>", tenant_type: "production")'
      bin/letflow eval 'Letflow.Release.tenant_onboarding_check("<slug>", format: :json)'

  Do not call it through `rpc`: the wrapper halts the VM on failure and would stop the node.

  The report proves the tenant, realm, host row, modules (at the versions of the RUNNING build),
  every stock process definition, document type and entity table, the platform role groups and
  STOREKEEPER members, the organisation/location/employee links, and the settings needed at first
  use. Shared-access, negative-balance and four-eyes values are information, not readiness gates.

  ## Options

    * `:realm` -- expected realm id (default the slug)
    * `:host` -- expected hostname (default nil: exactly one host row)
    * `:tenant_type` -- expected `test` / `production` (default nil: not checked)
    * `:modules` -- expected module ids (default `default_modules/0`)
    * `:format` -- `:text` (default) or `:json`, consumed by the release wrapper
    * `:date` -- report date (default today; intended for deterministic tests)

  ## Scoping (INV-1, INV-6, INV-7)

  The tenant schema comes only from the registration of the tenant found by slug, never from an
  argument. Every read is an Ecto query with bound values, a context read using that schema, or the
  parameterised `TenantProvisioning.entity_table_exists?/2`. The check writes nothing.

  ## Output (INV-4)

  The header carries tenant slug, build SHA and date. Each check is one `OK`, `RED` or `INFO` line;
  the final line is `READY` or `RED` followed by the failed check names. Text and JSON contain only
  slugs, realm/host names, build/module/definition/document/table names, role names, organisation
  and location names, counts and fixed tokens: never tenant/user/employee ids, schema names,
  credentials, employee names, usernames or e-mail addresses. A raise inside a check becomes the
  token `read_failed` for that check.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.ApprovalRules
  alias Letflow.BuildInfo
  alias Letflow.Definitions
  alias Letflow.Documents.DocumentType
  alias Letflow.Identity
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Ledger.NegativeBalanceSettings
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Installs
  alias Letflow.Modules.ReadApi
  alias Letflow.Repo
  alias Letflow.SharedStockAccess
  alias Letflow.TenantProvisioning

  @default_modules ~w(org locations catalog_items codes stock)

  @type check_result :: :ok | :info | {:fail, atom()}
  @type check :: %{name: String.t(), result: check_result(), detail: String.t() | nil}
  @type report :: %{
          slug: String.t(),
          build_sha: String.t() | nil,
          date: Date.t(),
          checks: [check()]
        }

  @doc "The default module list, in install order."
  @spec default_modules() :: [String.t()]
  def default_modules, do: @default_modules

  @doc "Every document type key the running stock module registers."
  @spec document_types() :: [String.t()]
  def document_types do
    stock_module().document_types() |> Enum.map(& &1.key)
  end

  @doc "Every entity table the running stock module manages."
  @spec tables() :: [String.t()]
  def tables do
    Enum.map(stock_module().manifest().manages_entity_types, fn entity_type ->
      {:ok, table} = TenantProvisioning.table_name_for_entity_type(entity_type)
      table
    end)
  end

  @doc "Every stock process key in the running build's pack, in pack order."
  @spec process_definitions() :: [String.t()]
  def process_definitions do
    {:ok, pack} = Installs.read_pack_document(stock_module().manifest().pack)
    Enum.map(Map.fetch!(pack, "definitions"), &Map.fetch!(&1, "process_key"))
  end

  @doc "Runs all checks for one tenant. `{:error, report}` when any readiness check is RED."
  @spec run(term(), keyword()) :: {:ok, report()} | {:error, report()}
  def run(slug, opts \\ []) do
    checks =
      case find_tenant(slug) do
        {:ok, tenant} -> tenant_checks(tenant, opts)
        {:fail, token} -> [check("tenant", {:fail, token}, nil)]
      end

    report = %{
      slug: if(is_binary(slug), do: slug, else: ""),
      build_sha: BuildInfo.sha(),
      date: Keyword.get(opts, :date, Date.utc_today()),
      checks: checks
    }

    if Enum.any?(checks, &red?/1), do: {:error, report}, else: {:ok, report}
  end

  @doc "Header, one line per check, then READY or the comma-separated RED check names."
  @spec format_lines(report()) :: [String.t()]
  def format_lines(%{slug: slug, build_sha: sha, date: date, checks: checks}) do
    red = Enum.filter(checks, &red?/1)

    verdict =
      case red do
        [] -> "READY"
        failed -> "RED " <> Enum.map_join(failed, ", ", & &1.name)
      end

    [
      "tenant: #{slug}",
      "build_sha: #{sha || "unknown"}",
      "date: #{Date.to_iso8601(date)}"
    ] ++ Enum.map(checks, &format_check/1) ++ [verdict]
  end

  @doc "The same report as one stable JSON object for readiness scripts."
  @spec format_json(report()) :: String.t()
  def format_json(%{slug: slug, build_sha: sha, date: date, checks: checks}) do
    %{
      slug: slug,
      build_sha: sha,
      date: Date.to_iso8601(date),
      status: if(Enum.any?(checks, &red?/1), do: "red", else: "ready"),
      checks:
        Enum.map(checks, fn %{name: name, result: result, detail: detail} ->
          %{
            name: name,
            status: json_status(result),
            reason: fail_reason(result),
            detail: detail
          }
        end)
    }
    |> Jason.encode!()
  end

  defp json_status(:ok), do: "ok"
  defp json_status(:info), do: "info"
  defp json_status({:fail, _}), do: "red"
  defp fail_reason({:fail, reason}), do: Atom.to_string(reason)
  defp fail_reason(_), do: nil

  defp format_check(%{name: name, result: :ok, detail: detail}),
    do: join(["OK", name, detail])

  defp format_check(%{name: name, result: :info, detail: detail}),
    do: join(["INFO", name, detail])

  defp format_check(%{name: name, result: {:fail, token}, detail: detail}),
    do: join(["RED", name, Atom.to_string(token), detail])

  defp join(parts), do: parts |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  defp red?(%{result: {:fail, _}}), do: true
  defp red?(_), do: false

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
    base =
      [check_realm(tenant, Keyword.get(opts, :realm, tenant.slug))] ++
        check_type(tenant, Keyword.get(opts, :tenant_type)) ++
        [check_host(tenant, Keyword.get(opts, :host))] ++
        tenant_first_use_checks(tenant)

    case guarded(fn -> TenantProvisioning.registered_schema(tenant.id) end) do
      {:ok, {:ok, schema}} ->
        base ++
          [check("schema", :ok, nil)] ++
          schema_checks(schema, Keyword.get(opts, :modules, @default_modules))

      _ ->
        base ++ [check("schema", {:fail, :schema_not_registered}, nil)]
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

  defp tenant_first_use_checks(tenant) do
    shared? = SharedStockAccess.enabled?(tenant.slug)
    app_name = get_in(tenant.settings || %{}, ["app_name"])

    app_check =
      if present?(app_name),
        do: check("settings app_name", :ok, "set=true"),
        else: check("settings app_name", {:fail, :app_name_missing}, "set=false")

    scope_check =
      if shared? and tenant.scope_enforcement != :off,
        do:
          check(
            "scope enforcement",
            {:fail, :scope_enforcement_active},
            "mode=#{tenant.scope_enforcement} required=off"
          ),
        else: check("scope enforcement", :ok, "mode=#{tenant.scope_enforcement}")

    [
      app_check,
      check("shared stock access", :info, "enabled=#{shared?}"),
      scope_check
    ]
  end

  defp schema_checks(schema, expected) do
    installed =
      case guarded(fn -> Installs.list_installed(prefix: schema) end) do
        {:ok, rows} -> Map.new(rows, &{&1.module_id, &1.version})
        _ -> :read_failed
      end

    module_checks(installed, expected) ++
      [role_groups_check(schema)] ++ stock_checks(schema, "stock" in expected)
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

  defp role_groups_check(schema) do
    case guarded(fn ->
           expected =
             RoleRegistry.seedable_role_names(schema)
             |> Enum.uniq()
             |> Kernel.++(["STOREKEEPER"])
             |> Enum.uniq()

           held =
             Repo.all(
               from(r in TenantRole,
                 join: g in Group,
                 on: g.id == r.group_id,
                 where: r.kind == :platform_role,
                 select: r.name
               ),
               prefix: schema
             )

           {expected, held}
         end) do
      {:ok, {expected, held}} ->
        case Enum.sort(expected -- held) do
          [] ->
            check("platform role groups", :ok, "count=#{length(expected)}")

          missing ->
            check(
              "platform role groups",
              {:fail, :role_groups_missing},
              "missing=#{Enum.join(missing, ",")}"
            )
        end

      _ ->
        check("platform role groups", {:fail, :read_failed}, nil)
    end
  end

  defp stock_checks(_schema, false), do: []

  defp stock_checks(schema, true) do
    processes = guarded(&process_definitions/0)
    documents = guarded(&document_types/0)
    tables = guarded(&tables/0)

    employees =
      guarded(fn ->
        {:ok, rows} = ReadApi.list_active(schema, "org_employee")
        rows
      end)

    process_checks(schema, processes) ++
      document_checks(schema, documents) ++
      table_checks(schema, tables) ++
      [storekeeper_check(schema, employees)] ++
      employee_checks(schema, employees) ++
      [place_links_check(schema), legal_entities_check(schema)] ++
      [ledger_settings_check(schema), four_eyes_check(schema, processes)]
  end

  defp process_checks(schema, {:ok, names}) do
    Enum.map(names, fn name ->
      result = guarded(fn -> Definitions.get_active_by_name(name, prefix: schema) end)

      case result do
        {:ok, {:ok, %{needs_reactivation_at: nil}}} ->
          check("process #{name}", :ok, "active=true")

        {:ok, {:ok, _}} ->
          check("process #{name}", {:fail, :reactivation_required}, "active=true")

        {:ok, {:error, :not_found}} ->
          check("process #{name}", {:fail, :process_not_active}, "active=false")

        _ ->
          check("process #{name}", {:fail, :read_failed}, nil)
      end
    end)
  end

  defp process_checks(_schema, _),
    do: [check("stock process definitions", {:fail, :read_failed}, nil)]

  defp document_checks(schema, {:ok, keys}) do
    for key <- keys do
      name = "document_type #{key}"

      case guarded(fn -> Repo.get(DocumentType, key, prefix: schema) end) do
        {:ok, nil} -> check(name, {:fail, :document_type_missing}, nil)
        {:ok, %{owner_module: "stock"}} -> check(name, :ok, nil)
        {:ok, _} -> check(name, {:fail, :document_type_not_stock}, nil)
        _ -> check(name, {:fail, :read_failed}, nil)
      end
    end
  end

  defp document_checks(_schema, _),
    do: [check("stock document types", {:fail, :read_failed}, nil)]

  defp table_checks(schema, {:ok, expected}) do
    for table <- expected do
      name = "table #{table}"

      case guarded(fn -> TenantProvisioning.entity_table_exists?(schema, table) end) do
        {:ok, true} -> check(name, :ok, nil)
        {:ok, false} -> check(name, {:fail, :table_missing}, nil)
        _ -> check(name, {:fail, :read_failed}, nil)
      end
    end
  end

  defp table_checks(_schema, _), do: [check("stock entity tables", {:fail, :read_failed}, nil)]

  defp storekeeper_check(schema, {:ok, employees}) do
    result =
      guarded(fn ->
        ids =
          Repo.all(
            from(gm in GroupMember,
              join: r in TenantRole,
              on: r.group_id == gm.group_id,
              join: u in User,
              on: u.id == gm.user_id,
              where: r.name == "STOREKEEPER" and r.kind == :platform_role and u.status == :active,
              select: gm.user_id,
              distinct: true
            ),
            prefix: schema
          )

        effective = Identity.roles_by_user(ids, prefix: schema)
        employee_users = MapSet.new(employees, & &1["user_id"])

        {ids,
         Enum.count(ids, fn id ->
           "STOREKEEPER" not in Map.get(effective, id, []) or
             not MapSet.member?(employee_users, id)
         end)}
      end)

    case result do
      {:ok, {[], _}} ->
        check("storekeeper users", {:fail, :storekeeper_missing}, "count=0")

      {:ok, {ids, 0}} ->
        check("storekeeper users", :ok, "count=#{length(ids)}")

      {:ok, {ids, gaps}} ->
        check(
          "storekeeper users",
          {:fail, :storekeeper_link_missing},
          "count=#{length(ids)} gaps=#{gaps}"
        )

      _ ->
        check("storekeeper users", {:fail, :read_failed}, nil)
    end
  end

  defp storekeeper_check(_schema, _), do: check("storekeeper users", {:fail, :read_failed}, nil)

  defp employee_checks(schema, {:ok, employees}) do
    count_check =
      case length(employees) do
        1 -> check("active employees", :ok, "count=1")
        n -> check("active employees", {:fail, :active_employee_count}, "count=#{n} expected=1")
      end

    linked =
      Enum.map(employees, fn employee ->
        case employee["user_id"] do
          id when is_binary(id) ->
            case Ecto.UUID.cast(id) do
              {:ok, uuid} -> uuid
              :error -> nil
            end

          _ ->
            nil
        end
      end)

    ids = linked |> Enum.reject(&is_nil/1) |> Enum.uniq()

    active_result =
      guarded(fn ->
        if ids == [],
          do: [],
          else:
            Repo.all(
              from(u in User, where: u.id in ^ids and u.status == :active, select: u.id),
              prefix: schema
            )
      end)

    link_check =
      case active_result do
        {:ok, active_ids} ->
          active = MapSet.new(active_ids)
          gaps = Enum.count(linked, &(is_nil(&1) or not MapSet.member?(active, &1)))

          if gaps == 0,
            do: check("employee user links", :ok, "count=#{length(employees)} gaps=0"),
            else:
              check(
                "employee user links",
                {:fail, :employee_user_link_missing},
                "count=#{length(employees)} gaps=#{gaps}"
              )

        _ ->
          check("employee user links", {:fail, :read_failed}, nil)
      end

    [count_check, link_check]
  end

  defp employee_checks(_schema, _),
    do: [
      check("active employees", {:fail, :read_failed}, nil),
      check("employee user links", {:fail, :read_failed}, nil)
    ]

  defp place_links_check(schema) do
    case guarded(fn ->
           locations = module!("locations")
           {:ok, places} = locations.list_active(schema)

           gaps =
             Enum.reject(places, fn place ->
               locations.org_unit_ids_for_location(schema, place["record_id"]) != []
             end)

           {length(places), Enum.map(gaps, &record_label/1)}
         end) do
      {:ok, {count, []}} ->
        check("place org unit links", :ok, "count=#{count}")

      {:ok, {count, names}} ->
        check(
          "place org unit links",
          {:fail, :place_link_missing},
          "count=#{count} gaps=#{Enum.join(names, ",")}"
        )

      _ ->
        check("place org unit links", {:fail, :read_failed}, nil)
    end
  end

  defp legal_entities_check(schema) do
    case guarded(fn ->
           org = module!("org")
           {:ok, units} = ReadApi.list_active(schema, "org_unit")

           gaps =
             Enum.reject(units, fn unit ->
               case org.lookup(schema, unit["legal_entity_id"]) do
                 {:ok, %{"entity_type" => "org_legal_entity", "active" => true} = legal_entity} ->
                   present?(legal_entity["name"]) and present?(legal_entity["bin"])

                 _ ->
                   false
               end
             end)

           {length(units), Enum.map(gaps, &record_label/1)}
         end) do
      {:ok, {count, []}} ->
        check("org unit legal entities", :ok, "count=#{count}")

      {:ok, {count, names}} ->
        check(
          "org unit legal entities",
          {:fail, :legal_entity_incomplete},
          "count=#{count} gaps=#{Enum.join(names, ",")}"
        )

      _ ->
        check("org unit legal entities", {:fail, :read_failed}, nil)
    end
  end

  defp ledger_settings_check(schema) do
    case guarded(fn -> NegativeBalanceSettings.rows(schema, ["stock"]) end) do
      {:ok, rows} ->
        allow_negative = rows |> Map.get("stock", %{}) |> Map.get(:allow_negative, false)
        check("ledger settings", :info, "registration=stock allow_negative=#{allow_negative}")

      _ ->
        check("ledger settings", {:fail, :read_failed}, nil)
    end
  end

  defp four_eyes_check(schema, {:ok, stock_names}) do
    case guarded(fn -> ApprovalRules.list(schema) end) do
      {:ok, rows} ->
        stock = Enum.filter(rows, &(&1.definition_name in stock_names))
        on = Enum.count(stock, & &1.four_eyes)
        off = length(stock) - on

        steps =
          Enum.map_join(stock, ",", fn row ->
            "#{row.definition_name}.#{row.node_id}=#{if row.four_eyes, do: "on", else: "off"}"
          end)

        check(
          "four-eyes",
          :info,
          join(["on=#{on}", "off=#{off}", if(steps != "", do: "steps=#{steps}")])
        )

      _ ->
        check("four-eyes", {:fail, :read_failed}, nil)
    end
  end

  defp four_eyes_check(_schema, _), do: check("four-eyes", {:fail, :read_failed}, nil)

  defp record_label(record) do
    (record["name"] || record["code"] || "unnamed")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, 80)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp stock_module, do: module!("stock")

  defp module!(id) do
    {:ok, module} = Catalog.fetch(id)
    module
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
