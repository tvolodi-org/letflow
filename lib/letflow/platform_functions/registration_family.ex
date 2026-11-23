defmodule Letflow.PlatformFunctions.RegistrationFamily do
  @moduledoc """
  The registration family's catalogue entry (T-2589, pilot gap G1a of the
  "Register a tenant" pilot; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`, decision (a)).

  One entry, `platform.validate_registration`: it checks the three values a
  registration carries -- the slug, the display name and the e-mail -- and
  returns the normalized slug and the e-mail's domain. It has NO side effect:
  it reads no registry, writes no row, sends nothing out. It exists to prove
  the whole path of a platform step end to end (the catalogue entry, the
  closed registry, the durable dispatcher, the authority fence, the per-step
  result row) before a function with real side effects is registered.

  ## Why the idempotency key is the slug

  The entry's `idempotency_key` names the input that makes a repeat THE SAME
  call. For a registration that is the slug: the slug is the tenant's
  identity, so a second call with the same slug is the same registration --
  with the same data it is a replay (the first result is returned), and with
  DIFFERENT data it is a key reuse and is refused
  (`idempotency_key_reuse`), never a second registration.

  ## The permission

  `:TenantsManage`, the platform atom the tenant lifecycle routes already use.
  A holder of it is the one who may switch on a version that calls this entry
  and the one who may start it.
  """

  alias Letflow.PlatformFunctions.Entry
  alias Letflow.PlatformFunctions.Entry.Input
  alias Letflow.PlatformFunctions.Entry.Output
  alias Letflow.PlatformFunctions.Entry.SideEffect

  @permission :TenantsManage
  @version "1"

  @doc """
  The entries this family declares.
  """
  @spec entries() :: [Entry.t()]
  def entries do
    [validate_registration()]
  end

  defp validate_registration do
    %Entry{
      name: "platform.validate_registration",
      family: :platform,
      version: @version,
      inputs: [
        %Input{name: "slug", type: :string, required: true, source_class: :start},
        %Input{name: "display_name", type: :string, required: true, source_class: :start},
        %Input{name: "email", type: :string, required: true, source_class: :start}
      ],
      outputs: [
        %Output{name: "normalized_slug", type: :string},
        %Output{name: "email_domain", type: :string}
      ],
      permission: @permission,
      side_effects: [
        %SideEffect{
          text: "reads nothing and writes nothing: it only checks the registration values",
          class: :read
        }
      ],
      idempotency_key: ["slug"],
      platform_tenant_only: true
    }
  end
end
