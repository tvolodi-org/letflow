defmodule Mix.Tasks.Letflow.ScopeEnforcement.BreakGlass do
  @shortdoc "Operator break-glass: turns an `on` tenant to shadow or off (GH #2883), dev and CI only"

  @moduledoc """
  The Mix form of `Letflow.Release.ScopeBreakGlass.run/5` (GH #2883). The Mix form is for dev
  and CI hosts ONLY. Do NOT run it on a production host: `Mix.Task.run("app.start")` there boots
  a second full Letflow application (supervision tree, listeners, schedulers) against the same
  database as the running node. On a deployed release use the `rpc` form in
  `docs/runbooks/scope-enforcement-on.md`.

  ## Usage

      mix letflow.scope_enforcement.break_glass <slug> --to shadow|off --reason "<text>" \\
        --operator <label> (--confirm <slug> | --dry-run)

  The `--reason` MUST start with the incident ticket id (`"<ticket id>: <short reason>"`); it is
  what ties the audit entry to the infrastructure access log (a documented rule, not checked here).

  Every switch except `--confirm` / `--dry-run` is mandatory, and exactly one of those two must
  be given. There is no default for `--operator` (no `$USER`): the label is an attestation
  recorded in the audit entry. An unknown switch, a missing value or an extra positional is a
  usage error. Exits with status 1 on an `ERROR` result (0 for `OK` and `DRYRUN`); this task is
  the only place that halts.
  """

  use Mix.Task

  alias Letflow.Release.ScopeBreakGlass

  @usage "usage: mix letflow.scope_enforcement.break_glass <slug> --to shadow|off " <>
           "--reason \"<text>\" --operator <label> (--confirm <slug> | --dry-run)"

  @impl Mix.Task
  @spec run(argv :: [String.t()]) :: :ok
  def run(argv) do
    {slug, to, reason, operator, opts} = parse_args!(argv)

    Mix.Task.run("app.start")

    result = ScopeBreakGlass.run(slug, to, reason, operator, opts)

    case ScopeBreakGlass.exit_code(result) do
      0 -> :ok
      code -> System.halt(code)
    end
  end

  @doc false
  @spec parse_args!(argv :: [String.t()]) ::
          {slug :: String.t(), to :: String.t(), reason :: String.t(), operator :: String.t(),
           opts :: keyword()}
  def parse_args!(argv) do
    {switches, positional, invalid} =
      OptionParser.parse(argv,
        strict: [
          to: :string,
          reason: :string,
          operator: :string,
          confirm: :string,
          dry_run: :boolean
        ]
      )

    with [] <- invalid,
         [slug] <- positional,
         true <- present?(slug),
         to when is_binary(to) <- present_switch(switches, :to),
         reason when is_binary(reason) <- present_switch(switches, :reason),
         operator when is_binary(operator) <- present_switch(switches, :operator),
         {:ok, opts} <- guard_opts(switches) do
      {slug, to, reason, operator, opts}
    else
      _usage_error -> Mix.raise(@usage)
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp present_switch(switches, key) do
    case Keyword.get_values(switches, key) do
      [value] -> if present?(value), do: value
      _missing_or_repeated -> nil
    end
  end

  # Exactly one of `--confirm <slug>` and `--dry-run`.
  defp guard_opts(switches) do
    confirm = present_switch(switches, :confirm)
    dry_run? = Keyword.get(switches, :dry_run, false) == true

    cond do
      dry_run? and is_nil(confirm) and Keyword.get_values(switches, :confirm) == [] ->
        {:ok, [dry_run: true]}

      not dry_run? and is_binary(confirm) ->
        {:ok, [confirm: confirm]}

      true ->
        :error
    end
  end
end
