defmodule Letflow.ProblemReports.ExportConfig do
  @moduledoc """
  T-1948: parser of `LETFLOW_PROBLEM_REPORT_EXPORT_SHA256`, the SHA-256 (64 lowercase hex characters) of
  the read-only token that may read `GET /maintenance/v1/problem-reports`. Unset or blank means the
  mount answers 404 (safe default: off). Called from `config/runtime.exs`. An invalid value is an
  error whose text names the variable and never the value (INV-4).
  """

  @var "LETFLOW_PROBLEM_REPORT_EXPORT_SHA256"

  @doc "The environment variable this parser serves."
  @spec var() :: String.t()
  def var, do: @var

  @owner_list_var "LETFLOW_OWNER_LIST_SHA256"

  @doc "The environment variable of the owner-list (team write) credential, T-1963."
  @spec owner_list_var() :: String.t()
  def owner_list_var, do: @owner_list_var

  @doc """
  T-1963: the owner-list credential hash must differ from the export hash (the export token is
  read-only; the owner-list token writes). The message names no value.
  """
  @spec distinct(String.t() | nil, String.t() | nil) :: :ok | {:error, String.t()}
  def distinct(export_hash, owner_list_hash)
      when is_binary(export_hash) and export_hash == owner_list_hash,
      do:
        {:error,
         "environment variables #{@var} and #{@owner_list_var} must hold different hashes; " <>
           "the values are not echoed."}

  def distinct(_export_hash, _owner_list_hash), do: :ok

  @spec parse_hash(String.t() | nil) :: {:ok, String.t() | nil} | {:error, String.t()}
  def parse_hash(value), do: parse_hash(value, @var)

  @spec parse_hash(String.t() | nil, String.t()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def parse_hash(nil, _var), do: {:ok, nil}

  def parse_hash(value, var) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, nil}

      hash ->
        if Regex.match?(~r/\A[0-9a-f]{64}\z/, hash) do
          {:ok, hash}
        else
          {:error,
           "environment variable #{var} is invalid; the value is not echoed. It takes 64 " <>
             "lowercase hex characters (a SHA-256) or nothing."}
        end
    end
  end
end
