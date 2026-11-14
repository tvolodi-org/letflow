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

  @spec parse_hash(String.t() | nil) :: {:ok, String.t() | nil} | {:error, String.t()}
  def parse_hash(nil), do: {:ok, nil}

  def parse_hash(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, nil}

      hash ->
        if Regex.match?(~r/\A[0-9a-f]{64}\z/, hash) do
          {:ok, hash}
        else
          {:error,
           "environment variable #{@var} is invalid; the value is not echoed. It takes 64 " <>
             "lowercase hex characters (a SHA-256) or nothing."}
        end
    end
  end
end
