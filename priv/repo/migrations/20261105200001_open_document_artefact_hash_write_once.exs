# Letflow.Repo.Migrations.OpenDocumentArtefactHashWriteOnce
#
# REQ-623 / GH #3474 (decision 0075 R3): the one opening of `document_versions.artefact_hash`.
# `guard_document_versions()` is replaced with the 20261022100002 body plus one branch: an
# issued row that stays issued may set `artefact_hash` from NULL to a 64-character lowercase hex
# value, and nothing else on it may change (the jsonb diff below the branch refuses every other
# column). value -> value, value -> NULL and any other issued -> issued update are refused, as
# every issued -> issued update was before. The triggers are not recreated, so their
# `ENABLE ALWAYS` state is kept. Existing issued versions keep a NULL hash (pending) and are not
# back-filled.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY (see the
# manifest in Letflow.TenantProvisioning).
defmodule Letflow.Repo.Migrations.OpenDocumentArtefactHashWriteOnce do
  use Ecto.Migration

  def up do
    if prefix() do
      execute(function_sql(prefix(), true))
    end
  end

  def down do
    if prefix() do
      execute(function_sql(prefix(), false))
    end
  end

  defp function_sql(schema, with_attach) do
    attach =
      if with_attach do
        """
        ELSIF OLD.status = 'issued' AND NEW.status = 'issued' THEN
          IF OLD.artefact_hash IS NULL AND NEW.artefact_hash ~ '^[0-9a-f]{64}$' THEN
            allowed := ARRAY['artefact_hash'];
          ELSE
            RAISE EXCEPTION 'document version transition is not allowed'
              USING ERRCODE = 'restrict_violation';
          END IF;
        """
      else
        ""
      end

    """
    CREATE OR REPLACE FUNCTION "#{schema}".guard_document_versions() RETURNS trigger AS $$
    DECLARE
      allowed text[];
    BEGIN
      -- D-8: the only transitions, each with the columns it may change. Every other
      -- pair (including any change from discarded, superseded or cancelled) is refused.
      IF OLD.status = 'draft' AND NEW.status = 'draft' THEN
        allowed := ARRAY['content'];
      ELSIF OLD.status = 'draft' AND NEW.status = 'issued' THEN
        allowed := ARRAY['status', 'issued_at', 'issued_by', 'content_hash'];
      ELSIF OLD.status = 'draft' AND NEW.status = 'discarded' THEN
        allowed := ARRAY['status', 'discarded_at', 'discarded_by'];
      ELSIF OLD.status = 'issued' AND NEW.status = 'superseded' THEN
        allowed := ARRAY['status', 'superseded_by_version'];
      ELSIF OLD.status = 'issued' AND NEW.status = 'cancelled' THEN
        allowed := ARRAY['status', 'cancelled_at', 'cancelled_by', 'cancel_reason'];
      #{attach}ELSE
        RAISE EXCEPTION 'document version transition is not allowed'
          USING ERRCODE = 'restrict_violation';
      END IF;

      IF (to_jsonb(OLD) - allowed) IS DISTINCT FROM (to_jsonb(NEW) - allowed) THEN
        RAISE EXCEPTION 'document version field is immutable for this transition'
          USING ERRCODE = 'restrict_violation';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """
  end
end
