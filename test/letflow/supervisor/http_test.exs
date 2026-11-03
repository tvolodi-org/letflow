defmodule Letflow.Supervisor.HttpTest do
  @moduledoc """
  REQ-219 (design `req219-supervision-layering.md` §8) AC6: under
  `config/test.exs`'s `start_http: false`, `Letflow.Supervisor.Http` starts
  with zero children -- read-only against the already-running,
  application-supervised singleton, safe `async: true`.

  `async: false`: the second test below mutates the global `:start_http`
  `Application` env key (restored via `on_exit/1`) to exercise the
  gated-ON branch. It deliberately does NOT restart the live, already-
  booted `Letflow.Supervisor.Http` singleton to observe this -- doing so
  would actually bind the real HTTP port via Bandit, reintroducing
  exactly the ISS-0015 port-collision hazard `config/test.exs`'s
  `start_http: false` exists to avoid (this project's two-worktree
  concurrent `mix test` setup). Instead it calls `Letflow.
  Supervisor.Http.init/1` directly -- a plain, side-effect-free function
  call (per `Supervisor.init/2`'s own documented contract: it returns a
  `{:ok, {flags, child_specs}}` tuple, it does not start any process) --
  so the gate's branching logic is verified without spawning anything or
  touching a real socket.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  test "Letflow.Supervisor.Http has zero children under config/test.exs's start_http: false" do
    refute Application.get_env(:letflow, :start_http, true)

    assert Supervisor.which_children(Letflow.Supervisor.Http) == []
  end

  test "AC6: init/1 includes exactly Bandit when :start_http is true, and is empty when false (pure -- no process started)" do
    original_start_http = Application.get_env(:letflow, :start_http, true)
    # config/test.exs deliberately never sets :http_port (ISS-0015 -- Bandit
    # never starts under test, so it never needs one); http_child/0's
    # gated-true branch fetches it via Application.fetch_env!/2, so it must
    # be present for THIS assertion's duration only.
    had_http_port? = Application.get_env(:letflow, :http_port) != nil
    original_http_port = Application.get_env(:letflow, :http_port)

    on_exit(fn ->
      Application.put_env(:letflow, :start_http, original_start_http)

      if had_http_port? do
        Application.put_env(:letflow, :http_port, original_http_port)
      else
        Application.delete_env(:letflow, :http_port)
      end
    end)

    Application.put_env(:letflow, :start_http, true)
    Application.put_env(:letflow, :http_port, 4000)
    {:ok, {_flags, children_when_true}} = Letflow.Supervisor.Http.init(nil)
    # Bandit supplies its own child_spec/1 (overriding the default derived
    # from its module name), whose :id is {Bandit, a_unique_ref} rather than
    # the bare Bandit atom -- confirmed empirically here rather than assumed;
    # match on the tagged-tuple shape instead of pinning the bare atom.
    assert [child_spec] = children_when_true
    assert {Bandit, _unique_ref} = child_spec.id

    Application.put_env(:letflow, :start_http, false)
    {:ok, {_flags, children_when_false}} = Letflow.Supervisor.Http.init(nil)
    assert children_when_false == []
  end
end
