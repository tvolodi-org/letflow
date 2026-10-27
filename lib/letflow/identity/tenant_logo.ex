defmodule Letflow.Identity.TenantLogo do
  @moduledoc """
  REQ-590 / GH #3338 part 1: the tenant's uploaded logo, one row per tenant schema
  (`tenant_logos`, singleton `id = 1`, no `tenant_id` column: the schema prefix is the tenant).

  Nothing reads the image back yet (REQ-591) and `tenants.settings["logo_url"]` is untouched.
  The feature is behind `:tenant_logo_upload_enabled` (default false).

  `validate/2` runs the checks in a fixed order, the cheap ones first: (1) the declared type is
  in the closed list, (2) the RECEIVED bytes are at most `max_bytes/0`, (3) the leading bytes
  match the declared type, (4) the attachment scanner (the seam `Letflow.Repository.Attachments`
  uses, resolved from `:attachment_scanner`) finds nothing. A scanner that raises or errors
  refuses the upload (INV-8); nothing is stored before every check passed.

  `put/6` and `delete/4` write the row and one audit entry in a single transaction. The audit
  entry holds type, size and sha256 only, never the bytes (INV-4). A database failure of the
  audit write raises, rolls the transaction back and comes out as `{:error, :audit_failed}`.
  Every Repo call carries the caller's `prefix` (INV-1/INV-6).
  """

  use Ecto.Schema

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Ecto.Multi
  alias Letflow.Audit
  alias Letflow.Repo

  @allowed_content_types ["image/png", "image/jpeg", "image/webp"]
  @max_bytes 524_288
  @default_scanner Letflow.Repository.AttachmentScanner.SignatureHeuristic

  @primary_key {:id, :integer, autogenerate: false}
  schema "tenant_logos" do
    field(:content_type, :string)
    field(:byte_size, :integer)
    field(:content_hash, :string)
    field(:data, :binary)
    field(:updated_at, :utc_datetime_usec)
    field(:updated_by, :binary_id)
  end

  @type refusal ::
          :type | :too_large | :signature | {:infected, String.t()} | :scan_unavailable

  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:letflow, :tenant_logo_upload_enabled, false) == true

  @spec allowed_content_types() :: [String.t()]
  def allowed_content_types, do: @allowed_content_types

  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @spec validate(String.t(), binary()) :: :ok | {:error, refusal()}
  def validate(declared_type, bytes) when is_binary(declared_type) and is_binary(bytes) do
    cond do
      declared_type not in @allowed_content_types -> {:error, :type}
      byte_size(bytes) > @max_bytes -> {:error, :too_large}
      not signature_matches?(declared_type, bytes) -> {:error, :signature}
      true -> scan(bytes, declared_type)
    end
  end

  defp signature_matches?("image/png", <<0x89, "PNG\r\n", 0x1A, "\n", _::binary>>), do: true
  defp signature_matches?("image/jpeg", <<0xFF, 0xD8, 0xFF, _::binary>>), do: true

  defp signature_matches?("image/webp", <<"RIFF", _::binary-size(4), "WEBP", _::binary>>),
    do: true

  defp signature_matches?(_type, _bytes), do: false

  defp scan(bytes, type) do
    scanner = Application.get_env(:letflow, :attachment_scanner, @default_scanner)

    case scanner.scan(bytes, type) do
      {:ok, :clean} -> :ok
      {:ok, :infected, verdict} -> {:error, {:infected, verdict}}
      _other -> {:error, :scan_unavailable}
    end
  rescue
    _exception -> {:error, :scan_unavailable}
  catch
    _kind, _reason -> {:error, :scan_unavailable}
  end

  @doc """
  Stores (or replaces) the tenant's logo and appends the `tenant_logo.upload` audit entry in
  one transaction. The bytes must already have passed `validate/2`.
  """
  @spec put(String.t(), String.t(), Ecto.UUID.t() | nil, String.t(), binary(), String.t() | nil) ::
          {:ok, t()} | {:error, :audit_failed}
  def put(prefix, tenant_id, actor_id, type, bytes, trace_id) do
    hash = hash(bytes)

    row = %__MODULE__{
      id: 1,
      content_type: type,
      byte_size: byte_size(bytes),
      content_hash: hash,
      data: bytes,
      updated_at: DateTime.utc_now(),
      updated_by: actor_id
    }

    attrs = %{
      actor_id: actor_id,
      action: "tenant_logo.upload",
      resource_type: "tenant_logo",
      resource_id: tenant_id,
      before_state: nil,
      after_state: %{
        "content_type" => type,
        "byte_size" => byte_size(bytes),
        "content_hash" => hash
      },
      trace_id: trace_id
    }

    Multi.new()
    |> Multi.insert(:logo, row,
      prefix: prefix,
      on_conflict:
        {:replace, [:content_type, :byte_size, :content_hash, :data, :updated_at, :updated_by]},
      conflict_target: :id
    )
    |> Audit.append_multi(:audit, attrs, prefix)
    |> run(tenant_id)
  end

  @doc """
  Removes the tenant's logo and appends the `tenant_logo.delete` audit entry in one
  transaction. `{:error, :not_found}` when the tenant has none.
  """
  @spec delete(String.t(), String.t(), Ecto.UUID.t() | nil, String.t() | nil) ::
          {:ok, t()} | {:error, :not_found | :audit_failed}
  def delete(prefix, tenant_id, actor_id, trace_id) do
    Repo.transaction(fn ->
      query = from(l in __MODULE__, where: l.id == 1, lock: "FOR UPDATE")

      case Repo.one(query, prefix: prefix) do
        nil ->
          Repo.rollback(:not_found)

        %__MODULE__{} = row ->
          attrs = %{
            actor_id: actor_id,
            action: "tenant_logo.delete",
            resource_type: "tenant_logo",
            resource_id: tenant_id,
            before_state: %{
              "content_type" => row.content_type,
              "byte_size" => row.byte_size,
              "content_hash" => row.content_hash
            },
            after_state: nil,
            trace_id: trace_id
          }

          {:ok, _} = Repo.delete(row, prefix: prefix)

          case Audit.insert_entry(Repo, attrs, prefix) do
            {:ok, _entry} -> row
            {:error, _reason} -> Repo.rollback(:audit_failed)
          end
      end
    end)
    |> case do
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> audit_failure(tenant_id, exception)
  end

  defp run(multi, tenant_id) do
    case Repo.transaction(multi) do
      {:ok, %{logo: logo}} ->
        {:ok, logo}

      {:error, step, reason, _changes} ->
        Logger.error(
          "tenant_logo write failed (tenant #{tenant_id}, step #{inspect(step)}): #{inspect(reason)}"
        )

        {:error, :audit_failed}
    end
  rescue
    exception -> audit_failure(tenant_id, exception)
  end

  defp audit_failure(tenant_id, exception) do
    Logger.error(
      "tenant_logo write failed (tenant #{tenant_id}): #{inspect(exception.__struct__)}"
    )

    {:error, :audit_failed}
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @type t :: %__MODULE__{}
end
