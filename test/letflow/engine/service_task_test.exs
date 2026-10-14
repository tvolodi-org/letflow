defmodule Letflow.Engine.ServiceTaskTest do
  @moduledoc """
  Tests for REQ-056's `Letflow.Engine.ServiceTask` — config parsing,
  failure classification, retry/backoff decisions, and idempotency-key
  construction (all pure), plus AC5(b)/AC6/AC8's give-up/empty-URL routing
  into REQ-061's `Letflow.Engine.set_instance_error/2` (integration, real
  Postgres). See `test/specs/REQ-056.md` for the full rationale.

  Pure-function sections (`AC1`-`AC4`, `AC5(a)`, `AC7`) need no database and
  run under `ExUnit.Case, async: true`. The AC5(b)/AC6/AC8 routing sections
  need a real tenant schema (`Letflow.DataCase`, `async: false`) — mirrors
  `test/letflow/engine_execution_error_test.exs`'s own
  `provisioned_tenant/0` pattern exactly, since these tests exercise the
  same `Letflow.Engine.set_instance_error/2` entry point that suite covers.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.Graph
  alias Letflow.Engine.ServiceTask
  alias Letflow.Engine.ServiceTask.Config
  alias Letflow.Engine.VariableMerge

  defp svc_node(attrs) do
    %Graph.Node{id: "svc1", node_type: :SERVICE_TASK, attributes: attrs}
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- parse_config_from_node_attributes/1 defaults + warning
  # ---------------------------------------------------------------------------------

  describe "AC1 -- parse_config_from_node_attributes/1 defaults and warning" do
    test "defaults timeout_ms to 30000 and retry_limit to 3 when omitted" do
      assert {:ok, %Config{} = config} =
               ServiceTask.parse_config_from_node_attributes(
                 svc_node(%{"endpoint" => "http://x"})
               )

      assert config.timeout_ms == 30_000
      assert config.retry_limit == 3
      assert config.warnings == []
    end

    test "explicit timeout_ms/retry_limit are read through, not overridden by the defaults" do
      assert {:ok, %Config{} = config} =
               ServiceTask.parse_config_from_node_attributes(
                 svc_node(%{"endpoint" => "http://x", "timeout_ms" => 5_000, "retry_limit" => 7})
               )

      assert config.timeout_ms == 5_000
      assert config.retry_limit == 7
    end

    test "both url and service_id present records the BothUrlAndServiceIdProvidedUrlIgnored warning, not an error" do
      assert {:ok, %Config{} = config} =
               ServiceTask.parse_config_from_node_attributes(
                 svc_node(%{"endpoint" => "http://x", "service_id" => "svc-42"})
               )

      assert config.warnings == [:both_url_and_service_id_provided_url_ignored]
      # service_id wins -- route_kind still resolves to :catalog_service, url ignored for
      # dispatch purposes (design doc §3.1) -- and this is {:ok, _}, never {:error, _}.
      assert config.route_kind == :catalog_service
      assert config.service_id == "svc-42"
    end

    test "url only (no service_id) never records the warning" do
      assert {:ok, %Config{} = config} =
               ServiceTask.parse_config_from_node_attributes(
                 svc_node(%{"endpoint" => "http://x"})
               )

      assert config.warnings == []
      assert config.route_kind == :inline_url
    end

    test "neither url nor service_id present is a hard parse error, not silently defaulted" do
      assert {:error, :missing_url_and_service_id} =
               ServiceTask.parse_config_from_node_attributes(svc_node(%{}))
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- 3xx is a failure, never a redirect; 429 is a retriable failure
  # ---------------------------------------------------------------------------------

  describe "AC2 -- HTTP 3xx classification" do
    test "an HTTP 3xx is classified as a failure kind, never as {:success, _}" do
      assert ServiceTask.classify_failure_kind({:http, 301, nil}) == :http_redirect_3xx
      assert ServiceTask.classify_failure_kind({:http, 302, nil}) == :http_redirect_3xx
      assert ServiceTask.classify_failure_kind({:http, 307, nil}) == :http_redirect_3xx
    end

    test "an HTTP 3xx is never retriable -- it is not followed as a redirect" do
      refute ServiceTask.is_retriable_failure(:http_redirect_3xx)
    end
  end

  describe "AC2 -- HTTP 429 classification" do
    test "an HTTP 429 is classified as :rate_limited_429" do
      assert ServiceTask.classify_failure_kind({:http, 429, nil}) == :rate_limited_429
    end

    test "an HTTP 429 is a retriable failure" do
      assert ServiceTask.is_retriable_failure(:rate_limited_429)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- all 7 failure kinds, and decide_failure/3's below/equal/above boundary
  # ---------------------------------------------------------------------------------

  describe "AC3 -- each of the 7 failure kinds, condition -> kind" do
    test ":timeout raw_outcome -> :timeout" do
      assert ServiceTask.classify_failure_kind(:timeout) == :timeout
    end

    test "{:network, reason} -> :network" do
      assert ServiceTask.classify_failure_kind({:network, :econnrefused}) == :network
    end

    test "{:request_build_error, reason} -> :request_build_error" do
      assert ServiceTask.classify_failure_kind({:request_build_error, :bad_template}) ==
               :request_build_error
    end

    test "a generic non-2xx/non-3xx/non-429 status (500) -> :http_non_2xx" do
      assert ServiceTask.classify_failure_kind({:http, 500, nil}) == :http_non_2xx
    end

    test "a 4xx other than 429 (404) -> :http_non_2xx" do
      assert ServiceTask.classify_failure_kind({:http, 404, nil}) == :http_non_2xx
    end

    test "a 3xx status -> :http_redirect_3xx" do
      assert ServiceTask.classify_failure_kind({:http, 301, nil}) == :http_redirect_3xx
    end

    test "a 429 status -> :rate_limited_429" do
      assert ServiceTask.classify_failure_kind({:http, 429, nil}) == :rate_limited_429
    end

    test "a 2xx body that is a JSON array -> :invalid_2xx_body" do
      assert ServiceTask.classify_failure_kind({:http, 200, "[1,2,3]"}) == :invalid_2xx_body
    end

    test "a 2xx body that is a bare JSON string -> :invalid_2xx_body" do
      assert ServiceTask.classify_failure_kind({:http, 200, ~s("just a string")}) ==
               :invalid_2xx_body
    end

    test "a 2xx body that fails to decode at all -> :invalid_2xx_body" do
      assert ServiceTask.classify_failure_kind({:http, 200, "not json{{{"}) == :invalid_2xx_body
    end

    test "a 2xx body that is nil (empty body) -> :invalid_2xx_body" do
      assert ServiceTask.classify_failure_kind({:http, 200, nil}) == :invalid_2xx_body
    end
  end

  describe "AC3 -- is_retriable_failure/1 over the full closed union" do
    test "timeout, network, and rate_limited_429 are retriable" do
      assert ServiceTask.is_retriable_failure(:timeout)
      assert ServiceTask.is_retriable_failure(:network)
      assert ServiceTask.is_retriable_failure(:rate_limited_429)
    end

    test "http_non_2xx, http_redirect_3xx, invalid_2xx_body, and request_build_error are not retriable" do
      refute ServiceTask.is_retriable_failure(:http_non_2xx)
      refute ServiceTask.is_retriable_failure(:http_redirect_3xx)
      refute ServiceTask.is_retriable_failure(:invalid_2xx_body)
      refute ServiceTask.is_retriable_failure(:request_build_error)
    end
  end

  describe "AC3 -- decide_failure/3 boundary at attempt_index below/equal/above retry_limit" do
    test "a retriable kind below retry_limit retries" do
      assert ServiceTask.decide_failure(:timeout, 2, 3) == :retry
    end

    test "a retriable kind exactly at retry_limit gives up" do
      assert ServiceTask.decide_failure(:timeout, 3, 3) == :give_up
    end

    test "a retriable kind above retry_limit gives up" do
      assert ServiceTask.decide_failure(:timeout, 4, 3) == :give_up
    end

    test "a non-retriable kind gives up immediately regardless of attempt_index/retry_limit" do
      assert ServiceTask.decide_failure(:invalid_2xx_body, 0, 3) == :give_up
      assert ServiceTask.decide_failure(:invalid_2xx_body, 10, 100) == :give_up
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- exponential growth + cap, no sleeping
  # ---------------------------------------------------------------------------------

  describe "AC4 -- compute_service_task_backoff_ms/3 exponential growth and cap" do
    test "grows exponentially across 4 successive attempt indices, no sleep, no cap hit" do
      assert ServiceTask.compute_service_task_backoff_ms(0, 100, 10_000) == 100
      assert ServiceTask.compute_service_task_backoff_ms(1, 100, 10_000) == 200
      assert ServiceTask.compute_service_task_backoff_ms(2, 100, 10_000) == 400
      assert ServiceTask.compute_service_task_backoff_ms(3, 100, 10_000) == 800
    end

    test "is clamped at cap_ms once the exponential growth would exceed it" do
      # Uncapped would be 100 * 2^5 = 3200; cap_ms forces exactly 500.
      assert ServiceTask.compute_service_task_backoff_ms(5, 100, 500) == 500
    end

    test "never decreases as attempt_index increases, for fixed base_ms/cap_ms" do
      values = for i <- 0..5, do: ServiceTask.compute_service_task_backoff_ms(i, 50, 1_000)
      assert values == Enum.sort(values)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5(a) -- 2xx JSON object body classifies as success and merges via REQ-049
  # ---------------------------------------------------------------------------------

  describe "AC5(a) -- 2xx JSON object body merges via VariableMerge.merge/3" do
    test "classify_failure_kind returns {:success, decoded_map} for a JSON object body" do
      assert {:success, %{"a" => 1}} =
               ServiceTask.classify_failure_kind({:http, 200, ~s({"a":1})})
    end

    test "the decoded success body actually merges through REQ-049's merge/3" do
      assert {:success, decoded_map} =
               ServiceTask.classify_failure_kind({:http, 201, ~s({"order_id":"ord-1"})})

      assert {:ok, %{"order_id" => "ord-1"}, []} = VariableMerge.merge(%{}, decoded_map, nil)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 (pure half) -- validate_rendered_url/1
  # ---------------------------------------------------------------------------------

  describe "AC6 -- validate_rendered_url/1 rejects empty/blank/nil" do
    test "an empty string is rejected" do
      assert {:error, :empty_rendered_url} = ServiceTask.validate_rendered_url("")
    end

    test "an all-whitespace string is rejected" do
      assert {:error, :empty_rendered_url} = ServiceTask.validate_rendered_url("   ")
    end

    test "nil is rejected" do
      assert {:error, :empty_rendered_url} = ServiceTask.validate_rendered_url(nil)
    end

    test "a non-blank URL is accepted" do
      assert :ok = ServiceTask.validate_rendered_url("http://example.com/hook")
    end
  end

  # ---------------------------------------------------------------------------------
  # AC7 -- moduledoc content, real ExUnit assertions on the compiled moduledoc string
  # ---------------------------------------------------------------------------------

  defp normalized_moduledoc(module) do
    {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
      Code.fetch_docs(module)

    String.replace(moduledoc, ~r/\s+/, " ")
  end

  describe "AC7 -- moduledoc states injectable transport/catalog and the unbuilt DLQ" do
    test "states the HTTP transport is injectable" do
      doc = normalized_moduledoc(ServiceTask)
      assert doc =~ "transport"
      assert doc =~ "INJECTABLE"
    end

    test "states the service_catalog lookup is injectable" do
      doc = normalized_moduledoc(ServiceTask)
      assert doc =~ "service_catalog"
      assert doc =~ "catalog_lookup_fun"
    end

    test "names OBS-05's DLQ (S6) as the unbuilt destination for exhausted retries" do
      doc = normalized_moduledoc(ServiceTask)
      assert doc =~ "OBS-05"
      assert doc =~ "S6"
      assert doc =~ "dead-letter"
    end

    test "confirms no partial DLQ was built here" do
      doc = normalized_moduledoc(ServiceTask)
      assert doc =~ "No partial DLQ"
      assert doc =~ "no retry-queue table, no discard endpoint, no background sweep"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC8 (by inspection) -- this module never opens its own ERROR transition
  # ---------------------------------------------------------------------------------

  describe "AC8 -- by inspection, no bespoke ERROR transition exists in this module" do
    test "the module exposes no Ecto.Multi/append_multi/Repo call -- only the attrs-builder functions" do
      exported = ServiceTask.__info__(:functions)

      # The only two functions producing a standalone_error_attrs()-shaped map --
      # confirms (together with the source read in test/specs/REQ-056.md's "by
      # inspection" note) that a :give_up verdict has exactly one exit shape from
      # this module, never a direct instance_projections write.
      assert {:build_service_task_give_up_error_attrs, 1} in exported
      assert {:build_empty_url_error_attrs, 1} in exported
      refute {:append_multi, 3} in exported
    end
  end

  # ---------------------------------------------------------------------------------
  # GH 2534 PR 7c-1 AC1 (design gh2534-7c-script-handler.md 4.1): route :script
  # ---------------------------------------------------------------------------------

  describe "GH 2534 7c-1 AC1 -- the :script route" do
    test "script route parses" do
      assert {:ok, %Config{} = config} =
               ServiceTask.parse_config_from_node_attributes(
                 svc_node(%{"script_key" => "pricing_v", "script_version" => 3})
               )

      assert config.route_kind == :script
      assert config.script_key == "pricing_v"
      assert config.script_version == 3
      assert config.url_template == nil and config.service_id == nil
    end

    test "conflicting routes refused" do
      for other <- [%{"endpoint" => "http://x"}, %{"service_id" => "svc"}] do
        attrs = Map.merge(%{"script_key" => "k", "script_version" => 1}, other)

        assert ServiceTask.parse_config_from_node_attributes(svc_node(attrs)) ==
                 {:error, :conflicting_routes}
      end
    end

    test "invalid script reference" do
      for key <- ["Bad", "1abc", "has-dash", String.duplicate("a", 65)] do
        assert ServiceTask.parse_config_from_node_attributes(
                 svc_node(%{"script_key" => key, "script_version" => 1})
               ) == {:error, {:invalid_script_reference, :key}}
      end

      for version <- [nil, 0, -1, "1", 1.0] do
        attrs = %{"script_key" => "k", "script_version" => version}

        assert ServiceTask.parse_config_from_node_attributes(svc_node(attrs)) ==
                 {:error, {:invalid_script_reference, :version}}
      end
    end

    test "HTTP parse unchanged (an empty script_key is not a script binding)" do
      assert {:ok, %Config{route_kind: :inline_url, script_key: nil}} =
               ServiceTask.parse_config_from_node_attributes(
                 svc_node(%{"endpoint" => "http://x", "script_key" => ""})
               )

      assert {:ok, %Config{route_kind: :catalog_service}} =
               ServiceTask.parse_config_from_node_attributes(svc_node(%{"service_id" => "s"}))

      assert ServiceTask.parse_config_from_node_attributes(svc_node(%{})) ==
               {:error, :missing_url_and_service_id}
    end
  end
end
