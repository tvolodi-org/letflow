defmodule Letflow.Signup.Sweep do
  @moduledoc """
  The sign-up step of the `Letflow.TenantProvisioner.Sweep` tick (decision 0085, addendum T-1701; REQ-803).
  Pure functions, no process: the timer is the existing provisioner sweep.

  With the sign-up flag off (the default) `run/1` does nothing and runs no query. With it on:

  1. **Expire**: `Letflow.Signup.expire_stale/1`, unchanged (one atomic UPDATE; it does not take the submit
     advisory lock).
  2. **Resume** (only when `Provisioning.configured?/0`): `Provisioning.stale_unfinished_ids/1` (three steps,
     claim empty or stale, at most 50 per tick) go through `Provisioning.start_async/1`. `failed` rows are never
     selected and `step_attempts` is never reset, so every request stays bounded by the attempt cap; two runners
     are kept apart by `Provisioning.claim/1`.

  It deletes nothing (rows or realms), creates no tenant itself, and logs counts only, never e-mail or tokens.
  Each part is wrapped so a fault in one does not skip the other (INV-8).
  """

  require Logger

  alias Letflow.Signup
  alias Letflow.Signup.Provisioning

  @spec run(keyword()) :: %{expired: non_neg_integer(), resumed: non_neg_integer()}
  def run(opts \\ []) do
    if Signup.enabled?() do
      now = Keyword.get(opts, :now) || DateTime.utc_now()
      start = Keyword.get(opts, :start, &Provisioning.start_async/1)
      %{expired: expire(now), resumed: resume(now, start)}
    else
      %{expired: 0, resumed: 0}
    end
  end

  defp expire(now) do
    Signup.expire_stale(now)
  rescue
    exception -> failed(:expire, inspect(exception.__struct__))
  catch
    kind, _reason -> failed(:expire, inspect(kind))
  end

  defp resume(now, start) do
    if Provisioning.configured?() do
      ids = Provisioning.stale_unfinished_ids(now)
      Enum.each(ids, start)
      length(ids)
    else
      0
    end
  rescue
    exception -> failed(:resume, inspect(exception.__struct__))
  catch
    kind, _reason -> failed(:resume, inspect(kind))
  end

  defp failed(step, reason) do
    Logger.error("signup sweep step failed (step=#{step}, reason=#{reason})")
    0
  end
end
