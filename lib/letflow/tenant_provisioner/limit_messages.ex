defmodule Letflow.TenantProvisioner.LimitMessages do
  @moduledoc """
  T-1621: the code and the en/ru/kk sentence of the 409 that `POST /admin/v1/tenants` answers when a
  create hits a limit. Pure. The text carries no value, count, tenant id or e-mail (INV-4).
  Unknown languages fall back to English.
  """

  @languages ~w(ru kk en)

  @type which :: :demo_cap | :source_budget | :email_domain_budget

  @doc "The `limit` code of the 409 body. `demo_cap_reached` is the name the front door already handles."
  @spec code(which()) :: String.t()
  def code(:demo_cap), do: "demo_cap_reached"
  def code(:source_budget), do: "source_budget_reached"
  def code(:email_domain_budget), do: "email_domain_budget_reached"

  @doc "The sentence for a `limit` code in a language."
  @spec text(String.t(), String.t()) :: String.t()
  def text(code, language) when language in @languages, do: do_text(code, language)
  def text(code, _other), do: do_text(code, "en")

  defp do_text("demo_cap_reached", "en"), do: "the demo tenant limit has been reached"
  defp do_text("demo_cap_reached", "ru"), do: "достигнут лимит демо-пространств"
  defp do_text("demo_cap_reached", "kk"), do: "демо-кеңістіктер лимитіне жетті"

  defp do_text("source_budget_reached", "en"),
    do: "too many demo tenants were created from this source today"

  defp do_text("source_budget_reached", "ru"),
    do: "с этого источника сегодня создано слишком много демо-пространств"

  defp do_text("source_budget_reached", "kk"),
    do: "бүгін осы көзден тым көп демо-кеңістік жасалды"

  defp do_text("email_domain_budget_reached", "en"),
    do: "too many demo tenants were created for this e-mail domain today"

  defp do_text("email_domain_budget_reached", "ru"),
    do: "для этого почтового домена сегодня создано слишком много демо-пространств"

  defp do_text("email_domain_budget_reached", "kk"),
    do: "бүгін осы пошта домені үшін тым көп демо-кеңістік жасалды"
end
