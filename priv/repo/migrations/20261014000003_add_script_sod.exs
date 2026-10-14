# Letflow.Repo.Migrations.AddScriptSod
#
# GH 2534 PR 7b-2b (decision 0053 D6 + its 2026-10-14 amendment) -- see
# lib/letflow/design/gh2534-7b2b-script-sod.md section 3 for the design.
#
#   * `script_policy` gains the tenant's DECLARED separation-of-duties policy (`sod`, its writer
#     class, user, time and reason) and the platform flag that allows `solo_audited` for this
#     tenant (default FORBIDDEN, S2). A CHECK makes a declared `solo_audited` impossible while
#     the platform forbids it. `script_policy_guard()` is NOT replaced: it names only `id`,
#     `inserted_at` and DELETE, so it already covers these columns (design 3.1, CDV 7).
#   * `script_rules` gains `sod_excluded` (the publish-time SoD set plus the publisher, SEC F2)
#     and the three `confirmed_*` columns of the D6 confirmation.
#   * `script_rules_guard()` is replaced (same name, same SQLSTATE 'LF001') and its trigger now
#     also fires BEFORE INSERT (SECURITY F2: a new row must be a draft with self_published
#     false and NULL sod_excluded / confirmed_*). The design 3.3 rules: `self_published` may become true only at draft -> published while the policy row
#     says `sod = 'solo_audited' AND platform_solo_audited_allowed`; `sod_excluded` is written at
#     publish (covering the contributors and the publisher) and immutable afterwards; a
#     confirmation is a third allowed shape on a published/retired row. The `down` direction
#     restores the 7b-1 function body verbatim (before the columns it never named are dropped).
#
# PLACEMENT: per-tenant (0006 D2: no tenant_id column).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
# Existing tenants receive the columns through the boot-time replay; existing rows keep
# `sod = 'strict'`, solo FORBIDDEN, and NULL `sod_excluded` / `confirmed_*`.
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7); the only
# interpolation is the schema name from `prefix()`. Inside the trigger body the policy row is
# read from `TG_TABLE_SCHEMA` (the schema of the row being updated, quoted with `%I`), not from
# the migration-time schema name, so a cloned or renamed tenant schema reads its own policy row.
defmodule Letflow.Repo.Migrations.AddScriptSod do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      alter table(:script_policy, prefix: schema) do
        add :sod, :text, null: false, default: "strict"
        add :sod_set_by, :binary_id
        add :sod_set_by_class, :text
        add :sod_set_at, :utc_datetime_usec
        add :sod_reason, :text
        add :platform_solo_audited_allowed, :boolean, null: false, default: false
        # 9a8aa7ca: no operator id column (the operator's identity lives in the platform chain).
        add :platform_solo_audited_set_at, :utc_datetime_usec
        add :platform_solo_audited_reason, :text
      end

      create constraint(:script_policy, :script_policy_sod_value,
               check: "sod IN ('strict', 'solo_audited')",
               prefix: schema
             )

      create constraint(:script_policy, :script_policy_sod_set_by_class,
               check:
                 "sod_set_by_class IS NULL OR sod_set_by_class IN ('tenant_admin', 'platform_operator', 'system')",
               prefix: schema
             )

      create constraint(:script_policy, :script_policy_sod_reason_length,
               check: "char_length(sod_reason) <= 500",
               prefix: schema
             )

      create constraint(:script_policy, :script_policy_platform_solo_reason_length,
               check: "char_length(platform_solo_audited_reason) <= 500",
               prefix: schema
             )

      # S2/S3: a declared solo_audited only while the platform allows it.
      create constraint(:script_policy, :script_policy_solo_requires_platform,
               check: "NOT (sod = 'solo_audited' AND NOT platform_solo_audited_allowed)",
               prefix: schema
             )

      alter table(:script_rules, prefix: schema) do
        add :sod_excluded, {:array, :binary_id}
        add :confirmed_by, :binary_id
        add :confirmed_at, :utc_datetime_usec
        add :confirmed_sha256, :text
      end

      create constraint(:script_rules, :script_rules_confirmed_all_or_none,
               check:
                 "(confirmed_by IS NULL AND confirmed_at IS NULL AND confirmed_sha256 IS NULL) OR " <>
                   "(confirmed_by IS NOT NULL AND confirmed_at IS NOT NULL AND confirmed_sha256 IS NOT NULL)",
               prefix: schema
             )

      create constraint(:script_rules, :script_rules_confirmed_self_published,
               check: "confirmed_by IS NULL OR (self_published AND sod_excluded IS NOT NULL)",
               prefix: schema
             )

      # A NULL element would make the trigger's `= ANY(sod_excluded)` NULL and silently pass.
      create constraint(:script_rules, :script_rules_sod_excluded_no_null,
               check: "sod_excluded IS NULL OR array_position(sod_excluded, NULL) IS NULL",
               prefix: schema
             )

      execute(sod_guard(schema), v7b1_guard(schema))

      # SECURITY F2: the guard also fires on INSERT (a new row must be a plain draft). The 7b-1
      # trigger is BEFORE UPDATE OR DELETE; rollback re-creates exactly that.
      execute(
        ~s(DROP TRIGGER IF EXISTS script_rules_guard ON "#{schema}".script_rules),
        """
        CREATE TRIGGER script_rules_guard
          BEFORE UPDATE OR DELETE ON "#{schema}".script_rules
          FOR EACH ROW EXECUTE FUNCTION "#{schema}".script_rules_guard()
        """
      )

      execute(
        """
        CREATE TRIGGER script_rules_guard
          BEFORE INSERT OR UPDATE OR DELETE ON "#{schema}".script_rules
          FOR EACH ROW EXECUTE FUNCTION "#{schema}".script_rules_guard()
        """,
        ~s(DROP TRIGGER IF EXISTS script_rules_guard ON "#{schema}".script_rules)
      )
    end
  end

  # Design 3.3: the 7b-1 function with rules 1-5 changed (everything else unchanged).
  defp sod_guard(schema) do
    """
    CREATE OR REPLACE FUNCTION "#{schema}".script_rules_guard() RETURNS trigger AS $$
    DECLARE
      content_changed boolean;
      confirmation_changed boolean;
      solo_allowed boolean;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'script_rules: versions are never deleted' USING ERRCODE = 'LF001';
      END IF;

      -- SECURITY F2: a new row is always a plain draft (every other state is reached through
      -- the UPDATE rules below).
      IF TG_OP = 'INSERT' THEN
        IF NEW.status IS DISTINCT FROM 'draft'
           OR NEW.self_published IS DISTINCT FROM false
           OR NEW.sod_excluded IS NOT NULL
           OR NEW.confirmed_by IS NOT NULL OR NEW.confirmed_at IS NOT NULL
           OR NEW.confirmed_sha256 IS NOT NULL THEN
          RAISE EXCEPTION 'script_rules: a new version must be a draft' USING ERRCODE = 'LF001';
        END IF;
        RETURN NEW;
      END IF;

      IF NEW.id IS DISTINCT FROM OLD.id
         OR NEW.key IS DISTINCT FROM OLD.key
         OR NEW.version IS DISTINCT FROM OLD.version
         OR NEW.hook_kind IS DISTINCT FROM OLD.hook_kind
         OR NEW.inserted_at IS DISTINCT FROM OLD.inserted_at THEN
        RAISE EXCEPTION 'script_rules: identity columns are immutable' USING ERRCODE = 'LF001';
      END IF;

      content_changed :=
        NEW.source IS DISTINCT FROM OLD.source
        OR NEW.manifest IS DISTINCT FROM OLD.manifest
        OR NEW.test_cases IS DISTINCT FROM OLD.test_cases
        OR NEW.sha256 IS DISTINCT FROM OLD.sha256;

      confirmation_changed :=
        NEW.confirmed_by IS DISTINCT FROM OLD.confirmed_by
        OR NEW.confirmed_at IS DISTINCT FROM OLD.confirmed_at
        OR NEW.confirmed_sha256 IS DISTINCT FROM OLD.confirmed_sha256;

      IF OLD.status = 'draft' THEN
        IF NEW.status IN ('draft', 'discarded') THEN
          IF NEW.self_published
             OR NEW.sod_excluded IS NOT NULL
             OR NEW.confirmed_by IS NOT NULL OR NEW.confirmed_at IS NOT NULL
             OR NEW.confirmed_sha256 IS NOT NULL THEN
            RAISE EXCEPTION 'script_rules: invalid draft sod state' USING ERRCODE = 'LF001';
          END IF;
        END IF;

        IF NEW.status = 'draft' THEN
          IF NOT (OLD.contributors <@ NEW.contributors)
             OR NEW.publisher_id IS NOT NULL OR NEW.published_at IS NOT NULL
             OR NEW.retired_at IS NOT NULL OR NEW.revoked_at IS NOT NULL
             OR NEW.discarded_at IS NOT NULL THEN
            RAISE EXCEPTION 'script_rules: invalid draft update' USING ERRCODE = 'LF001';
          END IF;
          RETURN NEW;
        ELSIF NEW.status = 'published' THEN
          IF content_changed
             OR NEW.contributors IS DISTINCT FROM OLD.contributors
             OR NEW.publisher_id IS NULL OR NEW.published_at IS NULL
             OR NEW.retired_at IS NOT NULL OR NEW.revoked_at IS NOT NULL
             OR NEW.discarded_at IS NOT NULL
             OR NEW.confirmed_by IS NOT NULL OR NEW.confirmed_at IS NOT NULL
             OR NEW.confirmed_sha256 IS NOT NULL
             OR NEW.sod_excluded IS NULL
             OR NOT (NEW.contributors <@ NEW.sod_excluded)
             OR NOT (NEW.publisher_id = ANY(NEW.sod_excluded)) THEN
            RAISE EXCEPTION 'script_rules: invalid publish' USING ERRCODE = 'LF001';
          END IF;

          IF NEW.self_published THEN
            -- The policy row of THIS row's schema (TG_TABLE_SCHEMA, quoted by %I): a schema
            -- name fixed at migration time would not follow a schema clone or rename.
            EXECUTE format(
              'SELECT (p.sod = ''solo_audited'' AND p.platform_solo_audited_allowed) '
              'FROM %I.script_policy p WHERE p.id = 1',
              TG_TABLE_SCHEMA
            ) INTO solo_allowed;

            IF solo_allowed IS NOT TRUE THEN
              RAISE EXCEPTION 'script_rules: self publish not allowed' USING ERRCODE = 'LF001';
            END IF;
          ELSIF NEW.publisher_id = ANY(NEW.contributors) THEN
            RAISE EXCEPTION 'script_rules: invalid publish' USING ERRCODE = 'LF001';
          END IF;
          RETURN NEW;
        ELSIF NEW.status = 'discarded' THEN
          IF content_changed
             OR NEW.contributors IS DISTINCT FROM OLD.contributors
             OR NEW.discarded_at IS NULL
             OR NEW.publisher_id IS NOT NULL OR NEW.published_at IS NOT NULL
             OR NEW.retired_at IS NOT NULL OR NEW.revoked_at IS NOT NULL THEN
            RAISE EXCEPTION 'script_rules: invalid discard' USING ERRCODE = 'LF001';
          END IF;
          RETURN NEW;
        END IF;

        RAISE EXCEPTION 'script_rules: invalid transition from draft' USING ERRCODE = 'LF001';
      END IF;

      IF OLD.status IN ('published', 'retired') THEN
        IF content_changed
           OR NEW.contributors IS DISTINCT FROM OLD.contributors
           OR NEW.publisher_id IS DISTINCT FROM OLD.publisher_id
           OR NEW.published_at IS DISTINCT FROM OLD.published_at
           OR NEW.discarded_at IS DISTINCT FROM OLD.discarded_at
           OR NEW.self_published IS DISTINCT FROM OLD.self_published
           OR NEW.sod_excluded IS DISTINCT FROM OLD.sod_excluded THEN
          RAISE EXCEPTION 'script_rules: published content is immutable' USING ERRCODE = 'LF001';
        END IF;

        IF OLD.status = 'published' AND NEW.status = 'retired'
           AND OLD.retired_at IS NULL AND NEW.retired_at IS NOT NULL
           AND NEW.revoked_at IS NOT DISTINCT FROM OLD.revoked_at
           AND NOT confirmation_changed THEN
          RETURN NEW;
        END IF;

        IF NEW.status = 'revoked'
           AND OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL
           AND NEW.retired_at IS NOT DISTINCT FROM OLD.retired_at
           AND NOT confirmation_changed THEN
          RETURN NEW;
        END IF;

        -- 7b-2b confirmation: only the three confirmed_* columns (and updated_at) change.
        IF NEW.status = OLD.status
           AND NEW.retired_at IS NOT DISTINCT FROM OLD.retired_at
           AND NEW.revoked_at IS NOT DISTINCT FROM OLD.revoked_at
           AND OLD.confirmed_by IS NULL AND OLD.confirmed_at IS NULL
           AND OLD.confirmed_sha256 IS NULL
           AND NEW.confirmed_by IS NOT NULL AND NEW.confirmed_at IS NOT NULL
           AND NEW.confirmed_sha256 IS NOT NULL
           AND OLD.self_published
           AND OLD.sod_excluded IS NOT NULL
           AND NEW.confirmed_sha256 = OLD.sha256
           AND NOT (NEW.confirmed_by = ANY(OLD.sod_excluded)) THEN
          RETURN NEW;
        END IF;
      END IF;

      RAISE EXCEPTION 'script_rules: invalid transition' USING ERRCODE = 'LF001';
    END;
    $$ LANGUAGE plpgsql
    """
  end

  # The 7b-1 body (20261014000001_create_script_rules.exs), restored on rollback.
  defp v7b1_guard(schema) do
    """
    CREATE OR REPLACE FUNCTION "#{schema}".script_rules_guard() RETURNS trigger AS $$
    DECLARE
      content_changed boolean;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'script_rules: versions are never deleted' USING ERRCODE = 'LF001';
      END IF;

      IF NEW.id IS DISTINCT FROM OLD.id
         OR NEW.key IS DISTINCT FROM OLD.key
         OR NEW.version IS DISTINCT FROM OLD.version
         OR NEW.hook_kind IS DISTINCT FROM OLD.hook_kind
         OR NEW.inserted_at IS DISTINCT FROM OLD.inserted_at
         OR NEW.self_published IS DISTINCT FROM OLD.self_published THEN
        RAISE EXCEPTION 'script_rules: identity columns are immutable' USING ERRCODE = 'LF001';
      END IF;

      content_changed :=
        NEW.source IS DISTINCT FROM OLD.source
        OR NEW.manifest IS DISTINCT FROM OLD.manifest
        OR NEW.test_cases IS DISTINCT FROM OLD.test_cases
        OR NEW.sha256 IS DISTINCT FROM OLD.sha256;

      IF OLD.status = 'draft' THEN
        IF NEW.status = 'draft' THEN
          IF NOT (OLD.contributors <@ NEW.contributors)
             OR NEW.publisher_id IS NOT NULL OR NEW.published_at IS NOT NULL
             OR NEW.retired_at IS NOT NULL OR NEW.revoked_at IS NOT NULL
             OR NEW.discarded_at IS NOT NULL THEN
            RAISE EXCEPTION 'script_rules: invalid draft update' USING ERRCODE = 'LF001';
          END IF;
          RETURN NEW;
        ELSIF NEW.status = 'published' THEN
          IF content_changed
             OR NEW.contributors IS DISTINCT FROM OLD.contributors
             OR NEW.publisher_id IS NULL OR NEW.published_at IS NULL
             OR NEW.publisher_id = ANY(NEW.contributors)
             OR NEW.retired_at IS NOT NULL OR NEW.revoked_at IS NOT NULL
             OR NEW.discarded_at IS NOT NULL THEN
            RAISE EXCEPTION 'script_rules: invalid publish' USING ERRCODE = 'LF001';
          END IF;
          RETURN NEW;
        ELSIF NEW.status = 'discarded' THEN
          IF content_changed
             OR NEW.contributors IS DISTINCT FROM OLD.contributors
             OR NEW.discarded_at IS NULL
             OR NEW.publisher_id IS NOT NULL OR NEW.published_at IS NOT NULL
             OR NEW.retired_at IS NOT NULL OR NEW.revoked_at IS NOT NULL THEN
            RAISE EXCEPTION 'script_rules: invalid discard' USING ERRCODE = 'LF001';
          END IF;
          RETURN NEW;
        END IF;

        RAISE EXCEPTION 'script_rules: invalid transition from draft' USING ERRCODE = 'LF001';
      END IF;

      IF OLD.status IN ('published', 'retired') THEN
        IF content_changed
           OR NEW.contributors IS DISTINCT FROM OLD.contributors
           OR NEW.publisher_id IS DISTINCT FROM OLD.publisher_id
           OR NEW.published_at IS DISTINCT FROM OLD.published_at
           OR NEW.discarded_at IS DISTINCT FROM OLD.discarded_at THEN
          RAISE EXCEPTION 'script_rules: published content is immutable' USING ERRCODE = 'LF001';
        END IF;

        IF OLD.status = 'published' AND NEW.status = 'retired'
           AND OLD.retired_at IS NULL AND NEW.retired_at IS NOT NULL
           AND NEW.revoked_at IS NOT DISTINCT FROM OLD.revoked_at THEN
          RETURN NEW;
        END IF;

        IF NEW.status = 'revoked'
           AND OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL
           AND NEW.retired_at IS NOT DISTINCT FROM OLD.retired_at THEN
          RETURN NEW;
        END IF;
      END IF;

      RAISE EXCEPTION 'script_rules: invalid transition' USING ERRCODE = 'LF001';
    END;
    $$ LANGUAGE plpgsql
    """
  end
end
