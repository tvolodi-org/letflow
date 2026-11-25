defmodule Letflow.PlatformFunctions.Impl.TenantCreate do
  @moduledoc """
  The body of `tenant.create` (T-2590, pilot gap G1b of the "Register a
  tenant" pilot).

  It creates the tenant row of the global tenant registry -- the write that
  today sits in `Letflow.Routers.Tenants` (`POST /tenants`) and in
  `Letflow.Routers.Onboarding` (`POST /onboarding`). That code moved HERE, so
  the route and the platform step call ONE implementation: the route keeps its
  own answer (a duplicate slug is still a 409) and the step gets the same
  write with the idempotency a durable queue needs.

  ## The two callers

    * `create_tenant/1` -- the operator's create, exactly as the routes call
      it today: `{:ok, tenant}`, `{:error, :duplicate_slug}` or
      `{:error, changeset}`. A route answers the duplicate slug with a 409
      and nothing else changes.
    * `run/1` -- the step's body: the same write, but a REPEAT of the same
      call returns the first result instead of failing (see below).

  ## The idempotency

  The catalogue entry's key input is the SLUG: the slug is the tenant's
  identity, so a second call with the same slug is the same registration. A
  repeat therefore changes NOTHING:

    * the tenant with that slug exists and carries the same display name --
      the first result is returned (the same `tenant_id`), and no row is
      written. The tenant is ADOPTED: it may be one this step created, or
      one that already existed. An existing tenant that is not `:active` is
      activated by the chain's next step (`tenant.provision`) -- the same
      activation `POST /tenants/:slug/reactivate` performs, and the
      operator's own authority (`:TenantsManage` in the platform tenant)
      covers it. The ROUTE refuses the same slug with a 409, so the step and
      the route differ here ON PURPOSE: a step must be able to repeat
      itself, a route answers the conflict;
    * the slug belongs to a DIFFERENT tenant (a different display name) --
      the slug is taken and the call is refused
      (`platform_call_duplicate_slug`). The step never takes over a tenant
      it was not asked about;
    * the tenant with that slug was PURGED -- its schema is gone and the
      purge's marker (`tenant_lifecycles.purged_at`) is set -- the call is
      refused (`platform_call_tenant_purged`): a purge is final, and no step
      hands out a tenant that no longer exists;
    * two dispatchers race for the same slug -- the loser sees the duplicate
      and re-reads the row: the same rules as above decide the answer.

  The dispatcher refuses a key REUSE before the body runs (the same key with
  different arguments), so the body only ever sees one shape of arguments.

  ## The bounds

  Both values are tenant-controlled (they come from the start form), so they
  are byte-bounded BEFORE anything else touches them (SF-01): the slug and the
  display name are refused above 255 bytes each, the same cap the routes'
  own request schema applies. The tenant's own changeset checks the rest
  (a reserved slug, a missing name).

  ## What it never does

  It never raises (INV-8): every failure is an `{:error, code}` with a code
  of this module's own vocabulary, and the dispatcher records the code, never
  a message. It writes ONE row (the tenant) -- no schema, no migration, no
  module, no grant: those are the other steps of the chain.
  """

  alias Letflow.Identity

  # ONE length rule for the routes' schema and the chain (T-2704): at most 255
  # CHARACTERS (graphemes, the unit of the routes' `max_length: 255`), behind a
  # byte bound that is checked first so no per-character work runs on a huge value.
  @max_chars 255
  @max_bytes 8192

  @typedoc "The stable code of a refused create."
  @type refusal ::
          :platform_call_arg_invalid
          | :platform_call_duplicate_slug
          | :platform_call_tenant_purged
          | :platform_call_tenant_create_failed

  @doc """
  The operator's create, moved out of the routes: exactly what
  `Letflow.Identity.create_tenant/1` answers, with no change of shape.

  The routes call this, so the tenant row is written in ONE place (here) and
  the platform step's body calls the same code below.
  """
  @spec create_tenant(map()) ::
          {:ok, Identity.Tenant.t()} | {:error, :duplicate_slug} | {:error, Ecto.Changeset.t()}
  def create_tenant(attrs) do
    Identity.create_tenant(attrs)
  end

  @doc """
  Runs the step over the resolved arguments.

  `context` carries the resolved `inputs` (the entry's declared input names
  to their values). Returns `{:ok, %{"tenant_id" => id}}` with the entry's
  declared output, or `{:error, refusal}`.
  """
  @spec run(map()) :: {:ok, map()} | {:error, refusal()}
  def run(%{inputs: inputs}) when is_map(inputs) do
    slug = Map.get(inputs, "slug")
    name = Map.get(inputs, "name")

    with :ok <- bounded(slug),
         :ok <- bounded(name),
         {:ok, tenant_id} <- create_or_replay(slug, name) do
      {:ok, %{"tenant_id" => tenant_id}}
    end
  end

  def run(_other), do: {:error, :platform_call_arg_invalid}

  # The slug decides. The tenant with that slug is the tenant this call is
  # about: the same one means the same call (the first result is returned),
  # a different one means the slug is taken.
  defp create_or_replay(slug, name) do
    case Identity.get_tenant_by_slug(slug) do
      {:ok, tenant} -> replay(tenant, name)
      {:error, :not_found} -> create(slug, name)
    end
  end

  # A PURGED tenant is refused before anything else: its schema is gone and
  # the purge's marker is never cleared, so the step must not hand it out
  # (the chain's `tenant.provision` refuses the same tenant).
  defp replay(%{id: id, display_name: display_name}, name) do
    cond do
      Identity.tenant_purged?(id) -> {:error, :platform_call_tenant_purged}
      display_name == name -> {:ok, id}
      true -> {:error, :platform_call_duplicate_slug}
    end
  end

  defp create(slug, name) do
    case create_tenant(%{"slug" => slug, "display_name" => name}) do
      {:ok, tenant} ->
        {:ok, tenant.id}

      {:error, :duplicate_slug} ->
        # Another dispatcher won the race for this slug. The row that carries
        # it now decides the answer, under the same rules as a replay.
        case Identity.get_tenant_by_slug(slug) do
          {:ok, tenant} -> replay(tenant, name)
          {:error, :not_found} -> {:error, :platform_call_tenant_create_failed}
        end

      {:error, %Ecto.Changeset{}} ->
        {:error, :platform_call_tenant_create_failed}
    end
  end

  @doc """
  The shared length rule: a non-empty string of at most 255 characters
  (graphemes), after a byte bound. `tenant.validate` uses the same function.
  """
  @spec bounded(term()) :: :ok | {:error, :platform_call_arg_invalid}
  def bounded(value) when is_binary(value) do
    if byte_size(value) <= @max_bytes and value != "" and String.length(value) <= @max_chars,
      do: :ok,
      else: {:error, :platform_call_arg_invalid}
  end

  def bounded(_value), do: {:error, :platform_call_arg_invalid}
end
