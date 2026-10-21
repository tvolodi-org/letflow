defmodule Letflow.Documents.BootCheck do
  @moduledoc """
  One-shot boot child that reads the live PostgreSQL version and refuses to start the
  application below the floor in `Letflow.Documents.Preconditions` (REQ-500, GH #2588,
  decision 0056).

  It sits in `Letflow.Supervisor.Infrastructure` right after `Letflow.Repo`. Returning
  `{:error, reason}` from `start_link/1` makes the supervisor fail to start, so the
  application does not come up. On success it returns `:ignore`, so no process is left
  running and no restart is needed. The check is one `SHOW` query, and it is off under
  test (`config :letflow, :document_boot_check, false`) because the test Repo runs in
  Ecto's manual sandbox mode, which a boot-time query cannot use.
  """

  alias Letflow.Documents.Preconditions

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc false
  @spec start_link(keyword()) :: :ignore | {:error, term()}
  def start_link(opts \\ []) do
    if Application.get_env(:letflow, :document_boot_check, true) do
      case verify(Keyword.get(opts, :server_version_num_fun, &server_version_num/0)) do
        :ok -> :ignore
        {:error, reason} -> {:error, reason}
      end
    else
      :ignore
    end
  end

  @doc """
  Runs the floor check against the version `fun` returns. `fun` is a zero-arity function
  that returns `server_version_num` as an integer; the test passes an injected one.
  """
  @spec verify((-> integer())) :: :ok | {:error, {:postgres_too_old, integer()}}
  def verify(fun) when is_function(fun, 0), do: Preconditions.check_server_version_num(fun.())

  @doc "Reads `server_version_num` from the running server."
  @spec server_version_num() :: integer()
  def server_version_num do
    %{rows: [[version]]} = Letflow.Repo.query!("SHOW server_version_num")
    String.to_integer(version)
  end
end
