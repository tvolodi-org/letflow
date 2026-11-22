defmodule Letflow.PlatformFunctions.Impl.ValidateRegistration do
  @moduledoc """
  The body of `platform.validate_registration` (T-2589, pilot gap G1a).

  It checks the three values a registration carries and returns the normalized
  slug and the e-mail's domain. It has NO side effect: no registry read, no
  write, nothing sent out. It is the harmless function that proves the whole
  path of a platform step end to end.

  ## The rules

    * the slug: lower case, digits and dashes, 3 to 64 characters, starting
      and ending with a letter or a digit;
    * the display name: not blank, at most 200 characters;
    * the e-mail: one `@`, a dot in the domain, no spaces, at most 254
      characters.

  ## The contract with the dispatcher

  `run/1` never raises (INV-8): a bad value is an `{:error, code}` with a
  stable code, and anything unexpected is caught by the caller
  (`Letflow.PlatformFunctions.Dispatcher`) and recorded as a failed step. The
  outputs are exactly the names the catalogue entry declares
  (`normalized_slug`, `email_domain`); no other key is written.
  """

  @slug_pattern ~r/^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$/
  @email_pattern ~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/

  @max_display_name_length 200
  @max_email_length 254

  @typedoc "The stable code of a refused registration."
  @type refusal ::
          :platform_call_invalid_slug
          | :platform_call_invalid_display_name
          | :platform_call_invalid_email

  @doc """
  Runs the check over the resolved arguments of the step.

  `context` carries the resolved `inputs` (a map of the entry's declared input
  names to their values) and the dispatch context. Returns `{:ok, outputs}`
  with the entry's declared outputs, or `{:error, refusal}`.
  """
  @spec run(map()) :: {:ok, map()} | {:error, refusal()}
  def run(%{inputs: inputs}) when is_map(inputs) do
    slug = Map.get(inputs, "slug")
    display_name = Map.get(inputs, "display_name")
    email = Map.get(inputs, "email")

    with :ok <- validate_slug(slug),
         :ok <- validate_display_name(display_name),
         :ok <- validate_email(email) do
      {:ok,
       %{
         "normalized_slug" => String.trim(slug),
         "email_domain" => email |> String.split("@") |> List.last()
       }}
    end
  end

  def run(_other), do: {:error, :platform_call_invalid_slug}

  defp validate_slug(slug) when is_binary(slug) do
    trimmed = String.trim(slug)

    if trimmed == "" or not Regex.match?(@slug_pattern, trimmed) do
      {:error, :platform_call_invalid_slug}
    else
      :ok
    end
  end

  defp validate_slug(_slug), do: {:error, :platform_call_invalid_slug}

  defp validate_display_name(display_name) when is_binary(display_name) do
    trimmed = String.trim(display_name)

    if trimmed == "" or String.length(trimmed) > @max_display_name_length do
      {:error, :platform_call_invalid_display_name}
    else
      :ok
    end
  end

  defp validate_display_name(_display_name), do: {:error, :platform_call_invalid_display_name}

  defp validate_email(email) when is_binary(email) do
    trimmed = String.trim(email)

    if trimmed == "" or String.length(trimmed) > @max_email_length or
         not Regex.match?(@email_pattern, trimmed) do
      {:error, :platform_call_invalid_email}
    else
      :ok
    end
  end

  defp validate_email(_email), do: {:error, :platform_call_invalid_email}
end
