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
      written;
    * the slug belongs to a DIFFERENT tenant (a different display name) --
      the slug is taken and the call is refused
      (`platform_call_duplicate_slug`). The step never adopts a tenant it did
      not create;
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

  # The byte caps of the two values, in bytes. They mirror the routes' own
  # request schema (`max_length: 255`), so a value the routes accept is a
  # value the step accepts.
  @max_slug_bytes 255
  @max_name_bytes 255

  @typedoc "The stable code of a refused create."
  @type refusal ::
          :platform_call_arg_invalid
          | :platform_call_duplicate_slug
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

    with :ok <- bounded(slug, @max_slug_bytes),
         :ok <- bounded(name, @max_name_bytes),
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

  defp replay(%{id: id, display_name: display_name}, name) do
    if display_name == name do
      {:ok, id}
    else
      {:error, :platform_call_duplicate_slug}
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

  # The BYTE bound comes first: the value is checked before any comparison
  # with it (SF-01). A value that is not a string at all is refused the same
  # way.
  defp bounded(value, cap) when is_binary(value) do
    if byte_size(value) <= cap, do: :ok, else: {:error, :platform_call_arg_invalid}
  end

  defp bounded(_value, _cap), do: {:error, :platform_call_arg_invalid}
end
