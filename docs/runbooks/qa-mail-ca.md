# Runbook: the QA mail trap's CA in the QA image (build-argument gate)

The QA mail trap (`mailpit`, shared with Keycloak on `ubuntu-16gb-nbg1-1`) serves a certificate
signed by a host-local CA. The QA application image must trust that CA; no other image may. The
certificate therefore reaches an image through exactly one path: a build argument.

The product's half of the change is ai-dala-infra run `2026-11-22-qa-mail-adapter-001`, step
`step-04c-tracked-change.md`. Infra owns the host half (the trap, the CA file, the window).

## Where it exists

- The certificate is a **host-local file**, never a repository file:
  `/opt/apps/letflow-qa/deploy/qa-mail-ca/letflow-qa-mail-ca.crt` on the QA host, mode 644. It is
  the PUBLIC certificate only; the private key stays in `/opt/apps/qa-mailtrap/tls/ca.key` (root,
  600) and never enters a build context.
- `deploy/qa-mail-ca/` is ignored in the repository except for its `.gitkeep` placeholder
  (`deploy/qa-mail-ca/*` + `!deploy/qa-mail-ca/.gitkeep`), so the directory always exists for the
  build context and no certificate can be committed by accident.
- The QA image trusts the CA **only when it is built with `--build-arg LETFLOW_QA_MAIL_CA=true`**.
  `deploy/redeploy-qa.sh` is the only place that passes it. The argument defaults to `false` in
  `deploy/Dockerfile`, so a production build, `redeploy-test.sh`, a demo build and a plain
  `docker build` contain no copy of the certificate and no entry for it in the trust store.
- The certificate reaches the image through a `FROM scratch AS qa-mail-ca` stage whose content is
  bind-mounted (`RUN --mount=type=bind,from=qa-mail-ca`) into ONE build step that runs only when the
  argument is `true`. A bind mount leaves nothing in any layer, so even a build context that
  contains the certificate cannot leak it into an image built without the argument.
- With the argument `true` and the certificate missing, the build **fails**: no silent skip.

## Deploying

`deploy/redeploy-qa.sh` checks the file before it builds and stops with a named error when it is
missing (`ERROR: deploy/qa-mail-ca/letflow-qa-mail-ca.crt missing`). That is deliberate: a QA
redeploy without the certificate would produce an image whose mail adapter cannot verify the trap,
and the failure would only show up as a delivery error later. **Place the certificate on the host
before the QA redeploy that builds with the argument.**

The first CD after this change merges still builds **without** the argument (the already-running
bash keeps executing the old script text from the old inode). That image is harmless: the mail
variables are not set yet. Every CD after it carries the gate.

## Checking it

- The image built with the argument holds the certificate twice: `/usr/local/share/ca-certificates/
  letflow-qa-mail-ca.crt` and `/etc/ssl/certs/letflow-qa-mail-ca.pem`, and its bundle
  `/etc/ssl/certs/ca-certificates.crt` holds one more certificate than an image built without it.
- The image built without it holds neither file and no certificate with the subject
  `Letflow QA local mail CA`.
- On the host, after the deploy: `scripts/mail_adapter_check.sh --container letflow-qa-app-1` must
  end with `ready:` (see `docs/testing/uat-mail-trap.md`).

## Tests

`test/letflow/qa_mail_ca_separation_test.exs` (T1-T6; the spec is `test/specs/QA-MAIL-CA.md`):
T1-T5 read the tracked files, T6 builds the image and reads its trust store.
