defmodule Mix.Tasks.Letflow.Signup.Resume do
  @shortdoc "Resumes public sign-up requests stuck in or failed at the realm or tenant step (T-1593, T-1679)"

  @moduledoc """
  The operator cleanup path of the sign-up realm and tenant-create steps (decision 0085; a timer sweep also resumes stale requests when the sign-up flag is on, see `Letflow.Signup.Sweep`).
  Thin wrapper over `Letflow.Signup.Provisioning.resume/1`: puts retryable `failed` rows back to
  `provisioning`, then runs every unfinished request in the foreground.

  ## Usage

      mix letflow.signup.resume [--tenant-id ID] [--force]

  `--force` also retries rows that failed with a non-retryable code (`demo_cap_reached`, `bad_response`,
  ...). Needs the same environment as the server (flag, provisioner URL, token, hostname domain).
  Output is tenant ids and result codes only -- never an e-mail, token or password.
  """

  use Mix.Task

  alias Letflow.Signup.Provisioning

  @impl Mix.Task
  @spec run(argv :: [String.t()]) :: :ok
  def run(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv, strict: [tenant_id: :string, force: :boolean])

    Mix.Task.run("app.start")

    if Provisioning.configured?() do
      results = Provisioning.resume(opts)

      Enum.each(results, fn {tenant_id, result} ->
        Mix.shell().info("#{tenant_id}: #{format(result)}")
      end)

      Mix.shell().info("signup resume: #{length(results)} request(s) processed")
    else
      Mix.shell().error("signup resume: the flag or the provisioner settings are not configured")
      System.halt(1)
    end

    :ok
  end

  defp format(:ok), do: "completed"
  defp format(:noop), do: "skipped (held by another run or not resumable)"
  defp format({:failed, code}), do: "failed (#{code})"
end
