defmodule Letflow.TenantConfigBundle do
  @moduledoc """
  REQ-552 slice 1 (GH #3177) -- export and import of a tenant's configuration bundle: the tenant
  settings (`tenants.settings`, the five closed keys of `Letflow.Identity.TenantSettings`) and the
  settings of the installed modules (`tenant_modules.settings`). A separate path from the
  definition promotion pipeline and from solution packs; it touches neither.

  Plain transactional context, no process (REQ-045). The tenant id and the schema prefix are
  arguments taken from the caller's token by the router; nothing in a bundle document selects a
  tenant (INV-1, INV-10). A module setting that holds a secret reference is exported as that
  reference string; this module never resolves a secret (INV-4).

  ## Import

  All-or-nothing: the shape and key vocabulary are checked first (no DB access), then one
  transaction locks the tenant row, applies the tenant settings with the PATCH shallow-merge
  rule, and writes each changed module's settings through `Letflow.Modules.Installs.put_settings/3`
  (the module's current manifest schema validates). Every violated item is reported; any
  violation rolls the whole import back. Unknown tenant-settings keys (and `brand_colors`
  sub-keys) are refused, which is stricter than `PATCH /tenant/settings`, which drops them.

  ## Format v2 (REQ-599, GH #3370)

  The export is `bpm/config-bundle/v2`: v1 plus the optional parts `label_overrides`
  (`message_id`, `locale`, `text`; sorted by message_id, locale) and `notification_templates`
  (`template_key`, `locale`, `subject`, `body`; sorted by template_key, locale). Each part is
  exported only for a caller who holds its manage permission (`:LabelsManage`,
  `:NotificationTemplatesManage`); the router decides and passes `parts:`. Import accepts v1 and
  v2; until part 2 of REQ-599 the two new parts in a v2 document are not read or applied. The
  import audit entry records the version of the imported document.

  A re-import of identical content changes nothing and writes no audit entry. A change writes
  exactly one entry carrying key names and module ids, never values.

  `tenant_settings_changed` counts changed TOP-LEVEL keys (a `brand_colors` map that differs
  counts 1); `modules_changed` / `modules_unchanged` count module entries.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Letflow.Audit
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantSettings
  alias Letflow.Labels
  alias Letflow.Modules.Installs
  alias Letflow.Modules.TenantModule
  alias Letflow.NotificationTemplates
  alias Letflow.Repo

  @schema_version "bpm/config-bundle/v2"
  @accepted_versions ["bpm/config-bundle/v1", "bpm/config-bundle/v2"]

  @type counts :: %{
          tenant_settings_changed: non_neg_integer(),
          modules_changed: non_neg_integer(),
          modules_unchanged: non_neg_integer()
        }

  @doc "The bundle schema version this module writes (export)."
  @spec schema_version() :: String.t()
  def schema_version, do: @schema_version

  @doc "The bundle schema versions an import accepts."
  @spec accepted_versions() :: [String.t()]
  def accepted_versions, do: @accepted_versions

  @doc """
  The bundle of `tenant_id` (installed modules read from `prefix`). Reads only.

  `opts[:parts]` lists the optional parts the caller may read (`:label_overrides`,
  `:notification_templates`); the router passes only those the caller's manage permission covers.
  A listed part adds its key with a list (`[]` when the tenant has none); an unlisted part adds no
  key. Default `[]`.
  """
  @spec export(Ecto.UUID.t(), String.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def export(tenant_id, prefix, opts \\ []) do
    parts = Keyword.get(opts, :parts, [])

    with {:ok, tenant} <- Identity.get_tenant(tenant_id) do
      modules =
        [prefix: prefix]
        |> Installs.list_installed()
        |> Enum.sort_by(& &1.module_id)
        |> Enum.map(fn tm ->
          %{
            "module_id" => tm.module_id,
            "module_version" => tm.version,
            "settings" => tm.settings || %{}
          }
        end)

      bundle = %{
        "bundle_schema_version" => @schema_version,
        "exported_at" =>
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "tenant_settings" => tenant.settings || %{},
        "module_settings" => modules
      }

      {:ok, Enum.reduce(parts, bundle, &add_part(&2, &1, tenant_id, prefix))}
    end
  end

  defp add_part(bundle, :label_overrides, tenant_id, prefix) do
    rows =
      prefix
      |> Labels.list_overrides(tenant_id)
      |> Enum.map(&%{"message_id" => &1.message_id, "locale" => &1.locale, "text" => &1.text})

    Map.put(bundle, "label_overrides", rows)
  end

  defp add_part(bundle, :notification_templates, tenant_id, prefix) do
    rows =
      prefix
      |> NotificationTemplates.list(tenant_id)
      |> Enum.map(
        &%{
          "template_key" => &1.template_key,
          "locale" => &1.locale,
          "subject" => &1.subject,
          "body" => &1.body
        }
      )
      |> Enum.sort_by(&{&1["template_key"], &1["locale"]})

    Map.put(bundle, "notification_templates", rows)
  end

  @doc """
  The permissions an import of `body` needs: `:TenantSettingsManage`, plus `:ModulesManage` when
  the bundle carries module settings.
  """
  @spec required_permissions(term()) :: [atom()]
  def required_permissions(%{"module_settings" => [_ | _]}),
    do: [:TenantSettingsManage, :ModulesManage]

  def required_permissions(_body), do: [:TenantSettingsManage]

  @doc """
  Applies `body` to the tenant `tenant_id` (schema `prefix`), as `actor_id`.
  """
  @spec import(Ecto.UUID.t(), String.t(), Ecto.UUID.t() | nil, term(), keyword()) ::
          {:ok, counts()}
          | {:error, {:unknown_schema_version, term()}}
          | {:error, {:invalid, [String.t()]}}
          | {:error, :internal}
  def import(tenant_id, prefix, actor_id, body, opts \\ []) do
    with {:ok, ts, modules} <- check_shape(body) do
      opts = Keyword.put(opts, :bundle_version, body["bundle_schema_version"])
      run_import(tenant_id, prefix, actor_id, ts, modules, opts)
    end
  end

  # ── shape (no DB) ───────────────────────────────────────────────────────

  defp check_shape(body) when is_map(body) do
    case Map.get(body, "bundle_schema_version") do
      v when v in @accepted_versions ->
        shape_rest(body)

      v when is_binary(v) ->
        {:error, {:unknown_schema_version, v}}

      _ ->
        shape_rest(body, ["bundle_schema_version must be a string"])
    end
  end

  defp check_shape(_other), do: {:error, {:invalid, ["request body must be a JSON object"]}}

  defp shape_rest(body, errs \\ []) do
    ts = Map.get(body, "tenant_settings")
    ms = Map.get(body, "module_settings")

    errs =
      if is_map(ts),
        do: errs ++ key_errors(ts),
        else: errs ++ ["tenant_settings must be an object"]

    {mods, errs} =
      if is_list(ms) do
        module_entries(ms, errs)
      else
        {[], errs ++ ["module_settings must be a list"]}
      end

    case errs do
      [] -> {:ok, ts, mods}
      _ -> {:error, {:invalid, errs}}
    end
  end

  defp module_entries(list, errs) do
    {mods, errs} =
      list
      |> Enum.with_index()
      |> Enum.reduce({[], errs}, fn
        {%{"module_id" => id, "settings" => s}, _i}, {acc, errs}
        when is_binary(id) and is_map(s) ->
          {[{id, s} | acc], errs}

        {%{"module_id" => id}, _i}, {acc, errs} when is_binary(id) ->
          {acc, errs ++ ["module_settings[#{id}]: settings must be an object"]}

        {_other, i}, {acc, errs} ->
          {acc, errs ++ ["module_settings[#{i}]: must be an object with a string module_id"]}
      end)

    mods = Enum.reverse(mods)
    ids = Enum.map(mods, &elem(&1, 0))

    errs =
      ids
      |> Enum.uniq()
      |> Enum.filter(fn id -> Enum.count(ids, &(&1 == id)) > 1 end)
      |> Enum.reduce(errs, fn id, e -> e ++ ["module_settings[#{id}]: duplicate module_id"] end)

    {mods, errs}
  end

  defp key_errors(ts) do
    unknown = Enum.reject(Map.keys(ts), &(&1 in TenantSettings.allowed_keys()))

    errs = Enum.map(unknown, &"tenant_settings.#{&1}: unrecognized key")

    errs =
      case Map.get(ts, "brand_colors") do
        bc when is_map(bc) ->
          errs ++
            (bc
             |> Map.keys()
             |> Enum.reject(&(&1 in Tenant.brand_colors_allowed_keys()))
             |> Enum.map(&"tenant_settings.brand_colors.#{&1}: unrecognized key"))

        _ ->
          errs
      end

    errs
  end

  # ── transaction ─────────────────────────────────────────────────────────

  defp run_import(tenant_id, prefix, actor_id, ts, modules, opts) do
    case Repo.transaction(fn -> apply_bundle(tenant_id, prefix, actor_id, ts, modules, opts) end) do
      {:ok, counts} -> {:ok, counts}
      {:error, {:invalid, _} = e} -> {:error, e}
      {:error, _other} -> {:error, :internal}
    end
  rescue
    exception ->
      Logger.error("tenant_config_bundle.import raised: #{inspect(exception.__struct__)}")
      {:error, :internal}
  end

  defp apply_bundle(tenant_id, prefix, actor_id, ts, modules, opts) do
    tenant =
      Repo.one(from(t in Tenant, where: t.id == ^tenant_id, lock: "FOR UPDATE")) ||
        Repo.rollback(:not_found)

    current = tenant.settings || %{}
    merged = Map.merge(current, ts)
    changed_keys = ts |> Map.keys() |> Enum.filter(&(Map.get(merged, &1) != Map.get(current, &1)))

    ts_errs =
      case changed_keys do
        [] ->
          []

        _ ->
          case Identity.update_tenant_settings(tenant.slug, %{"settings" => merged}) do
            {:ok, _} -> []
            {:error, %Ecto.Changeset{} = cs} -> changeset_messages(cs)
            {:error, _} -> ["tenant_settings: could not be applied"]
          end
      end

    {changed_ids, unchanged, mod_errs} =
      Enum.reduce(modules, {[], 0, []}, fn {id, settings}, {ch, un, errs} ->
        case Repo.get_by(TenantModule, [module_id: id], prefix: prefix) do
          nil ->
            {ch, un, errs ++ ["module_settings[#{id}]: module_not_installed"]}

          %TenantModule{settings: stored}
          when stored == settings or (is_nil(stored) and settings == %{}) ->
            {ch, un + 1, errs}

          %TenantModule{} ->
            case Installs.put_settings(id, settings, prefix: prefix) do
              {:ok, _} -> {[id | ch], un, errs}
              {:error, reason} -> {ch, un, errs ++ [module_error(id, reason)]}
            end
        end
      end)

    case ts_errs ++ mod_errs do
      [] -> :ok
      errs -> Repo.rollback({:invalid, errs})
    end

    changed_ids = Enum.reverse(changed_ids)

    if changed_keys != [] or changed_ids != [] do
      write_audit(tenant, prefix, actor_id, changed_keys, changed_ids, opts)
    end

    %{
      tenant_settings_changed: length(changed_keys),
      modules_changed: length(changed_ids),
      modules_unchanged: unchanged
    }
  end

  defp write_audit(tenant, prefix, actor_id, keys, ids, opts) do
    attrs = %{
      actor_id: actor_id,
      action: "tenant_config_bundle.import",
      resource_type: "tenant_config_bundle",
      resource_id: tenant.id,
      before_state: nil,
      after_state: %{
        "bundle_schema_version" => Keyword.fetch!(opts, :bundle_version),
        "tenant_settings_keys_changed" => Enum.sort(keys),
        "module_ids_changed" => ids
      },
      trace_id: Keyword.get(opts, :trace_id)
    }

    case Audit.insert_entry(Repo, attrs, prefix) do
      {:ok, _} -> :ok
      {:error, _} -> Repo.rollback(:audit_failed)
    end
  end

  defp changeset_messages(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Map.get(:settings, ["validation failed"])
    |> Enum.map(&"tenant_settings: #{&1}")
  end

  defp module_error(id, {:module_not_installed, _}),
    do: "module_settings[#{id}]: module_not_installed"

  defp module_error(id, {:settings_validation_failed, :no_schema}),
    do:
      "module_settings[#{id}]: module has no settings_schema; only an empty settings map is accepted"

  defp module_error(id, {:settings_validation_failed, failures}) when is_list(failures) do
    detail = Enum.map_join(failures, "; ", fn f -> "#{f.field_path}: #{f.constraint}" end)
    "module_settings[#{id}]: #{detail}"
  end

  defp module_error(id, _other), do: "module_settings[#{id}]: settings rejected"
end
