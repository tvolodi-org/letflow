defmodule Letflow.Signup.EmailPolicy do
  @moduledoc """
  T-1620 (TA-SL3): which e-mail domains the public sign-up refuses. Pure: no database, no clock, so the
  answer depends only on the request and cannot be used to probe whether an address is known (INV-5).

  Blocked = (seed list in `priv/signup/disposable_domains.txt` + the `disposable_domains` setting) minus the
  `allow_domains` setting (allow wins). A domain matches when it, or any parent suffix on a `.` boundary,
  is listed: `a.b.mailinator.com` hits `mailinator.com`, `notmailinator.com` does not.
  """

  @seed_path Path.expand("../../../priv/signup/disposable_domains.txt", __DIR__)
  @external_resource @seed_path

  @seed @seed_path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
        |> MapSet.new()

  @doc "The built-in seed list."
  @spec seed() :: MapSet.t(String.t())
  def seed, do: @seed

  @doc "The lower-case domain of a normalised address, trailing dots stripped (`nil` if there is none)."
  @spec domain(String.t()) :: String.t() | nil
  def domain(email) when is_binary(email) do
    case String.split(email, "@") do
      [_local, domain] ->
        domain
        |> String.downcase()
        |> String.trim_trailing(".")
        |> then(&if(&1 == "", do: nil, else: &1))

      _other ->
        nil
    end
  end

  @doc "`:ok`, or `{:error, :email_not_accepted}` for a blocked domain. `cfg` carries the two list settings."
  @spec check(String.t(), map()) :: :ok | {:error, :email_not_accepted}
  def check(email, cfg) do
    case domain(email) do
      nil ->
        :ok

      domain ->
        suffixes = suffixes(domain)
        allow = cfg |> Map.get(:allow_domains, []) |> MapSet.new()
        block = MapSet.union(@seed, cfg |> Map.get(:disposable_domains, []) |> MapSet.new())

        cond do
          Enum.any?(suffixes, &MapSet.member?(allow, &1)) -> :ok
          Enum.any?(suffixes, &MapSet.member?(block, &1)) -> {:error, :email_not_accepted}
          true -> :ok
        end
    end
  end

  # "a.b.c" -> ["a.b.c", "b.c", "c"]
  defp suffixes(domain) do
    labels = String.split(domain, ".")
    for n <- 0..(length(labels) - 1), do: labels |> Enum.drop(n) |> Enum.join(".")
  end
end
