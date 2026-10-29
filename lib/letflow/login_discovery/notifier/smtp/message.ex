defmodule Letflow.LoginDiscovery.Notifier.Smtp.Message do
  @moduledoc """
  PURE fixed-template composer for the login-discovery mail (REQ-441; design
  `req441-mail-notifier-adapter.md` s2.3). No I/O, no config reads, no mail
  library.

  The only request-derived text is the recipient address (the `To` header,
  validated by an ALLOW-list). Tenant slugs and display names appear only in the
  plain-text body, defanged by `sanitize_text/2`; the only links are
  `tenant_link/2`, built from the operator's validated base URL and the
  URL-encoded slug. Subject and every non-tenant line are fixed strings.
  The body uses `\\n` line breaks; the transport converts them to CRLF.
  """

  alias Letflow.LoginDirectory

  @subject "Your Letflow sign-in options"
  @intro "You asked for the organisations you can sign in to with this email address."
  @outro [
    "If you did not ask for this, you can ignore this message.",
    "Do not forward this message."
  ]
  @overflow "More organisations match this address; contact your administrator."
  @max_tenants 50
  @max_name_chars 80
  @max_slug_chars 64

  @type composed :: %{from: String.t(), to: String.t(), subject: String.t(), body: String.t()}
  @type opts :: %{from: String.t(), base_url: String.t()}

  @doc "The fixed subject."
  @spec subject() :: String.t()
  def subject, do: @subject

  @doc """
  Builds the message. Never raises on any binary input.
  """
  @spec compose(String.t(), [LoginDirectory.tenant_ref(), ...], opts()) ::
          {:ok, composed()} | {:error, :invalid_recipient | :invalid_message}
  def compose(recipient, tenants, %{from: from, base_url: base_url})
      when is_binary(recipient) and is_list(tenants) and is_binary(from) and is_binary(base_url) do
    cond do
      not valid_address?(recipient) ->
        {:error, :invalid_recipient}

      not valid_address?(from) or tenants == [] ->
        {:error, :invalid_message}

      true ->
        with {:ok, blocks} <- blocks(Enum.take(tenants, @max_tenants), base_url) do
          overflow = if length(tenants) > @max_tenants, do: [@overflow], else: []

          body =
            Enum.join(
              [@intro, Enum.join(blocks, "\n\n")] ++ overflow ++ [Enum.join(@outro, "\n")],
              "\n\n"
            )

          {:ok, %{from: from, to: recipient, subject: @subject, body: body}}
        end
    end
  end

  @max_subject_chars 200
  @max_body_chars 20_000

  @doc """
  Builds a message from already-rendered operator text (REQ-584 notification delivery). Pure,
  never raises. `to` and `from` pass `valid_address?/1`; the subject is one line of 1..200
  codepoints (control characters become spaces); the body is 1..20_000 codepoints with newlines
  kept (CRLF/CR normalised to `\\n`), other control characters turned into spaces and bidi or
  zero-width characters removed. Unlike `sanitize_text/2` it does not collapse newlines or
  rewrite `@` and `://`: the stored template is operator wording, not tenant-supplied data.
  A rendered subject over 200 codepoints is refused (`:invalid_message`), not truncated.
  """
  @spec compose_message(map(), %{from: String.t()}) ::
          {:ok, composed()} | {:error, :invalid_recipient | :invalid_message}
  def compose_message(%{to: to, subject: subject, body: body}, %{from: from})
      when is_binary(to) and is_binary(subject) and is_binary(body) and is_binary(from) do
    cond do
      not valid_address?(to) ->
        {:error, :invalid_recipient}

      not valid_address?(from) or not String.valid?(subject) or not String.valid?(body) ->
        {:error, :invalid_message}

      true ->
        subject = subject |> strip_invisible() |> single_line() |> String.trim()
        body = body |> String.replace(["\r\n", "\r"], "\n") |> strip_invisible() |> clean_body()

        if String.length(subject) in 1..@max_subject_chars and
             String.length(body) in 1..@max_body_chars do
          {:ok, %{from: from, to: to, subject: subject, body: body}}
        else
          {:error, :invalid_message}
        end
    end
  end

  def compose_message(%{to: to}, _opts) when not is_binary(to), do: {:error, :invalid_recipient}
  def compose_message(_message, _opts), do: {:error, :invalid_message}

  defp single_line(text), do: String.replace(text, ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u, " ")

  defp clean_body(text),
    do: String.replace(text, ~r/[\x{0000}-\x{0008}\x{000B}-\x{001F}\x{007F}-\x{009F}]/u, " ")

  defp strip_invisible(text) do
    String.replace(
      text,
      ~r/[\x{202A}-\x{202E}\x{2066}-\x{2069}\x{200E}\x{200F}\x{200B}-\x{200D}\x{2060}\x{FEFF}]/u,
      ""
    )
  end

  defp blocks(tenants, base_url) do
    Enum.reduce_while(tenants, {:ok, []}, fn tenant, {:ok, acc} ->
      case block(tenant, base_url) do
        {:ok, block} -> {:cont, {:ok, [block | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp block(%{slug: slug, display_name: name}, base_url)
       when is_binary(slug) and is_binary(name) do
    with {:ok, safe_name} <- sanitize_text(name, @max_name_chars),
         {:ok, safe_slug} <- sanitize_text(slug, @max_slug_chars) do
      {:ok,
       "Organisation: \"#{safe_name}\"\nSign in: #{tenant_link(base_url, slug)}\nCode: #{safe_slug}"}
    end
  end

  defp block(_other, _base_url), do: {:error, :invalid_message}

  @doc """
  Allow-list address check, used for the recipient AND for `LETFLOW_MAIL_FROM`:
  exactly one `@`; local part 1..64 bytes of `[A-Za-z0-9._+-]` with no leading,
  trailing or doubled dot; a dotted domain of hyphen-safe labels (1..63 bytes),
  not ending in an all-digit label; at most 254 bytes in total. Everything else
  (CR, LF, NUL, spaces, quotes, brackets, non-ASCII, IP literals, ...) is false.
  """
  @spec valid_address?(term()) :: boolean()
  def valid_address?(address) when is_binary(address) and byte_size(address) <= 254 do
    case :binary.split(address, "@", [:global]) do
      [local, domain] -> valid_local?(local) and valid_domain?(domain)
      _other -> false
    end
  end

  def valid_address?(_other), do: false

  defp valid_local?(local) do
    Regex.match?(~r/\A[A-Za-z0-9._+-]{1,64}\z/, local) and
      not String.starts_with?(local, ".") and not String.ends_with?(local, ".") and
      not String.contains?(local, "..")
  end

  defp valid_domain?(domain) do
    labels = String.split(domain, ".")

    length(labels) >= 2 and
      Enum.all?(labels, &Regex.match?(~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\z/, &1)) and
      not Regex.match?(~r/\A[0-9]+\z/, List.last(labels))
  end

  @doc """
  Makes tenant text inert: rejects invalid UTF-8; control characters become
  spaces; bidi and zero-width characters are removed; whitespace is collapsed;
  `://` becomes `[://]`, a `www.` word start becomes `www[.]`, `@` becomes `[at]`,
  a double quote becomes a single quote; the result is truncated to `max`
  codepoints (never rejected for length); an empty result is `(unnamed)`.
  """
  @spec sanitize_text(String.t(), pos_integer()) :: {:ok, String.t()} | {:error, :invalid_message}
  def sanitize_text(text, max \\ @max_name_chars)

  def sanitize_text(text, max) when is_binary(text) and is_integer(max) and max > 0 do
    if String.valid?(text) do
      cleaned =
        text
        |> String.replace(~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u, " ")
        |> String.replace(
          ~r/[\x{202A}-\x{202E}\x{2066}-\x{2069}\x{200E}\x{200F}\x{200B}-\x{200D}\x{2060}\x{FEFF}]/u,
          ""
        )
        |> String.replace(~r/\s+/u, " ")
        |> String.trim()
        |> String.replace("://", "[://]")
        |> String.replace(~r/\bwww\./i, "www[.]")
        |> String.replace("@", "[at]")
        |> String.replace("\"", "'")
        |> String.codepoints()
        |> Enum.take(max)
        |> Enum.join()
        |> String.trim()

      {:ok, if(cleaned == "", do: "(unnamed)", else: cleaned)}
    else
      {:error, :invalid_message}
    end
  end

  def sanitize_text(_text, _max), do: {:error, :invalid_message}

  @doc """
  The sign-in link: `<base_url>/?realm=<slug>` with the slug percent-encoded by
  `URI.encode_www_form/1`, so no `/ ? & # %0d @` can alter the link. `base_url`
  is the operator's validated, normalised value (no trailing slash).
  """
  @spec tenant_link(String.t(), String.t()) :: String.t()
  def tenant_link(base_url, slug) when is_binary(base_url) and is_binary(slug) do
    base_url <> "/?realm=" <> URI.encode_www_form(slug)
  end
end
