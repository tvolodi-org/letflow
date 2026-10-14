defmodule Letflow.BuildInfo do
  @moduledoc """
  The git commit SHA the running release was built from (ISS-1043, GH #2384).

  The SHA is baked into the runtime image at build time: `deploy/redeploy-qa.sh`
  and `deploy/redeploy-test.sh` pass `--build-arg GIT_SHA="$(git rev-parse HEAD)"`,
  and `deploy/Dockerfile`'s runtime stage turns it into the
  `LETFLOW_BUILD_SHA` environment variable. `config/runtime.exs` reads that
  variable once at boot through `normalize_sha/1` and stores the result under
  `config :letflow, :build_sha`. `GET /health` (`Letflow.Router`) reports it as
  `sha`, so `scripts/uat_preflight.sh` can compare the deployed build against
  `origin/main`.

  Only a lowercase hex string of 7 to 40 characters is accepted, after trimming
  surrounding whitespace. Anything else (unset, empty, uppercase, junk) becomes
  `nil`, which `/health` renders as JSON `null`. The value is a public, unauthenticated
  disclosure, so nothing but the SHA itself is ever reported: no environment name,
  hostname or dependency version.
  """

  @sha_pattern ~r/\A[0-9a-f]{7,40}\z/

  @doc """
  Normalises a raw build-SHA value (normally `System.get_env("LETFLOW_BUILD_SHA")`).

  Returns the trimmed value when it is 7 to 40 lowercase hex characters, `nil` otherwise.

      iex> Letflow.BuildInfo.normalize_sha("e60c9cb9dd986745644a08244d426457c33423fd")
      "e60c9cb9dd986745644a08244d426457c33423fd"

      iex> Letflow.BuildInfo.normalize_sha(" e60c9cb\\n")
      "e60c9cb"

      iex> Letflow.BuildInfo.normalize_sha("E60C9CB")
      nil

      iex> Letflow.BuildInfo.normalize_sha("")
      nil
  """
  @spec normalize_sha(term()) :: String.t() | nil
  def normalize_sha(value) when is_binary(value) do
    trimmed = String.trim(value)
    if Regex.match?(@sha_pattern, trimmed), do: trimmed, else: nil
  end

  def normalize_sha(_value), do: nil

  @doc """
  The build SHA configured for this node (`config :letflow, :build_sha`), or `nil`.

  Re-normalised on read, so a malformed value put into the application
  environment by other means is never reported.
  """
  @spec sha() :: String.t() | nil
  def sha, do: :letflow |> Application.get_env(:build_sha) |> normalize_sha()
end
