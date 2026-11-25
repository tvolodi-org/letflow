defmodule Letflow.SecurityProbe.G04Canary do
  @moduledoc """
  G-04 canary/taint harness core (design: `docs/security-probes/G-04-design.md`).

  Pure functions: a deterministic canary per case (`new/2`), the needles a leak
  can take (`needles/1`), the normalisation of a haystack (`variants/1`), the
  scan (`scan/2`), the exceptions list (`load_exceptions/1`) and the verdict
  (`verdict/2`). No clock, no randomness, no network.

  The heart of a canary is its core: 16 chars of lowercase base32 starting with
  `q`, derived from the case id. The core uses only unreserved ASCII letters and
  digits, so percent-encoding, JSON/HTML escaping, `inspect/1`, case folding and
  Unicode normalisation leave it byte-identical; detection keys on the core.
  """

  @kinds ~w(secret credential_url token email name header)a
  @personal ~w(email name)a

  @type canary :: %{case_id: String.t(), kind: atom(), core: String.t(), value: String.t()}
  @type hit :: %{
          case_id: String.t(),
          kind: atom(),
          surface: String.t(),
          locator: String.t(),
          part: String.t(),
          form: atom()
        }

  def kinds, do: @kinds

  @doc "The 16-char core of a case id (always starts with `q`)."
  @spec core(String.t()) :: String.t()
  def core(case_id, salt \\ "") do
    digest = :crypto.hash(:sha256, "letflow-g04:" <> case_id <> salt)
    "q" <> binary_part(String.downcase(Base.encode32(digest, padding: false)), 0, 15)
  end

  @doc """
  A canary of the given kind for a case. `port` only matters for `credential_url`.
  `salt:` gives a second canary of the same case its own core (a case that plants two
  kinds that must be told apart, such as a name that may appear and an email that may not).
  """
  @spec new(String.t(), atom(), keyword()) :: canary()
  def new(case_id, kind, opts \\ []) when kind in @kinds do
    c = core(case_id, Keyword.get(opts, :salt, ""))
    port = Keyword.get(opts, :port, 4000)

    value =
      case kind do
        :secret -> ~s(lfs-#{c}-"\\/%+&é)
        :credential_url -> "https://u#{c}:p#{c}@127.0.0.1:#{port}/x?token=#{c}#f#{c}"
        :token -> "Bearer lft.#{c}.sig"
        :email -> "lfe+#{c}@example.test"
        :name -> "Lfn #{c} Ǆ̈ ﬁ"
        :header -> "lfh-#{c}"
      end

    %{case_id: case_id, kind: kind, core: c, value: value}
  end

  # --- needles ------------------------------------------------------------

  @doc "Every needle form for a canary: `[{form, needle}]` (needles are already normalised)."
  @spec needles(canary()) :: [{atom(), String.t()}]
  def needles(%{core: c, value: v}) do
    windows = for i <- 0..(String.length(c) - 10), do: {:partial, String.slice(c, i, 10)}

    encoded =
      for src <- [v, c], enc <- [&Base.encode64/1, &Base.url_encode64(&1, padding: false)] do
        {:base64, stable_inner(src, enc)}
      end

    hex =
      for src <- [v, c],
          f <- [&Base.encode16(&1, case: :lower), &Base.encode16(&1, case: :upper)] do
        {:hex, f.(src)}
      end

    hashed =
      for src <- [v, c],
          alg <- [:sha256, :sha, :md5],
          f <- [&Base.encode16(&1, case: :lower), &Base.encode64/1] do
        {:hashed, f.(:crypto.hash(alg, src))}
      end

    ([{:exact, normalise(v)}, {:core, c}] ++ windows ++ encoded ++ hex ++ hashed)
    |> Enum.reject(fn {_f, n} -> n == "" end)
    |> Enum.uniq()
  end

  # base64 of `s` at the three byte alignments; keep the stable inner part
  # (drop the first and last 4 output chars) so an embedded value is found.
  defp stable_inner(s, enc) do
    Enum.map_join(["", "x", "xx"], <<0>>, fn pad ->
      out = enc.(pad <> s)
      String.slice(out, 4, max(String.length(out) - 8, 0))
    end)
  end

  # --- normalisation ------------------------------------------------------

  @ignorable [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x00AD]

  @doc "NFKC, drop default-ignorable code points, downcase."
  def normalise(s) when is_binary(s) do
    s =
      if String.valid?(s), do: :unicode.characters_to_nfkc_binary(s), else: s

    s = if is_binary(s), do: s, else: ""

    for(<<c::utf8 <- s>>, c not in @ignorable, into: "", do: <<c::utf8>>)
    |> String.downcase()
  rescue
    _ -> String.downcase(s)
  end

  @doc "Percent-decode `s` leniently (an invalid `%` sequence is left as it is)."
  def pct_decode(s) do
    Regex.replace(~r/%([0-9a-fA-F]{2})/, s, fn _, h -> <<String.to_integer(h, 16)>> end)
  end

  @doc "JSON `\\uXXXX`/`\\/` unescaping plus HTML/XML entity decoding."
  def unescape(s) do
    s
    |> String.replace("\\/", "/")
    |> then(
      &Regex.replace(~r/\\u([0-9a-fA-F]{4})/, &1, fn _, h -> cp(String.to_integer(h, 16)) end)
    )
    |> then(
      &Regex.replace(~r/&#x([0-9a-fA-F]+);/, &1, fn _, h -> cp(String.to_integer(h, 16)) end)
    )
    |> then(&Regex.replace(~r/&#([0-9]+);/, &1, fn _, d -> cp(String.to_integer(d)) end))
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
  end

  defp cp(n) when n in 0..0x10FFFF and n not in 0xD800..0xDFFF, do: <<n::utf8>>
  defp cp(_), do: ""

  # SF-01: bound the input BEFORE any regex, NFKC, unzip or inflate; an excess
  # raises (the probe fails closed) instead of skipping the item, which would be
  # a false-clean result.
  @max_input_bytes 4_194_304
  @max_members 200
  @max_expanded_bytes 16_777_216
  @max_depth 3

  defmodule TooLarge do
    @moduledoc "Raised when a haystack exceeds a bound of the canary scan (fail closed)."
    defexception [:message]
  end

  def max_input_bytes, do: @max_input_bytes
  def max_expanded_bytes, do: @max_expanded_bytes

  @doc """
  All haystack variants of `bytes`: raw, zip members, inflated PDF streams, then
  percent-decoded (two rounds), unescaped, normalised. Every variant is searched.
  Raises `TooLarge` when the input, the zip member count, the declared or actual
  expanded size, the nesting depth or an inflated PDF stream passes its bound.
  """
  @spec variants(binary()) :: [binary()]
  def variants(bytes) when is_binary(bytes) do
    if byte_size(bytes) > @max_input_bytes,
      do: raise(TooLarge, message: "input of #{byte_size(bytes)} bytes over #{@max_input_bytes}")

    bytes
    |> containers(0)
    |> Enum.flat_map(&forms/1)
    |> Enum.uniq()
  end

  defp containers(_, depth) when depth > @max_depth,
    do: raise(TooLarge, message: "container nesting over #{@max_depth}")

  defp containers(<<"PK", 3, 4, _::binary>> = zip, depth) do
    check_zip_listing!(zip)

    members =
      case :zip.unzip(zip, [:memory]) do
        {:ok, files} -> Enum.map(files, fn {_name, data} -> data end)
        _ -> []
      end

    if Enum.sum(Enum.map(members, &byte_size/1)) > @max_expanded_bytes,
      do: raise(TooLarge, message: "zip expands over #{@max_expanded_bytes} bytes")

    [zip | Enum.flat_map(members, &containers(&1, depth + 1))]
  end

  defp containers(<<"%PDF", _::binary>> = pdf, _depth), do: [pdf | pdf_streams(pdf)]
  defp containers(other, _depth), do: [other]

  # The central directory states the member count and sizes before any inflate.
  defp check_zip_listing!(zip) do
    case :zip.list_dir(zip) do
      {:ok, entries} ->
        files = for {:zip_file, _n, info, _c, _o, _s} <- entries, do: info

        if length(files) > @max_members,
          do: raise(TooLarge, message: "zip with #{length(files)} members over #{@max_members}")

        declared = files |> Enum.map(&elem(&1, 1)) |> Enum.sum()

        if declared > @max_expanded_bytes,
          do:
            raise(TooLarge, message: "zip declares #{declared} bytes over #{@max_expanded_bytes}")

      _ ->
        :ok
    end
  end

  defp pdf_streams(pdf) do
    Regex.scan(~r/stream\r?\n(.*?)\r?\nendstream/s, pdf, capture: :all_but_first)
    |> Enum.flat_map(fn [data] -> bounded_inflate(data) end)
  end

  # Inflate in chunks (`:zlib.safeInflate/2`) and stop at the bound (a deflate bomb is 1000:1).
  defp bounded_inflate(data) do
    z = :zlib.open()

    try do
      :zlib.inflateInit(z)
      inflate_loop(z, :zlib.safeInflate(z, data), [], 0)
    catch
      :error, :data_error -> []
      :error, %ErlangError{original: :data_error} -> []
    after
      :zlib.close(z)
    end
  end

  defp inflate_loop(z, {status, chunk}, acc, size) do
    chunk = IO.iodata_to_binary(chunk)
    size = size + byte_size(chunk)

    if size > @max_expanded_bytes,
      do: raise(TooLarge, message: "PDF stream inflates over #{@max_expanded_bytes} bytes")

    acc = [chunk | acc]

    case status do
      :continue -> inflate_loop(z, :zlib.safeInflate(z, []), acc, size)
      :finished -> [acc |> Enum.reverse() |> IO.iodata_to_binary()]
    end
  end

  defp forms(b) do
    d1 = pct_decode(b)
    d2 = pct_decode(d1)
    base = [b, d1, d2]
    un = Enum.map(base, &unescape/1)
    all = base ++ un
    all ++ Enum.map(all, &normalise/1)
  end

  # --- scan ---------------------------------------------------------------

  @doc """
  Scan `items` (`[{surface, locator, part, bytes}]`) for `canary`. Returns one
  hit per (item, form); the strongest form (first in `needles/1`) is reported.
  """
  @spec scan([{String.t(), String.t(), String.t(), binary()}], canary()) :: [hit()]
  def scan(items, canary) do
    needles =
      canary
      |> needles()
      |> Enum.flat_map(fn {form, n} -> n |> String.split(<<0>>) |> Enum.map(&{form, &1}) end)
      |> Enum.reject(fn {_, n} -> n == "" end)

    for {surface, locator, part, bytes} <- items,
        is_binary(bytes),
        vs = variants(bytes),
        form = first_form(needles, vs),
        form != nil do
      %{
        case_id: canary.case_id,
        kind: canary.kind,
        surface: surface,
        locator: locator,
        part: part,
        form: form
      }
    end
  end

  defp first_form(needles, vs) do
    Enum.find_value(needles, fn {form, n} ->
      if Enum.any?(vs, &String.contains?(&1, n)), do: form
    end)
  end

  # --- exceptions ---------------------------------------------------------

  @vocab %{
    "S1" => ~w(body_2xx_authorised body_2xx_other),
    "S2" => ~w(resp_headers),
    "S3" => ~w(detail errors raw_body),
    "S5" => ~w(before_after_state action resource_id trace_id other_column),
    "S7" => ~w(request_headers request_body request_path_query),
    "S10" => ~w(event_variables event_other read_answer)
  }

  @doc "Parts a surface may name; `any` for a surface without a vocabulary."
  def vocabulary(surface), do: Map.get(@vocab, surface, ["any"])

  @doc """
  Load the exceptions file. Returns `{:ok, rows}` or `{:error, reasons}`; the
  loader refuses a `legit` row for a `secret`/`token`, a personal-kind `legit`
  row with `case = *` outside S1/S5/S10 named parts, a personal-kind row on
  S1/S5/S10 whose part is `any` or `other_*`, and a part outside the vocabulary.
  """
  @spec load_exceptions(Path.t() | [String.t()]) :: {:ok, [map()]} | {:error, [String.t()]}
  def load_exceptions(path) when is_binary(path),
    do: path |> File.read!() |> String.split("\n") |> load_exceptions()

  def load_exceptions(lines) when is_list(lines) do
    rows =
      lines
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.map(&parse_row/1)

    errors = rows |> Enum.flat_map(&validate_row/1)
    if errors == [], do: {:ok, rows}, else: {:error, errors}
  end

  defp parse_row(line) do
    [id, type, kinds, surfaces, cases, parts, reason, by] =
      line |> String.split("|") |> Enum.map(&String.trim/1) |> pad(8)

    %{
      id: id,
      type: type,
      kinds: list(kinds),
      surfaces: list(surfaces),
      cases: list(cases),
      parts: list(parts),
      reason: reason,
      decided_by: by
    }
  end

  defp pad(l, n), do: l ++ List.duplicate("", max(n - length(l), 0))
  defp list(s), do: s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp validate_row(%{id: id, type: type} = r) do
    kinds = Enum.map(r.kinds, &String.to_atom/1)
    personal? = Enum.any?(kinds, &(&1 in @personal))

    [
      {type not in ["legit", "baseline"], "#{id}: type must be legit or baseline"},
      {type == "legit" and Enum.any?(kinds, &(&1 in [:secret, :token])),
       "#{id}: a legit row for secret/token is refused"},
      {Enum.any?(kinds, &(&1 not in @kinds)), "#{id}: unknown canary kind"},
      {Enum.any?(r.parts, fn p -> not Enum.any?(r.surfaces, &(p in vocabulary(&1))) end),
       "#{id}: part outside the vocabulary of its surfaces"},
      {type == "legit" and personal? and "*" in r.cases and
         not Enum.all?(r.surfaces, &(&1 in ["S1", "S5", "S10"])),
       "#{id}: a legit personal-kind row with case * only on S1/S5/S10"},
      {type == "legit" and personal? and
         Enum.any?(r.surfaces, &(&1 in ["S1", "S5", "S10"])) and
         Enum.any?(r.parts, &(&1 == "any" or String.starts_with?(&1, "other_"))),
       "#{id}: a legit personal-kind row on S1/S5/S10 must name a non-other part"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp row_matches?(r, hit) do
    Atom.to_string(hit.kind) in r.kinds and hit.surface in r.surfaces and
      ("*" in r.cases or hit.case_id in r.cases) and
      (hit.part in r.parts or ("any" in r.parts and vocabulary(hit.surface) == ["any"]))
  end

  @doc """
  Verdict of `hits` against `rows`. Returns `%{unlisted: hits, stale: rows,
  excused: hits, warnings: rows}`; the probe passes iff `unlisted` and `stale`
  are both empty.
  """
  @spec verdict([hit()], [map()], keyword()) :: map()
  def verdict(hits, rows, opts \\ []) do
    {excused, unlisted} = Enum.split_with(hits, fn h -> Enum.any?(rows, &row_matches?(&1, h)) end)

    # A per-case verdict (`case_id:`) judges staleness only for the rows that
    # name that case; a `*` row is judged by the run-level verdict (no option).
    # Otherwise a case-scoped baseline row would fail every other case as stale.
    judged =
      case Keyword.get(opts, :case_id) do
        nil -> rows
        id -> Enum.filter(rows, &(id in &1.cases))
      end

    {stale, warn} =
      judged
      |> Enum.reject(&(&1.type not in ["baseline", "legit"]))
      |> Enum.reject(fn r -> Enum.any?(hits, &row_matches?(r, &1)) end)
      |> Enum.split_with(&(&1.type == "baseline"))

    %{unlisted: unlisted, stale: stale, excused: excused, warnings: warn}
  end

  # S*: every BASE TABLE of the tenant schema AND of `public` (all but
  # schema_migrations), as row_to_json text. Audit rows are split per column so
  # the E-03/E-08 parts apply (S5); every other table is `S*:<schema>.<table>`.
  @spec database_items(String.t()) :: [{String.t(), String.t(), String.t(), binary()}]
  def database_items(tenant_schema) do
    for prefix <- [tenant_schema, "public"],
        [table] <-
          Letflow.Repo.query!(
            "SELECT table_name FROM information_schema.tables WHERE table_schema = $1 AND table_type = 'BASE TABLE' AND table_name <> 'schema_migrations'",
            [prefix]
          ).rows,
        item <- table_items(prefix, table) do
      item
    end
  end

  defp table_items(prefix, "audit_entries") do
    %{rows: rows} =
      Letflow.Repo.query!(~s|SELECT row_to_json(t)::text FROM "#{prefix}".audit_entries t|)

    for [json] <- rows, {col, val} <- Jason.decode!(json) do
      part =
        cond do
          col in ["before_state", "after_state"] -> "before_after_state"
          col in ["action", "resource_id", "trace_id"] -> col
          true -> "other_column"
        end

      {"S5", "#{prefix}.audit_entries.#{col}", part, to_string_val(val)}
    end
  end

  defp table_items(prefix, table) do
    %{rows: rows} =
      Letflow.Repo.query!(~s|SELECT row_to_json(t)::text FROM "#{prefix}"."#{table}" t|)

    [{"S*:#{table}", "#{prefix}.#{table}", "any", Enum.map_join(rows, "\n", &hd/1)}]
  end

  defp to_string_val(v) when is_binary(v), do: v
  defp to_string_val(v), do: Jason.encode!(v)

  @doc """
  Scan `items` for every canary and judge ONCE PER CASE: the hits of all canaries of one
  case id are pooled before `verdict/3`, so a case-scoped baseline row is stale only if no
  canary of its case hit it. Returns the merged verdict of all cases.
  """
  @spec verdict_cases([tuple()], [canary()], [map()]) :: map()
  def verdict_cases(items, canaries, rows) do
    canaries
    |> Enum.group_by(& &1.case_id)
    |> Enum.map(fn {case_id, cs} ->
      verdict(Enum.flat_map(cs, &scan(items, &1)), rows, case_id: case_id)
    end)
    |> Enum.reduce(%{unlisted: [], stale: [], excused: [], warnings: []}, fn v, acc ->
      Map.merge(acc, v, fn _k, x, y -> x ++ y end)
    end)
  end

  # --- log sink -----------------------------------------------------------

  defmodule LogSink do
    @moduledoc "A `:logger` handler that forwards formatted text of every level to an owner."
    @doc false
    def log(%{level: level, msg: msg, meta: meta}, %{owner: owner, ref: ref}) do
      text =
        case msg do
          {:string, s} -> IO.iodata_to_binary(s)
          {:report, r} -> inspect(r)
          {fmt, args} when is_list(args) -> :io_lib.format(fmt, args) |> IO.iodata_to_binary()
          other -> inspect(other)
        end

      # The production JSON formatter's bytes (S4): the same event, the same code.
      formatted =
        try do
          %{level: level, msg: msg, meta: meta}
          |> Letflow.Obs.Logger.format([])
          |> IO.iodata_to_binary()
        rescue
          _ -> ""
        end

      send(owner, {ref, level, text <> "\n" <> inspect(meta)})
      send(owner, {ref, {:formatted, level}, formatted})
      :ok
    end

    def adding_handler(config), do: {:ok, config}
    def removing_handler(_), do: :ok
  end

  @doc "Attach a sink (level :all); returns `{id, ref}`. Pair with `detach_sink/1`."
  def attach_sink do
    ref = make_ref()
    id = :"g04_sink_#{System.unique_integer([:positive])}"

    :ok =
      :logger.add_handler(id, LogSink, %{
        level: :all,
        config: %{owner: self(), ref: ref},
        owner: self(),
        ref: ref
      })

    {id, ref}
  end

  def detach_sink({id, _ref}), do: :logger.remove_handler(id)

  @doc "Drain the sink mailbox: `[{surface, locator, part, bytes}]` for surface S4."
  def drain_sink({_id, ref}) do
    drain(ref, [])
  end

  defp drain(ref, acc) do
    receive do
      {^ref, {:formatted, level}, text} ->
        drain(ref, [{"S4", "log #{level} (Obs.Logger.format)", "any", text} | acc])

      {^ref, level, text} ->
        drain(ref, [{"S4", "log #{level}", "any", text} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
