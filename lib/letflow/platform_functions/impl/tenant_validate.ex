defmodule Letflow.PlatformFunctions.Impl.TenantValidate do
  @moduledoc """
  The body of `tenant.validate` (T-2704, pilot gap G17b): the READ-ONLY first
  step of the registration chain.

  The catalogue declared the entry from the start (the authority rule of gap G2
  needs the name) and the shipped `platform.register_tenant` definition calls it
  as its first node, but it had no body: the dispatcher refused it with
  `:platform_function_not_implemented`, and the engine refused to START any
  instance of the definition. This is the body that closes it.

  It checks, with NO write, what `tenant.create` is about to rely on, using the
  SAME rules, so the chain fails at its first node instead of its second:

    * the slug and the display name are length-bounded first (SF-01: a byte bound, then 255 characters) and are
      strings;
    * the slug is not a reserved one (`Letflow.Identity.Tenant.reserved_slug?/1`);
    * the slug is free, or belongs to the SAME registration (a tenant with the
      same display name -- a repeat of the chain adopts it); a slug that belongs
      to ANOTHER tenant is `platform_call_duplicate_slug`, and a purged tenant
      is `platform_call_tenant_purged`.

  It returns no output. It never raises (INV-8): every failure is an
  `{:error, code}` of the vocabulary `tenant.create` already uses.
  """

  alias Letflow.Identity
  alias Letflow.Identity.Tenant

  @spec run(map()) ::
          {:ok, map()}
          | {:error,
             :platform_call_arg_invalid
             | :platform_call_duplicate_slug
             | :platform_call_tenant_purged}
  def run(%{inputs: inputs}) when is_map(inputs) do
    slug = Map.get(inputs, "slug")
    name = Map.get(inputs, "name")

    with :ok <- bounded(slug),
         :ok <- bounded(name),
         :ok <- not_reserved(slug),
         :ok <- free_or_same(slug, name) do
      {:ok, %{}}
    end
  end

  def run(_other), do: {:error, :platform_call_arg_invalid}

  defp bounded(value), do: Letflow.PlatformFunctions.Impl.TenantCreate.bounded(value)

  defp not_reserved(slug) do
    if Tenant.reserved_slug?(slug), do: {:error, :platform_call_arg_invalid}, else: :ok
  end

  defp free_or_same(slug, name) do
    case Identity.get_tenant_by_slug(slug) do
      {:error, :not_found} ->
        :ok

      {:ok, %{id: id, display_name: display_name}} ->
        cond do
          Identity.tenant_purged?(id) -> {:error, :platform_call_tenant_purged}
          display_name == name -> :ok
          true -> {:error, :platform_call_duplicate_slug}
        end
    end
  end
end
