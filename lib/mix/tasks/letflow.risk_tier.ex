defmodule Mix.Tasks.Letflow.RiskTier do
  @shortdoc "Advisory: is this diff SHORT-eligible? Prints TIER: SHORT or TIER: NOT-SHORT"

  @moduledoc """
  Advisory helper: decides only SHORT vs NOT-SHORT for the diff `base...head`.

      mix letflow.risk_tier [--base REF] [--head REF]

  Defaults are `origin/main` and `HEAD`. The only line on stdout is `TIER: SHORT` or
  `TIER: NOT-SHORT` (it matches `^TIER: (SHORT|NOT-SHORT)$`); the reason for NOT-SHORT goes
  to stderr. It never prints HIGH, DIRECT or FULL: HIGH stays the manual ORCHESTRATOR.md
  section 13 checklist and DIRECT stays section 10. NOT-SHORT means "run the existing FULL
  chain".

  The result is advisory (auditor ruling R11 of GH #2875): SHORT is not in force, and a SHORT
  chain also needs the supervisor's go. Exit status is 0 whenever the line is printed. A
  consumer that sees no matching line, more than one, or a non-zero exit treats the result as
  NOT-SHORT. Any unknown flag, stray argument, unresolvable ref or error also gives NOT-SHORT.

  The allow-list and the rules are in `Letflow.RiskTier`.

  ## Usage note

  Run it from a checkout of the base (origin/main), never from the PR head, with replace
  objects off and the Mix/Erlang/Elixir/Hex environment cleared by prefix:

      cd <checkout of origin/main>
      for v in $(env | cut -d= -f1 | grep -E '^(MIX|ERL|ELIXIR|HEX)_'); do unset "$v"; done
      GIT_NO_REPLACE_OBJECTS=1 mix letflow.risk_tier --base origin/main --head <pr-head-sha>

  `--head` must be a ref present in that checkout (fetch the PR head first); the head's own
  code is never executed. The output does not depend on git config: the git calls pass every
  relevant option as a flag and ignore system and global config.

  `--cd DIR` runs the git calls in another repository (used by the tests).
  """

  use Mix.Task

  @requirements []

  @impl Mix.Task
  def run(args) do
    {line, reason} = decide(args)
    if reason, do: IO.puts(:stderr, "risk_tier: " <> reason)
    IO.puts(line)
    :ok
  end

  defp decide(args) do
    case OptionParser.parse(args,
           strict: [base: :string, head: :string, cd: :string]
         ) do
      {opts, [], []} ->
        verdict =
          Letflow.RiskTier.tier(
            Keyword.get(opts, :base, "origin/main"),
            Keyword.get(opts, :head, "HEAD"),
            cd_opts(opts)
          )

        render(verdict)

      _ ->
        render({:not_short, "bad arguments"})
    end
  rescue
    e -> render({:not_short, "helper error: " <> Exception.message(e)})
  catch
    kind, value -> render({:not_short, "helper error: #{inspect({kind, value})}"})
  end

  defp cd_opts(opts) do
    case Keyword.fetch(opts, :cd) do
      {:ok, dir} -> [cd: dir]
      :error -> []
    end
  end

  defp render(:short), do: {"TIER: SHORT", nil}
  defp render({:not_short, reason}), do: {"TIER: NOT-SHORT", reason}
end
