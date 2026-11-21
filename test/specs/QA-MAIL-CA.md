# Test spec: QA mail CA -- a build-arg gated certificate in the QA image

Work item: the product's half of ai-dala-infra run `2026-11-22-qa-mail-adapter-001`, step
`step-04c-tracked-change.md` ("Exact diffs", items 1-4). No GitHub issue: the board carries
this as a pilot blocker (owner order D-177/D-175). Infra owns the host half (the mail trap,
the CA file on the QA host, the window, the manual redeploy).

Test file: `test/letflow/qa_mail_ca_separation_test.exs` (`@moduletag :unit`, static reads plus one
docker build; `async: false` because it shells out to `git` and to `docker`).

## What the change is

The QA mail trap serves a certificate signed by a host-local CA. The QA image must trust that CA;
no other image may. The certificate reaches an image through exactly one path: a `FROM scratch AS
qa-mail-ca` stage whose content is bind-mounted (`RUN --mount=type=bind,from=qa-mail-ca`) into a
single build step that is only executed when the build argument `LETFLOW_QA_MAIL_CA` is `true`.
`deploy/redeploy-qa.sh` is the only script that passes it. The default is `false`, so production,
test, demo and CI builds carry no copy of the certificate and no trust-store entry for it.

The CA public certificate is placed on the QA host at `deploy/qa-mail-ca/letflow-qa-mail-ca.crt`
and is never committed; the private key never enters a build context at all.

## Criterion to test mapping

| # | Acceptance criterion | Test | Why it exists |
|---|---|---|---|
| 1 | The Dockerfile declares `ARG LETFLOW_QA_MAIL_CA=false` exactly once, in the runtime stage, after the apt layer and before `USER letflow` and before `COPY --from=builder` | T1 | The argument's position decides two things: it must be inside the runtime stage (the builder stage has no trust store), and it must come after the apt layer (otherwise every new commit busts the cached apt layers) and before the release copy (otherwise the app layers are rebuilt on every CA change). |
| 2 | `update-ca-certificates` and the certificate's file name appear in the Dockerfile only inside the one `RUN` guarded by `[ "$LETFLOW_QA_MAIL_CA" = "true" ]` | T2 | An unguarded trust-store write would put the QA CA into every image, including production. The check counts occurrences outside the guarded instruction (comments included) and requires zero. |
| 3 | No `COPY`/`ADD` names the CA directory or a `.crt`/`.pem` (the scratch stage's own `COPY deploy/qa-mail-ca/ /` is the one allowed case), and no `COPY --from=qa-mail-ca` exists anywhere | T3 | A plain `COPY` would fail on every checkout without the file, and a `COPY --from=` would leave the certificate in an image layer, readable by anyone who can pull the image. The bind mount leaves nothing behind. |
| 4 | `deploy/redeploy-qa.sh` passes `--build-arg LETFLOW_QA_MAIL_CA=true`; `redeploy-test.sh`, every other file under `deploy/`, every workflow and every compose file never name the argument | T4 | The test environment and the demo builds must stay untrusting. The scan is over every file under `deploy/` (dot-files included) and every `.github/workflows/*` file, not only the two scripts the spec names. |
| 5 | No certificate, key or PEM is committed; `deploy/qa-mail-ca/` holds only its tracked `.gitkeep`; `.gitignore` carries the two ignore rules | T5 | The CA public certificate is not a secret, but a committed CA in a shared repository cannot be rotated away, and the private key must never be reachable. The check asks git what *would* be committed (`--cached --others --exclude-standard`), so it holds before and after the commit, and it holds even with a certificate sitting on the working tree. |
| 6 | A build without the argument contains no certificate and no trust-store entry; a build with it trusts the certificate; a build with it but without the file fails | T6 | The gate is the whole point, and only an image proves it. Skipped where docker, buildx or openssl are absent, so a host without them stays green. |

## Fail-first evidence

The tracked change is new, so "fails against pre-change code" is vacuous. The evidence is MUTATION
of the shipped gate, exactly as the infra step prescribes ("remove the `if` guard and T2/T6 must
fail"). The `if` guard was removed from `deploy/Dockerfile` (the `RUN` then copies the certificate
unconditionally), the test file was run, and the original file was restored and checksum-verified
(`md5sum` before and after the mutation: `b7639653cd5f2bc9b4949649c32011a3`).

| Mutant | Tests run | Result |
|---|---|---|
| the `if [ "$LETFLOW_QA_MAIL_CA" = "true" ]; then ... fi` guard removed from the gated `RUN` | `test/letflow/qa_mail_ca_separation_test.exs` | `Result: 4/6 passed`, 2 failures: T2 (`assert gated =~ ~S|if [ "$LETFLOW_QA_MAIL_CA" = "true" ]; then|` failed) and T6 (`the image built without LETFLOW_QA_MAIL_CA carries the CA:` -- the unconditional copy put the CA into the no-argument image) |

## Notes and deliberate limits

- T6 builds the **real Dockerfile with the builder stage dropped and everything after the gated
  `RUN` cut away** (the CA stage, the runtime base, the apt layer that installs
  `ca-certificates` and the gated `RUN`, verbatim, extracted from `deploy/Dockerfile` at test time).
  The Elixir release is not built: it needs the network and minutes of compile time and says
  nothing about the trust store. The instructions under test are the shipped ones, not a copy.
- T6 reads the trust store by splitting `/etc/ssl/certs/ca-certificates.crt` and printing each
  certificate's subject with `openssl x509 -noout -subject`; the QA CA's subject is
  `Letflow QA local mail CA`. The no-argument image holds 148 certificates and none of them is the
  QA CA; the QA image holds 149 and exactly one is.
- The base image is pulled before the builds. A registry that cannot serve it is an environment
  fact, not a fault of the gate, so the test says it skipped instead of reporting a build failure.
- The CA private key of T6's throwaway certificate is written outside the build context; only the
  public certificate is inside one.
- The first CD after the merge builds **without** the argument (the already-running bash keeps
  executing the old script text from the old inode). That image is harmless: the mail variables are
  not set yet. Infra does one manual build inside the window. Nothing in this change depends on
  that ordering.
