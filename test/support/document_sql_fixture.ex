defmodule Letflow.DocumentSqlFixture do
  @moduledoc """
  Raw-SQL helpers for the versioned-documents tests (REQ-500, GH #2588, PR A).

  The tests use these instead of the `Letflow.Documents` context, which does not exist in
  PR A (design D-15): they exercise the tables and the database triggers directly. Every
  statement is schema-qualified with the tenant's own schema name, which comes from
  `Letflow.TenantFixture`, never from a request. Identifiers are passed as strings and cast
  in SQL (`$n::uuid`).
  """

  alias Letflow.Repo

  @hash String.duplicate("a", 64)

  @doc "A provisioned tenant: `%{schema_name: ..., tenant_id: ...}`."
  def provisioned_tenant!(slug_prefix) do
    Letflow.TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-500 Documents Test Tenant"
    )
  end

  @doc "Runs `sql` and returns the result, raising on error."
  def exec!(sql, params \\ []), do: Repo.query!(sql, encode(params))

  # Postgrex sends a `uuid`-typed parameter as its 16 raw bytes, so a canonical UUID string is
  # dumped first. Only 36-character canonical strings are converted: every other string
  # (a type key, a schema name, a hash, JSON text) is sent unchanged.
  defp encode(params), do: Enum.map(params, &encode_param/1)

  defp encode_param(value) when is_binary(value) and byte_size(value) == 36 do
    case Ecto.UUID.cast(value) do
      {:ok, _canonical} -> Ecto.UUID.dump!(value)
      :error -> value
    end
  end

  defp encode_param(value), do: value

  @doc """
  Runs one statement in its own savepoint and reports whether the database accepted it.
  Returns `:accepted` or `{:refused, %Postgrex.Error{}}`. The savepoint keeps the outer
  test transaction usable after a refusal.
  """
  def attempt(sql, params \\ []) do
    case Repo.transaction(fn ->
           case Repo.query(sql, encode(params)) do
             {:ok, _result} -> :accepted
             {:error, error} -> Repo.rollback(error)
           end
         end) do
      {:ok, :accepted} -> :accepted
      {:error, %Postgrex.Error{} = error} -> {:refused, error}
    end
  end

  @doc "The message the database raised, or `nil` when the statement was accepted."
  def refusal_message({:refused, %Postgrex.Error{postgres: %{message: message}}}), do: message
  def refusal_message(:accepted), do: nil

  def table(schema, name), do: ~s("#{schema}"."#{name}")

  def insert_type!(schema, tenant_id, key \\ "purchase_request") do
    exec!(
      """
      INSERT INTO #{table(schema, "document_types")}
        (key, tenant_id, owner_module, numbering_scope, number_prefix, number_pad,
         legal_entity_required, declared_fields, inserted_at)
      VALUES ($1, $2::uuid, 'procurement', 'year', 'PR', 4, false, '{}'::jsonb, now())
      """,
      [key, tenant_id]
    )

    key
  end

  def insert_document!(schema, tenant_id, type_key, opts \\ []) do
    id = Keyword.get_lazy(opts, :id, &Ecto.UUID.generate/0)

    exec!(
      """
      INSERT INTO #{table(schema, "documents")}
        (id, tenant_id, type_key, issuing_org_unit_id, inserted_at)
      VALUES ($1::uuid, $2::uuid, $3, $4::uuid, now())
      """,
      [id, tenant_id, type_key, Ecto.UUID.generate()]
    )

    id
  end

  @doc "Inserts a version directly in `status` (draft unless given). Issued rows get a hash."
  def insert_version!(schema, tenant_id, document_id, version_no, status \\ "draft", opts \\ []) do
    id = Keyword.get_lazy(opts, :id, &Ecto.UUID.generate/0)
    content = Keyword.get(opts, :content, ~s({"amount":"10.00"}))

    issued? = status == "issued"

    exec!(
      """
      INSERT INTO #{table(schema, "document_versions")}
        (id, tenant_id, document_id, version_no, status, content, content_hash,
         issued_at, issued_by, inserted_at)
      VALUES ($1::uuid, $2::uuid, $3::uuid, $4, $5, $6::jsonb, $7,
              CASE WHEN $8::boolean THEN now() END,
              CASE WHEN $8::boolean THEN $9::uuid END, now())
      """,
      [
        id,
        tenant_id,
        document_id,
        version_no,
        status,
        content,
        if(issued?, do: @hash),
        issued?,
        Ecto.UUID.generate()
      ]
    )

    id
  end

  @doc """
  Inserts a version directly in `status` with explicit times (REQ-508 retention tests).
  `issued_at` is a `DateTime` or nil; `opts` takes `:cancelled_at` (DateTime) and
  `:superseded_by` (id of an existing version of the same document). The CHECKs of the
  table allow a direct insert of a superseded or cancelled row.
  """
  def insert_version_at!(
        schema,
        tenant_id,
        document_id,
        version_no,
        status,
        issued_at,
        opts \\ []
      ) do
    id = Keyword.get_lazy(opts, :id, &Ecto.UUID.generate/0)
    cancelled_at = Keyword.get(opts, :cancelled_at)
    cancelled? = status == "cancelled"
    hashed? = status in ["issued", "superseded", "cancelled"]

    exec!(
      """
      INSERT INTO #{table(schema, "document_versions")}
        (id, tenant_id, document_id, version_no, status, content, content_hash,
         issued_at, issued_by, superseded_by_version, cancelled_at, cancelled_by,
         cancel_reason, discarded_at, inserted_at)
      VALUES ($1::uuid, $2::uuid, $3::uuid, $4, $5, '{}'::jsonb,
              CASE WHEN $6::boolean THEN $7 END,
              $8::timestamptz, CASE WHEN $6::boolean THEN $9::uuid END,
              $10::uuid, $11::timestamptz, CASE WHEN $12::boolean THEN $9::uuid END,
              CASE WHEN $12::boolean THEN 'reason' END,
              CASE WHEN $5 = 'discarded' THEN now() END, now())
      """,
      [
        id,
        tenant_id,
        document_id,
        version_no,
        status,
        hashed?,
        @hash,
        issued_at,
        Ecto.UUID.generate(),
        Keyword.get(opts, :superseded_by),
        cancelled_at,
        cancelled?
      ]
    )

    id
  end

  @doc "Sets the retention policy of a type directly (period may be nil)."
  def set_policy!(schema, key, period, from, action) do
    exec!(
      """
      UPDATE #{table(schema, "document_types")}
         SET retention_period_days = $2, retention_from = $3, retention_action = $4
       WHERE key = $1
      """,
      [key, period, from, action]
    )
  end

  @doc "Moves a draft version to issued, the way the context will (status, time, who, hash)."
  def issue!(schema, version_id) do
    exec!(
      """
      UPDATE #{table(schema, "document_versions")}
         SET status = 'issued', issued_at = now(), issued_by = $2::uuid, content_hash = $3
       WHERE id = $1::uuid AND status = 'draft'
      """,
      [version_id, Ecto.UUID.generate(), @hash]
    )
  end

  def set_number!(schema, document_id, number, period \\ "2026") do
    exec!(
      """
      UPDATE #{table(schema, "documents")} SET number = $2, period = $3 WHERE id = $1::uuid
      """,
      [document_id, number, period]
    )
  end

  def set_current!(schema, document_id, version_id) do
    exec!(
      """
      UPDATE #{table(schema, "documents")} SET current_version = $2::uuid WHERE id = $1::uuid
      """,
      [document_id, version_id]
    )
  end

  def version_row(schema, version_id) do
    %{rows: [row]} =
      exec!(
        """
        SELECT status, content::text, content_hash, superseded_by_version::text
          FROM #{table(schema, "document_versions")} WHERE id = $1::uuid
        """,
        [version_id]
      )

    row
  end

  def document_row(schema, document_id) do
    %{rows: [row]} =
      exec!(
        """
        SELECT number, period, legal_entity_id::text, current_version::text
          FROM #{table(schema, "documents")} WHERE id = $1::uuid
        """,
        [document_id]
      )

    row
  end
end
