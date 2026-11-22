defmodule Letflow.Security.OutboundHttpInventoryTest do
  @moduledoc """
  G-06 of the team repo's `docs/security-coverage.md` §4: the **outbound
  HTTP-client / call-site AST inventory** and the dispatch-time rules every
  outbound channel must satisfy.

  The coverage map (§3.5, "New outbound channel") asks for a mechanical check
  that inventories *every* request call (`:httpc`, `Req`, `Finch`, `HTTPoison`,
  raw sockets, adapters), classifies the URL source of each, and proves that a
  tenant-influenced URL passes the shared validator **at the actual dispatch
  point**. Before this file no such inventory existed: the SSRF gate was
  checked per channel by hand (and the hand-written
  `test/letflow/webhooks_test.exs` redirect case was a source-text
  assertion, not a behaviour). A new outbound channel, a new HTTP client
  dependency or a second path around the validator would have reached main
  unchecked.

  ## What this probe does

  It is a pure AST scan over `lib/**/*.ex` (`test/**` is excluded: test bodies
  forge URLs on purpose, exactly as the sibling caller scans do). Every rule is
  a pure function over source text, and the real-tree tests and the synthetic
  non-vacuity tests run the SAME function -- the pattern of
  `test/letflow/entities/handler_writes_callers_test.exs`.

    * **I1 inventory** -- the scan finds every outbound call site. The
      inventory must not be empty, and it must contain exactly the seven real
      call sites the registry names (a completeness check: a scan that
      silently finds nothing would otherwise pass every rule below).
    * **I2 registration** -- every discovered call site is registered in
      `@registry` with its URL-source classification. A new outbound channel
      is unregistered, so it fails here until a human classified it.
    * **I3 no stale entries** -- every registry entry still exists in the
      tree. A deleted or renamed call site fails here instead of leaving a
      registry entry that no longer guards anything.
    * **I4 URL source** -- no registered call site takes its URL from a
      response (`response_derived`). A URL that came back from a remote
      server is attacker-influenced and must never be dispatched to.
    * **I5 dispatch-time validation** -- a call site whose URL source is
      tenant-influenced (`tenant_input`, `tenant_config`) must be reached
      only through the shared validator
      (`Letflow.Webhooks.UrlValidator.validate/1,2` -- the DNS-resolving
      variant, NOT `validate_syntactic/1`, which the validator's own moduledoc
      calls advisory write-time feedback only). The rule is path-based: it
      looks at every function of the module that reaches the request, so a
      second path around the validator fails.
    * **I6 one client** -- the only HTTP client in `lib/` is `:httpc`, and
      only `:httpc.request/4` and `:httpc.cancel_request/1` are used. A new
      client (`Req`, `Finch`, `HTTPoison`, `Tesla`), a raw socket
      (`:gen_tcp.connect/3`, `:ssl.connect/3`) or a shell client
      (`System.cmd("curl", ...)`) fails here: an adapter that does not go
      through the shared validator is an SSRF bypass by construction.
    * **I7 redirect policy** -- no call site passes `autoredirect: true` (or
      `follow_redirect: true`) to `:httpc`. `:httpc` does not follow
      redirects unless asked to, so the default is the safe one; a 3xx
      answered by a validated host must not become a request to an
      unvalidated one.

  ## Accepted limits (as in the sibling scans)

  A URL built by a macro, a call through `apply/3` with a computed module, a
  client reached through a variable receiver and a validator called through
  `import` are not seen. `validate_syntactic/1` is deliberately NOT accepted
  as the dispatch-time validator.

  ## Cost

  `@moduletag probe_cost_s: 3` -- one AST pass over `lib/`, no database, no
  network, no clock. Deterministic: the same tree always yields the same
  inventory.
  """

  use ExUnit.Case, async: true

  @moduletag :security_probe
  @moduletag :unit
  @moduletag probe_cost_s: 3

  # ── the registry ────────────────────────────────────────────────────────────────────────────
  # One entry per outbound call site in `lib/`. `url_source` is the coverage
  # map's §3.5 classification:
  #
  #   * `:platform_config`  -- the URL comes from platform/application
  #     configuration (the operator's own network). INV-9 does not require the
  #     shared validator for it.
  #   * `:tenant_config`    -- a tenant sets the URL as configuration.
  #   * `:tenant_input`     -- the URL comes out of tenant data (a document, a
  #     script, a definition, a rendered template).
  #   * `:response_derived` -- the URL came back from a remote server.
  #
  # A `:tenant_config` / `:tenant_input` call site MUST be reached through the
  # shared validator (rule I5). `:response_derived` is refused outright (I4).
  @registry [
    %{
      file: "lib/letflow/webhooks.ex",
      function: "do_dispatch_http/3",
      client: ":httpc",
      url_source: ":tenant_input",
      note: "the subscription's tenant-set target_url"
    },
    %{
      file: "lib/letflow/engine/service_task_dispatcher.ex",
      function: "do_http_transport/3",
      client: ":httpc",
      url_source: ":tenant_input",
      note: "the service task's rendered endpoint URL (tenant script/definition)"
    },
    %{
      file: "lib/letflow/voice/http.ex",
      function: "request/5",
      client: ":httpc",
      url_source: ":platform_config",
      note: "the platform operator's voice provider base URL"
    },
    %{
      file: "lib/letflow/oidc/realm_probe.ex",
      function: "exchange/2",
      client: ":httpc",
      url_source: ":platform_config",
      note: "the platform operator's Keycloak base URL"
    },
    %{
      file: "lib/letflow/signup/realm_users.ex",
      function: "http/3",
      client: ":httpc",
      url_source: ":platform_config",
      note: "the platform operator's realm provisioner base URL"
    },
    %{
      file: "lib/letflow/signup/realm_provisioner.ex",
      function: "http/5",
      client: ":httpc",
      url_source: ":platform_config",
      note: "the platform operator's realm provisioner base URL"
    },
    %{
      file: "lib/letflow/obs/alerts.ex",
      function: "deliver_with_retry/4",
      client: ":httpc",
      url_source: ":platform_config",
      note: "the platform operator's alert hook destination URL"
    }
  ]

  # The only HTTP client `lib/` may use, and the only two of its functions.
  @allowed_httpc_functions [:request, :cancel_request]

  # The clients that would bypass the shared validator. Named so the finding
  # reads as "a second HTTP client appeared", not "an unknown call".
  @foreign_clients %{
    "Req" => :req,
    "Finch" => :finch,
    "HTTPoison" => :httpoison,
    "Tesla" => :tesla
  }

  # Raw sockets: an outbound request that never reaches `:httpc` and therefore
  # never reaches the validator.
  @raw_socket_clients [:gen_tcp, :ssl]

  # The validation seams the product already has: a test-only flag that turns
  # the SSRF gate off so a local test server can be reached. Each one DEFAULTS
  # to true (validation on); the flag name is the allowlist, so a new flag
  # that turns a gate off has to be added here deliberately.
  @ssrf_seam_flags [
    :webhook_ssrf_validation_enabled,
    :service_task_ssrf_validation_enabled,
    :voice_url_validation_enabled
  ]

  # The seven real call sites, named here so I1 can assert the inventory is
  # complete rather than merely non-empty.
  @expected_call_sites [
    {"lib/letflow/webhooks.ex", "do_dispatch_http/3"},
    {"lib/letflow/engine/service_task_dispatcher.ex", "do_http_transport/3"},
    {"lib/letflow/voice/http.ex", "request/5"},
    {"lib/letflow/oidc/realm_probe.ex", "exchange/2"},
    {"lib/letflow/signup/realm_users.ex", "http/3"},
    {"lib/letflow/signup/realm_provisioner.ex", "http/5"},
    {"lib/letflow/obs/alerts.ex", "deliver_with_retry/4"}
  ]

  @rogue_fixture "test/fixtures/security_probes/rogue_outbound_client.ex"

  # ── the scan ────────────────────────────────────────────────────────────────────────────────

  defp lib_sources do
    for path <- Path.wildcard("lib/**/*.ex") |> Enum.sort(),
        path = String.replace(path, "\\", "/"),
        do: {path, File.read!(path)}
  end

  defp parse(source), do: source |> Code.string_to_quoted!(columns: false) |> unpipe()

  # `a |> f(b)` becomes `f(a, b)`, so a piped call is seen with the arity it
  # really has (the same normalisation the sibling caller scans use).
  defp unpipe(ast) do
    Macro.postwalk(ast, fn
      {:|>, _, [lhs, {{:., _, _} = dot, meta, args}]} when is_list(args) ->
        {dot, meta, [lhs | args]}

      {:|>, _, [lhs, {fun, meta, args}]} when is_atom(fun) and is_list(args) ->
        {fun, meta, [lhs | args]}

      node ->
        node
    end)
  end

  @doc """
  Every outbound call site in one source file.

  Each hit is `%{client:, call:, arity:, line:, function:, function_arity:}`,
  where `client` is the client module (`:httpc`, `:req`, ...) and
  `function`/`function_arity` name the enclosing function. A call outside any
  function (a module attribute) has `function: nil`.
  """
  def outbound_calls(source) do
    {_ast, hits} = walk(parse(source), nil, [])
    Enum.reverse(hits)
  end

  # The AST walk. `fun` is the enclosing function's `{name, arity}` or nil.
  defp walk(node, fun, acc)

  defp walk(nil, _fun, acc), do: {nil, acc}
  defp walk(atom, _fun, acc) when is_atom(atom), do: {atom, acc}
  defp walk(binary, _fun, acc) when is_binary(binary), do: {binary, acc}

  defp walk(list, fun, acc) when is_list(list) do
    {rev, acc} =
      Enum.reduce(list, {[], acc}, fn item, {items, acc} ->
        {item, acc} = walk(item, fun, acc)
        {[item | items], acc}
      end)

    {Enum.reverse(rev), acc}
  end

  # A two-element tuple is an AST node (a keyword pair inside a list).
  defp walk({a, b}, fun, acc) do
    {a, acc} = walk(a, fun, acc)
    {b, acc} = walk(b, fun, acc)
    {{a, b}, acc}
  end

  # `&:httpc.request/4` and `&Mod.fun/2` -- a capture of a remote function.
  # This clause comes before the generic one: a capture is a 3-tuple with a
  # list third element too.
  defp walk({:&, _, [{:/, _, [callee, _arity]}]} = node, fun, acc) do
    case callee do
      {{:., dmeta, [receiver, call_name]}, _, []} ->
        acc = record_client_call(receiver, call_name, :capture, dmeta, fun, acc)
        {node, acc}

      _other ->
        {node, acc}
    end
  end

  defp walk({kind, meta, args}, fun, acc) when is_list(args) do
    cond do
      kind in [:def, :defp, :defmacro, :defmacrop] ->
        [head | body] = args
        {name, arity} = head_signature(head)
        {body, acc} = walk(body, {name, arity}, acc)
        {{kind, meta, [head | body]}, acc}

      match?({:ok, _, _}, remote_call(kind)) ->
        {:ok, receiver, call_name} = remote_call(kind)
        acc = record_client_call(receiver, call_name, length(args), meta, fun, acc)
        {args, acc} = walk(args, fun, acc)
        {{kind, meta, args}, acc}

      true ->
        {args, acc} = walk(args, fun, acc)
        {{kind, meta, args}, acc}
    end
  end

  defp walk(other, _fun, acc), do: {other, acc}

  # A remote call node has the shape `{{:., _, [receiver, name]}, _, args}`:
  # its "kind" is the dot call itself, `{:., _, [receiver, name]}`.
  defp remote_call({:., _dmeta, [receiver, call_name]}), do: {:ok, receiver, call_name}
  defp remote_call(_other), do: :error

  defp head_signature({:when, _, [head | _guards]}), do: head_signature(head)

  defp head_signature({name, _, args}) when is_atom(name) and is_list(args),
    do: {name, length(args)}

  defp head_signature(_other), do: {nil, 0}

  # A remote call whose receiver names an HTTP client.
  defp record_client_call(receiver, call_name, arity, meta, fun, acc) do
    case client_of(receiver) do
      nil ->
        acc

      client ->
        {name, f_arity} = fun || {nil, 0}

        hit = %{
          client: client,
          call: call_name,
          arity: arity,
          line: Keyword.get(meta, :line, 0),
          function: name,
          function_arity: f_arity
        }

        [hit | acc]
    end
  end

  defp client_of(receiver) when is_atom(receiver) do
    if receiver == :httpc or receiver in @raw_socket_clients, do: receiver, else: nil
  end

  defp client_of({:__aliases__, _, parts}) do
    case Map.get(@foreign_clients, Atom.to_string(List.last(parts))) do
      nil -> nil
      client -> client
    end
  end

  defp client_of(_other), do: nil

  # ── module analysis (I5) ────────────────────────────────────────────────────────────────────

  @doc """
  The functions of one module: `%{"name/arity" => {kind, body}}`. The key is
  the string form used by the registry, so a registry entry and a function of
  the tree are compared as text.
  """
  def module_functions(source) do
    ast = parse(source)

    ast
    |> ast_defs()
    |> Enum.reduce(%{}, fn {kind, head, body}, acc ->
      {name, arity} = head_signature(head)
      Map.put(acc, fn_key(name, arity), {kind, body})
    end)
  end

  defp fn_key(name, arity), do: "#{name}/#{arity}"

  defp ast_defs(ast) do
    {_ast, defs} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [head | body]} = node, acc
        when kind in [:def, :defp, :defmacro, :defmacrop] ->
          {node, [{kind, head, body} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(defs)
  end

  @doc """
  The local functions each function of the module calls: `%{"name/arity" =>
  ["other/arity"]}`.
  """
  def local_calls(functions) do
    known = Map.keys(functions)

    Map.new(functions, fn {key, {_kind, body}} ->
      {key, called_local_keys(body, known)}
    end)
  end

  defp called_local_keys(body, known) do
    {_ast, keys} =
      Macro.prewalk(body, [], fn
        {name, _meta, args} = node, acc when is_atom(name) and is_list(args) ->
          key = fn_key(name, length(args))
          {node, if(key in known, do: [key | acc], else: acc)}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(keys)
  end

  @doc """
  The functions of the module that reach the shared validator, directly or
  through a local helper.

  `UrlValidator.validate/1,2` is the DNS-resolving variant the validator's
  own moduledoc requires at the dispatch point; `validate_syntactic/1` is
  write-time advisory feedback and is NOT accepted here.
  """
  def validator_bearing(functions, calls) do
    direct =
      for {key, {_kind, body}} <- functions,
          contains_validator_call?(body),
          do: key

    direct
    |> MapSet.new()
    |> close_over(calls)
  end

  # A function that calls a validator-bearing function is itself on the
  # validator's path (Letflow.Voice.Http.post/5 -> validate/1 -> the call).
  defp close_over(set, calls) do
    Enum.reduce(1..(MapSet.size(set) + 1), set, fn _, set ->
      Enum.reduce(calls, set, fn {key, callees}, acc ->
        if key in acc and Enum.any?(callees, &MapSet.member?(acc, &1)) do
          MapSet.put(acc, key)
        else
          acc
        end
      end)
    end)
  end

  defp contains_validator_call?(body) do
    {_ast, found} =
      Macro.prewalk(body, false, fn
        {{:., _, [{:__aliases__, _, parts}, :validate]}, _, _args} = node, acc ->
          {node, acc or Atom.to_string(List.last(parts)) == "UrlValidator"}

        node, acc ->
          {node, acc}
      end)

    found
  end

  @doc """
  The functions of the module that reach `target` (the transitive callers).
  """
  def transitive_callers(calls, target) do
    direct =
      Enum.reduce(calls, MapSet.new(), fn {key, callees}, acc ->
        if target in callees, do: MapSet.put(acc, key), else: acc
      end)

    Enum.reduce(1..(MapSet.size(direct) + 1), direct, fn _, set ->
      Enum.reduce(calls, set, fn {key, callees}, acc ->
        if key in acc and Enum.any?(callees, &MapSet.member?(set, &1)) do
          MapSet.put(acc, key)
        else
          acc
        end
      end)
    end)
  end

  @doc """
  True when the function turns the SSRF gate off through one of the known
  test-only seams. Every seam DEFAULTS to true (the gate is on); the third
  argument of `Application.get_env/3` must be the literal `true`.
  """
  def seam_guarded?(body) do
    {_ast, found} =
      Macro.prewalk(body, false, fn
        {{:., _, [{:__aliases__, _, [:Application]}, :get_env]}, _, [:letflow, flag, true]} = node,
        acc ->
          {node, acc or flag in @ssrf_seam_flags}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # ── the rules, as pure functions over the tree ──────────────────────────────────────────────

  @doc """
  The call sites the tree violates, as a list of human-readable strings. An
  empty list means the tree satisfies every rule.
  """
  def violations(sources, registry \\ @registry) do
    per_file =
      for {path, source} <- sources do
        hits = outbound_calls(source)
        functions = if hits == [], do: %{}, else: module_functions(source)
        {path, hits, hits != [] and redirect_enabled?(source), functions}
      end

    discovered =
      for {path, hits, _redirect, _functions} <- per_file,
          hit <- request_sites(hits),
          do: {path, hit}

    discovered_keys = Enum.map(discovered, fn {path, hit} -> {path, key(hit)} end)
    registry_keys = Enum.map(registry, &{&1.file, &1.function})

    unregistered = discovered_keys -- registry_keys
    stale = registry_keys -- discovered_keys

    violations =
      Enum.map(unregistered, fn {path, key} ->
        "unregistered outbound call site: #{path} #{key}"
      end) ++
        Enum.map(stale, fn {path, key} ->
          "stale registry entry: #{path} #{key} (no such call site)"
        end) ++
        client_violations(discovered) ++
        redirect_violations(per_file) ++
        source_violations(registry) ++
        dispatch_violations(sources, registry)

    Enum.sort(violations)
  end

  defp key(hit), do: "#{hit.function}/#{hit.function_arity}"

  @doc """
  The call sites that ISSUE a request. `:httpc.cancel_request/1` is a
  companion call on an already-issued request, not a request of its own, so
  it is not a call site of the inventory.
  """
  def request_sites(hits) do
    Enum.filter(hits, fn hit -> hit.client != :httpc or hit.call == :request end)
  end

  # I6: one client only.
  defp client_violations(discovered) do
    foreign =
      for {path, hit} <- discovered,
          hit.client != :httpc,
          do:
            "outbound call through #{hit.client} in #{path} line #{hit.line} (only :httpc may issue requests)"

    wrong_httpc =
      for {path, hit} <- discovered,
          hit.client == :httpc,
          hit.call not in @allowed_httpc_functions,
          do:
            "outbound call :httpc.#{hit.call}/#{hit.arity} in #{path} line #{hit.line} (only :httpc.request and :httpc.cancel_request may be called)"

    foreign ++ wrong_httpc
  end

  # I7: the redirect policy. `:httpc` does not follow a redirect unless it is
  # told to, so the safe policy is the absence of the option.
  defp redirect_violations(per_file) do
    enabled =
      for {path, hits, redirect?, _functions} <- per_file,
          redirect?,
          hit <- hits,
          hit.client == :httpc,
          hit.call == :request,
          do: "redirect following is enabled in #{path} (a 3xx would reach an unvalidated host)"

    not_disabled =
      for {path, hits, _redirect?, functions} <- per_file,
          hit <- hits,
          hit.client == :httpc,
          hit.call == :request,
          body = body_of(functions, fn_key(hit.function, hit.function_arity)),
          not redirect_disabled?(body),
          do:
            "#{path} line #{hit.line} does not disable redirect following " <>
              "(:httpc follows up to five redirects unless autoredirect: false is passed)"

    enabled ++ not_disabled
  end

  @doc """
  True when the body passes `autoredirect: false` to `:httpc`.

  The absence of the option is NOT safe: `:httpc` follows up to five
  redirects by default, so a validated target that answers 302 sends the
  next request to a host the validator never saw.
  """
  def redirect_disabled?(body) do
    {_ast, found} =
      Macro.prewalk(body, false, fn
        {:autoredirect, false} = node, _acc -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end

  @doc """
  True when the source asks `:httpc` to follow a redirect.
  """
  def redirect_enabled?(source) do
    {_ast, found} =
      Macro.prewalk(parse(source), false, fn
        {{:., _, _}, _, args} = node, acc when is_list(args) ->
          {node, acc or Enum.any?(args, &redirect_option?/1)}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp redirect_option?({key, value}) when key in [:autoredirect, :follow_redirect],
    do: value == true

  defp redirect_option?(list) when is_list(list), do: Enum.any?(list, &redirect_option?/1)
  defp redirect_option?(_other), do: false

  # I4: the URL source.
  defp source_violations(registry) do
    for entry <- registry,
        entry.url_source == ":response_derived",
        do:
          "outbound call site #{entry.file} #{entry.function} takes its URL from a response (a remote server must never choose the next request target)"
  end

  # I5: the dispatch-time validator on every path to a tenant-influenced
  # request.
  defp dispatch_violations(sources, registry) do
    by_file = Map.new(sources, fn {path, source} -> {path, source} end)

    for entry <- registry,
        entry.url_source in [":tenant_input", ":tenant_config"],
        source = by_file[entry.file],
        problems <- dispatch_problems(source, entry.function),
        do: "#{entry.file} #{entry.function}: #{problems}"
  end

  @doc """
  The problems with the dispatch path to `target` in one source file, where
  `target` is the "name/arity" string of the function that holds the request.
  An empty list means the request is reached only through the shared
  validator.
  """
  def dispatch_problems(source, target) do
    functions = module_functions(source)
    calls = local_calls(functions)
    validators = validator_bearing(functions, calls)

    unless Map.has_key?(functions, target) do
      ["the call site does not exist in the file"]
    else
      direct_callers =
        for {key, callees} <- calls, target in callees, do: key

      guarded_by_validator? =
        MapSet.member?(validators, target) or
          Enum.any?(direct_callers, &MapSet.member?(validators, &1))

      unguarded =
        for caller <- direct_callers,
            not MapSet.member?(validators, caller),
            body = body_of(functions, caller),
            not seam_guarded?(body),
            do: caller

      problems = []

      problems =
        if guarded_by_validator? do
          problems
        else
          ["no path to the request calls Letflow.Webhooks.UrlValidator.validate/1,2"]
        end

      if unguarded == [] do
        problems
      else
        problems ++
          [
            "the request is reachable through a path that does not validate the URL: " <>
              Enum.join(unguarded, ", ")
          ]
      end
    end
  end

  defp body_of(functions, key) do
    case Map.get(functions, key) do
      {_kind, body} -> body
      nil -> []
    end
  end

  # ── real tree ───────────────────────────────────────────────────────────────────────────────

  setup_all do
    {:ok, sources: lib_sources()}
  end

  describe "I1: the inventory" do
    test "the scan set is the whole lib/ tree and is not empty", %{sources: sources} do
      paths = Enum.map(sources, &elem(&1, 0))

      assert length(paths) > 100
      assert "lib/letflow/webhooks.ex" in paths
      assert "lib/letflow/engine/service_task_dispatcher.ex" in paths
    end

    test "every real outbound call site is found, and the inventory is complete", %{
      sources: sources
    } do
      found =
        for {path, source} <- sources,
            hit <- request_sites(outbound_calls(source)),
            do: {path, key(hit)}

      found = MapSet.new(found)

      # the inventory is not empty, and it holds exactly the seven real sites
      assert MapSet.size(found) == length(@expected_call_sites)
      assert Enum.sort(MapSet.to_list(found)) == Enum.sort(@expected_call_sites)
    end

    test "every real outbound call site is a :httpc.request/4 call", %{sources: sources} do
      for {path, source} <- sources,
          hit <- request_sites(outbound_calls(source)) do
        assert hit.client == :httpc, "#{path} line #{hit.line}"
        assert hit.call == :request, "#{path} line #{hit.line}"
        assert hit.arity == 4, "#{path} line #{hit.line}"
      end
    end
  end

  describe "I2-I7: the rules" do
    test "the real tree violates no rule", %{sources: sources} do
      assert violations(sources) == []
    end

    test "the registry is not empty and names the seven call sites" do
      assert length(@registry) == 7

      registered = Enum.map(@registry, &{&1.file, &1.function})
      assert Enum.sort(registered) == Enum.sort(@expected_call_sites)
    end

    test "every registered call site exists in the tree and every tree site is registered", %{
      sources: sources
    } do
      found =
        for {path, source} <- sources,
            hit <- request_sites(outbound_calls(source)),
            do: {path, key(hit)}

      found = MapSet.new(found)
      registered = MapSet.new(@registry, &{&1.file, &1.function})

      assert MapSet.difference(found, registered) |> MapSet.to_list() == []
      assert MapSet.difference(registered, found) |> MapSet.to_list() == []
    end
  end

  # ── non-vacuity: the seeded failing case and the synthetic sources ──────────────────────────

  describe "non-vacuity" do
    test "the seeded failing case (the rogue fixture) is flagged by every rule it breaks" do
      source = File.read!(@rogue_fixture)

      # the fixture really is in the tree and really contains the defects
      assert File.exists?(@rogue_fixture)
      assert source =~ "Req.get("
      assert source =~ "autoredirect: true"

      # I1: the scan finds the fixture's call sites
      hits = outbound_calls(source)
      assert Enum.any?(hits, &(&1.client == :req))
      assert Enum.any?(hits, &(&1.client == :httpc))

      # I6: a foreign client is a violation
      assert Enum.any?(
               client_violations(for hit <- outbound_calls(source), do: {@rogue_fixture, hit}),
               &(&1 =~ "only :httpc")
             )

      # I7: a redirect that follows is a violation
      assert Enum.any?(
               redirect_violations([{@rogue_fixture, outbound_calls(source), true, %{}}]),
               &(&1 =~ "redirect")
             )

      # I5: a tenant-influenced request with no validator on its path is a violation
      assert dispatch_problems(source, "rogue_fetch/1") != []
      assert Enum.any?(dispatch_problems(source, "rogue_fetch/1"), &(&1 =~ "UrlValidator"))
    end

    test "the rogue fixture is not a compiled module (it is text, so it cannot break the build)" do
      assert @rogue_fixture =~ "test/fixtures/"
      refute @rogue_fixture =~ "test/support/"
    end

    test "I6: every foreign client and raw socket is flagged" do
      for snippet <- [
            "defmodule A do\n  def f, do: Req.get(\"https://x\")\nend",
            "defmodule A do\n  def f, do: Finch.request(:get, \"https://x\")\nend",
            "defmodule A do\n  def f, do: HTTPoison.get(\"https://x\")\nend",
            "defmodule A do\n  def f, do: Tesla.get(\"https://x\")\nend",
            "defmodule A do\n  def f, do: :gen_tcp.connect(~c\"h\", 443, [])\nend",
            "defmodule A do\n  def f, do: :ssl.connect(~c\"h\", 443, [])\nend"
          ] do
        hits = outbound_calls(snippet)

        assert hits != [], snippet
        assert Enum.any?(hits, &(&1.client != :httpc)), snippet
      end
    end

    test "I6: a capture of a foreign client's function is flagged" do
      hits = outbound_calls("defmodule A do\n  def f, do: &Req.get/1\nend")

      assert Enum.any?(hits, &(&1.client == :req))
    end

    test "I7: autoredirect: true is flagged, and the safe forms are not" do
      assert redirect_enabled?(
               "defmodule A do\n  def f, do: :httpc.request(:get, r, [autoredirect: true], [])\nend"
             )

      assert redirect_enabled?(
               "defmodule A do\n  def f, do: :httpc.request(:get, r, [{:follow_redirect, true}], [])\nend"
             )

      refute redirect_enabled?(
               "defmodule A do\n  def f, do: :httpc.request(:get, r, [autoredirect: false], [])\nend"
             )

      refute redirect_enabled?(
               "defmodule A do\n  def f, do: :httpc.request(:get, r, [{:timeout, 5_000}], [])\nend"
             )
    end

    test "I5: a tenant-influenced request without the validator on its path is flagged" do
      unguarded = """
      defmodule A do
        def fetch(url), do: do_fetch(url)

        defp do_fetch(url) do
          :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 5_000}], [])
        end
      end
      """

      problems = dispatch_problems(unguarded, "do_fetch/1")
      assert Enum.any?(problems, &(&1 =~ "UrlValidator"))

      guarded = """
      defmodule A do
        alias Letflow.Webhooks.UrlValidator

        def fetch(url) do
          case UrlValidator.validate(url) do
            :ok -> do_fetch(url)
            {:error, _} -> {:error, :target_url_not_allowed}
          end
        end

        defp do_fetch(url) do
          :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 5_000}], [])
        end
      end
      """

      assert dispatch_problems(guarded, "do_fetch/1") == []
    end

    test "I5: validate_syntactic/1 is NOT accepted as the dispatch-time validator" do
      syntactic_only = """
      defmodule A do
        alias Letflow.Webhooks.UrlValidator

        def fetch(url) do
          case UrlValidator.validate_syntactic(url) do
            :ok -> do_fetch(url)
            {:error, _} -> {:error, :target_url_not_allowed}
          end
        end

        defp do_fetch(url) do
          :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 5_000}], [])
        end
      end
      """

      assert dispatch_problems(syntactic_only, "do_fetch/1") != []
    end

    test "I5: a second path around the validator is flagged" do
      bypass = """
      defmodule A do
        alias Letflow.Webhooks.UrlValidator

        def fetch(url) do
          case UrlValidator.validate(url) do
            :ok -> do_fetch(url)
            {:error, _} -> {:error, :target_url_not_allowed}
          end
        end

        def fetch_unchecked(url), do: do_fetch(url)

        defp do_fetch(url) do
          :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 5_000}], [])
        end
      end
      """

      problems = dispatch_problems(bypass, "do_fetch/1")
      assert Enum.any?(problems, &(&1 =~ "does not validate the URL"))
    end

    test "I5: the known test-only seam is accepted, an unknown flag is not" do
      seam = """
      defmodule A do
        def fetch(url) do
          if Application.get_env(:letflow, :webhook_ssrf_validation_enabled, true) do
            do_fetch(url)
          else
            do_fetch(url)
          end
        end

        defp do_fetch(url) do
          :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 5_000}], [])
        end
      end
      """

      # the seam does not excuse a missing validator entirely (I5a still fails)
      assert Enum.any?(dispatch_problems(seam, "do_fetch/1"), &(&1 =~ "UrlValidator"))

      unknown_flag = String.replace(seam, ":webhook_ssrf_validation_enabled", ":my_own_flag")

      assert Enum.any?(
               dispatch_problems(unknown_flag, "do_fetch/1"),
               &(&1 =~ "does not validate")
             )
    end

    test "I4: a response-derived URL is refused" do
      registry = [
        %{
          file: "lib/x.ex",
          function: "f/1",
          client: ":httpc",
          url_source: ":response_derived",
          note: "n/a"
        }
      ]

      violations = violations([], registry)
      assert Enum.any?(violations, &(&1 =~ "response"))
    end

    test "I2/I3: an unregistered call site and a stale registry entry are both flagged" do
      sources = [{"lib/a.ex", "defmodule A do\n  def f, do: Req.get(\"https://x\")\nend"}]

      registry = [
        %{
          file: "lib/gone.ex",
          function: "g/1",
          client: ":httpc",
          url_source: ":platform_config",
          note: "n/a"
        }
      ]

      violations = violations(sources, registry)

      assert Enum.any?(violations, &(&1 =~ "unregistered outbound call site"))
      assert Enum.any?(violations, &(&1 =~ "stale registry entry"))
    end
  end
end
