defmodule Letflow.Test.SandboxAutoMode do
  @moduledoc """
  Shared helper for test files that must run real (non-sandboxed) DDL —
  tenant-schema provisioning, `Ecto.Migrator` replay — against
  `Ecto.Adapters.SQL.Sandbox`'s single shared connection, which cannot run
  that DDL under `:manual`/`{:shared, self()}` mode.

  Implements `lib/letflow/design/iss0580-sandbox-auto-mode-restore-leak.md` —
  build from it, don't invent a different shape. Test-only (`test/support/`,
  compiled under `elixirc_paths(:test)`), **not** referenced from `lib/`,
  **not** added to `lib/letflow/application.ex`'s supervision tree, **not** a
  GenServer — a plain module, matching `Letflow.Test.TenantTemplate`'s and
  `Letflow.TenantFixture`'s established shape for this directory.

  ## The defect this closes (design §0.1)

  `Ecto.Adapters.SQL.Sandbox.mode/2` is a pool-wide global, not scoped to the
  calling process. Six test files used to flip `Letflow.Repo` to `:auto` mode
  inside their own `provisioned_tenant/0` helper and never flip it back — every
  other `async: true` test's `Repo` writes, running concurrently in the same
  suite, then became real, uncommitted-forever commits instead of
  rollback-isolated ones, eventually colliding with an unrelated test's own
  unique-constraint expectations (the `ColumnPromotionTest` AC1 flake ISS-0580
  started from).

  ## Two shapes, not one (design §5)

  `provision!/2` is for the common case: enter `:auto` mode, run some real
  provisioning work, restore `:manual` mode plus a fresh checkout before
  returning — all in the same call, all in the calling test process.

  `enter_auto_mode!/1` and `exit_auto_mode!/1` are for the rarer case where
  `:auto` mode must stay in effect across the rest of a test body (real
  `Task.async` connections racing after the provisioning helper itself has
  already returned — see `test/letflow/engine_concurrency_test.exs`) and can
  only be closed later, from an `on_exit/1` callback running in a different
  process. A single option-flag-driven function would either force
  `provision!/2` to take on `on_exit/1`-registration responsibility it does
  not otherwise need, or force the deferred case's restore to run a checkout
  from the wrong process — see the design doc §5 for the full rejection
  rationale.

  ## Position on inline `:auto` (GH #2415 / #2424, ISS-0113, INV-F-6)

  Inline `Sandbox.mode(Repo, :auto)` in a test file's own `setup` stays an accepted
  convention for `async: false` files; there is no sweep over the existing files.
  The exposure is closed from the victim side by
  `mix letflow.check_async_sandbox_reachability`: every non-`async: true` file that
  calls the `Repo` must use `Letflow.DataCase` or set its own sandbox mode/checkout
  (or go through this module), and a new inline `Sandbox.mode(_, :auto)` outside the
  checker's frozen `@inline_auto_allowlist` fails the build. New tests reach `:auto`
  only through this module.
  """

  alias Ecto.Adapters.SQL.Sandbox

  @doc """
  Enters `:auto` mode on `repo`, runs `fun.()`, then restores `:manual` mode
  plus a fresh `Sandbox.checkout/1` for the calling process — whether `fun.()`
  returns normally or raises (an `after` block, not a fall-through at the end
  of a function body, so a provisioning `assert` failing partway through still
  leaves the pool back in `:manual` mode instead of stuck at `:auto`
  indefinitely).

  Returns `fun.()`'s result unchanged. Any exception `fun.()` raises still
  propagates after the restore has run — ordinary `try/after` semantics.

  For the six `provisioned_tenant/0`-shaped call sites listed in
  `lib/letflow/design/iss0580-sandbox-auto-mode-restore-leak.md` §3.1. Not for
  a caller that needs `:auto` mode to remain in effect after this call
  returns — see `enter_auto_mode!/1`/`exit_auto_mode!/1` for that case.
  """
  @spec provision!(repo :: module(), fun :: (-> result)) :: result when result: term()
  def provision!(repo, fun) do
    Sandbox.mode(repo, :auto)

    try do
      fun.()
    after
      Sandbox.mode(repo, :manual)
      :ok = Sandbox.checkout(repo)
    end
  end

  @doc """
  Enters `:auto` mode on `repo`. Thin, documented wrapper around
  `Sandbox.mode(repo, :auto)` — behaviorally identical to an inline call,
  named so the read site says *why* it is entering `:auto` mode and pairs
  visibly with `exit_auto_mode!/1`.

  Pairs with `exit_auto_mode!/1` registered as the caller's own `on_exit/1`
  callback, not with an immediate restore in the same function call — see
  that function's doc and `test/letflow/engine_concurrency_test.exs` for the
  one call site that needs this shape instead of `provision!/2`.
  """
  @spec enter_auto_mode!(repo :: module()) :: :ok
  def enter_auto_mode!(repo) do
    Sandbox.mode(repo, :auto)
  end

  @doc """
  Restores `:manual` mode on `repo`. Deliberately does **not** call
  `Sandbox.checkout/1` — unlike `provision!/2`'s restore step, this is meant
  to be called from an `on_exit/1` callback, which ExUnit runs in a separate
  process from the original test process. A checkout issued from that
  process would silently target the wrong process's ownership entry instead
  of helping the original test process's connection state (see
  `test/letflow/role_registry_test.exs`'s own moduledoc, "Sandbox mode: what
  ACTUALLY protects against cross-test leakage"). No checkout is needed here
  because, by the time this runs, the calling test process is already
  exiting — nothing in it will issue another `Repo` call afterward.

  Register this as the **first**-registered `on_exit/1` callback (ExUnit runs
  `on_exit/1` callbacks in LIFO order), before any existing cleanup
  `on_exit/1` that still needs `:auto` mode active to commit its own DDL —
  that way the existing cleanup runs first and this restore runs last.
  """
  @spec exit_auto_mode!(repo :: module()) :: :ok
  def exit_auto_mode!(repo) do
    Sandbox.mode(repo, :manual)
  end
end
