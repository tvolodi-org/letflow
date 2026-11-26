defmodule Letflow.Obs.QueryLogFilter do
  @moduledoc """
  A primary Logger filter that keeps bound parameters of WRITE statements out of the
  log (INV-4, T-2704).

  With `LOG_LEVEL=debug` Ecto logs every query as `QUERY OK ...\\n<sql> <inspect(params)>`,
  and the parameters of an INSERT/UPDATE/DELETE carry personal values (the registration's
  administrator e-mail and realm travel as instance start variables, event payloads and
  audit rows). The statement text and its header (source, timings) stay; the parameter
  list is replaced by `[redacted]`. A SELECT is left alone: its parameters are lookup
  keys, and a read of a value never persists it.

  Installed once by `Letflow.Application`; it applies before every handler, so the
  production formatter and test captures see the same redacted line.
  """

  @doc "Adds the filter to the primary logger; safe to call twice."
  @spec install() :: :ok
  def install do
    case :logger.add_primary_filter(__MODULE__, {&filter/2, []}) do
      :ok -> :ok
      {:error, {:already_exist, _}} -> :ok
    end
  end

  @doc false
  def filter(%{msg: {:string, data}} = event, _extra) do
    case redact(data) do
      :keep -> event
      redacted -> %{event | msg: {:string, redacted}}
    end
  end

  def filter(event, _extra), do: event

  @doc false
  @spec redact(iodata() | term()) :: :keep | String.t()
  def redact(data) do
    text = IO.iodata_to_binary(data)

    with "QUERY" <> _ <- text,
         [header, sql_and_params] <- String.split(text, "\n", parts: 2),
         true <- write_statement?(sql_and_params) do
      sql =
        case :binary.split(sql_and_params, " [") do
          [sql, _params] -> sql
          [sql] -> sql
        end

      header <> "\n" <> sql <> " [redacted]"
    else
      _ -> :keep
    end
  rescue
    # Not iodata: leave the event alone, never crash the logger.
    ArgumentError -> :keep
  end

  defp write_statement?(sql) do
    String.starts_with?(sql, ["INSERT", "UPDATE", "DELETE"])
  end
end
