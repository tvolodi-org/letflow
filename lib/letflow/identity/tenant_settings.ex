defmodule Letflow.Identity.TenantSettings do
  @moduledoc """
  Custom `Ecto.Type` for `Letflow.Identity.Tenant`'s `:settings` column.

  REQ-280 (`lib/letflow/design/req280-tenant-settings-store.md` §3) — enforces
  a **closed** top-level key vocabulary for tenant-supplied settings, exactly
  once, at exactly one load/dump/cast boundary, in both directions (write and
  read). The values reach a pre-authentication public endpoint in
  REQ-281/282, so an open-ended settings blob would be an unbounded
  disclosure surface: an unrecognized key must be rejected at write time, not
  filtered at read time.

  Underlying DB representation is still `:map` (JSONB on Postgres) — this
  type only adds the closed-key-set enforcement on top; per-key value
  validation (format/type of each recognized key's value) lives in
  `Letflow.Identity.Tenant.settings_changeset/2`, not here.

  ## Allowed keys

  Exactly seven string keys, no more, no fewer: `"app_name"`, `"logo_url"`,
  `"brand_colors"`, `"locales"`, `"default_locale"`, `"signatory_name"`,
  `"signatory_title"` (REQ-595). String-keyed (not atom)
  to match how a value arrives after JSON-decoding at the (out-of-scope-here)
  HTTP boundary, and this codebase's existing convention for `:map`-typed
  fields reaching the DB as JSONB (e.g. `tasks.form_schema`).
  """

  use Ecto.Type

  @allowed_keys ~w(app_name logo_url brand_colors locales default_locale signatory_name signatory_title)

  @doc false
  @impl Ecto.Type
  @spec type() :: :map
  def type, do: :map

  @doc """
  The closed top-level key vocabulary (REQ-382) — exposes `@allowed_keys` so
  a caller (`Letflow.Routers.TenantSettings`) can partition a raw request
  body into recognized/rejected top-level keys using the exact same list
  `cast/1` itself enforces, rather than an independently-drifting second
  copy of this vocabulary.
  """
  @spec allowed_keys() :: [String.t()]
  def allowed_keys, do: @allowed_keys

  @doc """
  Casts an input map, rejecting the first unrecognized top-level key
  (deterministic: input's own key order) with a typed, field-scoped error
  naming that key. Never silently drops an unknown key, never silently
  stores it.
  """
  @impl Ecto.Type
  @spec cast(term()) :: {:ok, map()} | {:error, keyword()}
  def cast(input) when is_map(input) do
    string_keyed = for {k, v} <- input, into: %{}, do: {to_string(k), v}

    case first_unrecognized_key(string_keyed) do
      nil ->
        {:ok, string_keyed}

      key ->
        {:error,
         [
           message: "unrecognized tenant setting key: #{inspect(key)}",
           validation: :unrecognized_key
         ]}
    end
  end

  def cast(nil), do: {:ok, nil}
  def cast(_other), do: :error

  @doc "Trusts the DB (already validated at write time); passes the stored map through unchanged."
  @impl Ecto.Type
  @spec load(term()) :: {:ok, map() | nil}
  def load(nil), do: {:ok, nil}
  def load(value) when is_map(value), do: {:ok, value}
  def load(_other), do: :error

  @doc """
  Re-validates the same allowed-key set defensively before writing
  (belt-and-braces against any future write path that bypasses the
  changeset, e.g. a raw `Repo.insert!/2` with a struct literal).
  """
  @impl Ecto.Type
  @spec dump(term()) :: {:ok, map() | nil} | :error
  def dump(nil), do: {:ok, nil}

  def dump(value) when is_map(value) do
    string_keyed = for {k, v} <- value, into: %{}, do: {to_string(k), v}

    case first_unrecognized_key(string_keyed) do
      nil -> {:ok, string_keyed}
      _key -> :error
    end
  end

  def dump(_other), do: :error

  defp first_unrecognized_key(map) do
    map
    |> Map.keys()
    |> Enum.find(fn key -> key not in @allowed_keys end)
  end
end
