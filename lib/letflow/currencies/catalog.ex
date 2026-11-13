defmodule Letflow.Currencies.Catalog do
  @moduledoc """
  The platform currency list (REQ-823, GH #4394, design `docs/design/currency-directory.md`),
  read at compile time from `priv/currencies/iso4217.json` (the way `Letflow.Labels.Defaults`
  reads its file). The list is the same for every tenant, so it is not tenant data (INV-1 does
  not apply to it); only the tenant switches are (`Letflow.Currencies`).

  Each entry is `%{code, numeric_code, minor_units, names: %{"ru", "kk", "en"}}`. The platform
  list is changed only by a code change to the JSON file; nothing writes it at run time.
  """

  @path Path.expand("../../../priv/currencies/iso4217.json", __DIR__)
  @external_resource @path
  @file_doc @path |> File.read!() |> Jason.decode!()

  @source Map.fetch!(@file_doc, "source")
  @entries @file_doc
           |> Map.fetch!("currencies")
           |> Enum.map(fn e ->
             %{
               code: Map.fetch!(e, "code"),
               numeric_code: Map.fetch!(e, "numeric_code"),
               minor_units: Map.fetch!(e, "minor_units"),
               names: Map.fetch!(e, "names")
             }
           end)
           |> Enum.sort_by(& &1.code)
  @by_code Map.new(@entries, &{&1.code, &1})

  @default_code "KZT"

  @type entry :: %{
          code: String.t(),
          numeric_code: String.t(),
          minor_units: 0..4,
          names: %{optional(String.t()) => String.t()}
        }

  @doc "The default tenant currency code (D-097): `KZT`."
  @spec default_code() :: String.t()
  def default_code, do: @default_code

  @doc "The `source` header of the file (ISO edition and classifier of the names)."
  @spec source() :: String.t()
  def source, do: @source

  @doc "Every entry, ordered by code."
  @spec all() :: [entry()]
  def all, do: @entries

  @doc "Every code, ordered."
  @spec codes() :: [String.t()]
  def codes, do: Enum.map(@entries, & &1.code)

  @doc "The entry of `code` (exact, upper case), or `nil`."
  @spec get(term()) :: entry() | nil
  def get(code) when is_binary(code), do: Map.get(@by_code, code)
  def get(_code), do: nil

  @doc "True when `code` is a code of the list."
  @spec known?(term()) :: boolean()
  def known?(code), do: get(code) != nil
end
