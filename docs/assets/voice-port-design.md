# Voice input: design for porting the Qoimeks service into Letflow

Status: design, not built (REQ-731, GH #3794, assets phase D item D2). Docs only: no code, no migration, no
definition JSON, no route, no screen, no dependency, no secret. Nothing here is implemented before GATE D
(owner decisions D-063, D-085); the routes, provider clients and draft check are later requirements written
from this file.

Sources: owner decisions D-022 (own keys or included), D-061 (voice is ported; the Go code is not reused),
D-063, D-085 and D-086 in `ai-dala-portfolio/DECISIONS.md`; `ai-dala-portfolio/architectures/assets.md`;
`Qoimeks-team/project/features-to-port.md` sections 2 and 7; `Qoimeks-team/project/voice-phrases-draft.md`;
`Qoimeks-team/project/retirement-criteria.md` criteria 3 and 9; `docs/assets/stock-workflow-documents.md`;
REQ-687, REQ-701, REQ-712 and REQ-731 in `docs/requirements.yaml`.

**The Qoimeks Go code is not reused (D-061).** It is the specification and the test material only.

Marks: **proposal** = to be confirmed by the owner at the phase D gate; **assumption** = taken to go on, owner
may change it (D-086).

Naming note: REQ-731's text names the file `docs/assets/voice-input.md`; task T-1285 names it
`docs/assets/voice-port-design.md`. This file follows the task. If the requirement's file name is wanted, it is a
rename.

## 1. What the Qoimeks server does today

A warehouse operator says or types a phrase such as "приход замок восемьдесят штук слева а три" and gets a
filled operation form to check and post. Nothing is saved by the voice part.

1. **Recording (phone/web).** AAC in `.m4a` on the phone; Opus in WebM on the web where supported, AAC/M4A on
   Safari. The app sends `lang` = app language (`ru` or `kk`) as the speech hint. Upload cap 10 MB; 60 s timeout
   per provider call.
2. **Speech to text.** ElevenLabs Scribe (`scribe_v2`, `language_code`, `tag_audio_events=false`) or any
   OpenAI-style `/audio/transcriptions` endpoint (`gpt-4o-transcribe`). No speech key: keyboard only.
3. **Phrase to draft (language model).** System prompt = fixed instructions + the locations (code, name) + the
   SKUs (code, name, unit, usual location). Prompt rules: kind words in ru and kk (приход/кіріс, расход/шығыс,
   переместил/ауыстырдым, инвентаризация/түгендеу, otherwise `unknown`); a general name shared by several SKUs
   returns the best three and the operator chooses; articles spoken letter by letter (a table of Russian letter
   names); location zone words (слева/сол жақ, справа/оң жақ, прямо/тура); never copy the usual location; never
   guess a quantity; only codes from the lists. Typed text takes the same path as recorded speech.
4. **Output.** JSON with exactly `kind`, `sku_codes[]`, `location_words`, `location_code`,
   `to_location_words`, `to_location_code`, `qty` (number or null). Three JSON modes per provider: `schema`
   (strict json_schema), `object` (json_object), `prompt` (prompt only). The parser strips `<think>…</think>`,
   takes the outer `{…}`, rejects non-JSON. Anthropic: cached system prompt; refusal and max-tokens are errors.
5. **Server check (`resolve`).** The model's answer is never trusted: unknown kinds dropped; SKU codes not in the
   catalog and duplicates dropped (order kept); a location kept only if its quoted words occur in the transcript
   (case and spaces aside); destination only for a transfer; negative quantity dropped.
6. **Failures.** Errors carry `source` (`speech` or `llm`) so the app says which part is down. Speech without a
   model: transcript only, form by hand. The app never posts by itself; with several SKUs it asks "Какой товар?"
   and Post stays disabled until one is chosen.
7. **Provider keys.** Several providers by environment variables, stored settings (encrypted, masked, never sent
   to the app) win over environment. Letflow ports the rules (key by reference, masked, env fallback), not the
   page.

## 2. The Letflow port

Two steps, both outbound calls from the Letflow server, both in the request of the route. No supervised process,
no queue, no stored audio (the Letflow architecture keeps the engine a plain transactional context; this
service is not even transactional: it reads and answers).

```
phone/web --audio or text--> POST (stock module, tenant from token)
   1. size/format/lang check          (route, no provider call yet)
   2. speech to text                  (provider call 1, audio only; skipped for typed text)
   3. read active catalog + locations (tenant prefix of the token)
   4. language model                  (provider call 2: transcript + lists, no audio)
   5. server check of the answer      (rules of section 5)
   6. answer the draft                (nothing stored)
```

### 2.1 Routes (proposal, names for the implementing entry)

Both are routes of module `stock`, read-only: no record, no posting, no event, no audio and no transcript
stored.

| Route (proposal) | Body | Answers |
|---|---|---|
| `POST /api/stock/voice/draft` | multipart: `audio` (file), `lang` (`ru` or `kk`) | the draft (section 4) |
| `POST /api/stock/voice/draft-text` | JSON: `text`, `lang` (optional hint) | the same draft |

* The tenant comes only from the token, never from a path, query or header value (INV-1, INV-10). A cross-tenant
  negative test is required in the implementing entry: a token of tenant A never sees tenant B's codes.
* Permission: the one that drafting a stock document needs in REQ-712, `StockPost`. **No new permission atom.**
  A caller without it gets 403; a tenant without the module gets the 404 of REQ-687 criterion 8a (not found and
  forbidden stay indistinguishable to a caller who may not know the resource exists, INV-5).
* The draft route is a `POST` because it carries a body and calls a paid provider; it is not idempotent and
  not retried by the server.

### 2.2 Audio limits

* Accepted formats: AAC in `.m4a` and Opus in WebM. Anything else is refused (section 6).
* Upload cap **10 MB**, checked by the route before any provider call. It sits under the multipart length
  `26_214_400` of `Plug.Parsers` in `lib/letflow/plugs/api_pipeline.ex` (the default length there is
  `2_097_152`, so the route's body must go through the multipart parser, not the default): the parser admits up
  to 25 MB, the route refuses above 10 MB with its own error. The implementing entry must keep the route's check
  as the binding one and test a file between 10 MB and 25 MB.
* Time limit **60 seconds** per provider call.
* The language hint is `ru` or `kk`; any other value is refused with 422.

### 2.3 Settings and providers

Settings are platform settings in QA: no tenant-facing secrets route exists today (`lib/letflow/secrets.ex`
moduledoc). A setting left unset turns its step off. Names are proposals.

| Setting (proposal) | Meaning | Default |
|---|---|---|
| `LETFLOW_VOICE_STT_PROVIDER` | speech provider kind: `openai_transcriptions` | unset (speech step off) |
| `LETFLOW_VOICE_STT_MODEL` | speech model, e.g. an OpenAI-style transcription model | unset (step off) |
| `LETFLOW_VOICE_STT_BASE_URL` | base URL of the speech endpoint | unset (step off) |
| `LETFLOW_VOICE_LLM_PROVIDER` | model provider kind: `openai_chat` | unset (model step off) |
| `LETFLOW_VOICE_LLM_MODEL` | chat model | unset (step off) |
| `LETFLOW_VOICE_LLM_BASE_URL` | base URL of the chat endpoint | unset (step off) |
| `LETFLOW_VOICE_LLM_JSON_MODE` | `schema`, `object` or `prompt` | `prompt` (the least demanding) |
| API keys, one per step | held by reference through `Letflow.Secrets` | unset |

Rules:

* An API key is held by reference only and never appears in a log, a response, an error or git (INV-4).
* Every base URL is checked with `Letflow.Webhooks.UrlValidator.validate/1` before a call (https only; private
  ranges refused after DNS; INV-9), at each call, because DNS can change.
* The calls use `:httpc` as `lib/letflow/webhooks.ex` does, so the implementation adds no HTTP client
  dependency (and none is added here).
* Provider kinds ported: an OpenAI-style transcription endpoint for speech; an OpenAI-style chat endpoint for
  the model with JSON modes `schema`, `object` and `prompt`. ElevenLabs, Anthropic-native and other providers
  are a later entry.
* Each new setting is a new env var and needs the reason stated in the implementing entry; all default off.
  With no provider set the whole service is off and typed or scanned entry works as before (retirement
  criterion 3: typed entry works without a speech key).
* Per-tenant keys are not designed here (open question 1).

### 2.4 Where each step runs, cost and privacy

| Step | Runs | Sends outside Letflow | Cost driver |
|---|---|---|---|
| size/format/lang check | Letflow server | nothing | none |
| speech to text | outside provider, called from the Letflow server | the audio of the phrase | audio seconds |
| catalog read | Letflow server, tenant schema | nothing | database read |
| language model | outside provider, called from the Letflow server | the transcript and the tenant's active item and location codes and names | tokens in and out (the catalog dominates the input) |
| server check, answer | Letflow server | nothing | none |

* The phone never holds a provider key and never calls a provider.
* Cost per 100 voice entries is measured for retirement criterion 9 on QA, with the field-test phone, and
  compared with Qoimeks. The catalog in the prompt is the main cost; a cap is open question 4. Token caching of
  the fixed instructions is a provider feature, not a design requirement.
* Privacy: audio and catalog names leave Letflow to a third-party processor. In QA with test data that is
  acceptable under D-086 once the owner supplies accounts; for production it needs the owner's decision (open
  question 3). No audio and no transcript is stored by Letflow; logs carry the route, tenant, outcome class and
  durations, never the audio, the transcript, the prompt or the catalog.

## 3. What the model sees

Instructions ported from Qoimeks, in Letflow's terms:

* The caller's tenant only: the **active** `catalog_item` records (code, name, base unit; fields in
  `priv/modules/catalog_items/entity_definitions/catalog_item.json`) and the **active** `location_node`
  records (code, name; `priv/modules/locations/entity_definitions/location_node.json`). The usual-location hint of
  Qoimeks has no Letflow field and is not sent.
* Kind words in Russian and Kazakh for each draft kind (receipt: приход / кіріс, қабылдадым; issue: расход,
  выдал / шығыс, бердім; transfer: переместил / ауыстырдым; count: инвентаризация, пересчитал / түгендеу,
  санадым). The word list is taken from Qoimeks `parse.go` and is checked by a Kazakh speaker (section 8).
* A general name shared by several items: return the best three.
* Never guess a quantity. Never copy a usual location. Use only codes from the given lists.
* `catalog_items.ex` and `locations.ex` on `origin/main` have `lookup/2` and `active?/2` and **no list
  function**. The implementing entry adds a read of the active records through the tenant prefix of the token
  (a new data-access path: INV-6 requires it to prove its scoping with a test).
* The size of the catalog in the prompt is an open owner question; this file gives no number.
* The letter-name table and the zone words (слева/справа/прямо) are specific to one warehouse in Qoimeks. Whether
  they stay in the base prompt or become tenant settings is open question 5.

## 4. Draft shape

The model answers JSON with exactly these keys, otherwise it is an error:

`kind`, `item_codes` (list), `location_words`, `location_code`, `to_location_words`, `to_location_code`,
`quantity` (number or null).

The route answers:

| Key | Meaning |
|---|---|
| `kind` | `receipt`, `issue`, `transfer`, `count` or `unknown` |
| `items` | matched catalog_item ids with `code` and `name` (more than one: the user chooses on the form) |
| `location`, `to_location` | location_node id with `code` and `name`, or null |
| `quantity` | decimal as text (no float), or null |
| `transcript` | the text the model saw |
| `dropped` | list of what the check removed and why, each `{field, value, reason}` with reason one of `unknown_kind`, `unknown_item`, `duplicate_item`, `unknown_location`, `location_not_said`, `to_location_not_transfer`, `negative_quantity` |

Draft kinds (proposal, assumption, owner may change at the phase D gate): `receipt`, `issue`, `transfer`,
`count`, mapped to the stock receipt, issue and transfer documents of `docs/assets/stock-workflow-documents.md`
and to a count sheet line of REQ-701; `unknown` for anything else. Write off, hand over and return are an open
question. Lot, unit, org unit and responsible employee are not filled by the voice draft (the form fills them as
for typed entry). **Posting is never done by this service:** the user checks the draft and saves it through the
stock document routes of REQ-712 or the count sheet of REQ-701.

## 5. The server check of the model's answer

The answer is never trusted. No rule is relaxed for typed text.

| Rule | Result |
|---|---|
| answer is not JSON, or JSON with other keys | error `llm` (section 6), never a partial draft |
| `kind` not one of the four | `unknown` |
| item code not among the tenant's active catalog_item codes | dropped; duplicates dropped, order kept |
| location kept only if it is an active location_node code of the tenant **and** its quoted words occur in the transcript (case and spaces aside) | otherwise dropped (`unknown_location` / `location_not_said`) |
| to location | only for a transfer; otherwise dropped |
| negative quantity | dropped |
| quantity not a number | dropped |

Known gaps carried from Qoimeks and left to the implementing entry's decision: the check does not verify the
quantity against the transcript (dictated corrections, phrase ru-08), and it keeps a location whose words occur
even when the model picked a wrong code for them (ru-07).

## 6. Failures

The route answers `source` (`speech` or `llm`) and a short reason. No error carries the API key, the provider's raw
body or the tenant's catalog (INV-4); the provider being down never blocks typed entry. Exact status codes are
proposals.

| Failure | Status | Reason | Source |
|---|---|---|---|
| speech step off (no provider set) | 503 | `speech_off` | speech |
| model step off | 200 with the transcript only, kind `unknown`, nothing else filled | `llm_off` (field `notice`) | llm |
| provider error or timeout (60 s) | 502 / 504 | `provider_error` / `provider_timeout` | the failed step |
| model answer not JSON or other keys | 502 | `bad_answer` | llm |
| model refusal or answer cut at the length limit | 502 | `refused` / `truncated` | llm |
| file over 10 MB | 413 | `audio_too_large` | speech (not called) |
| audio format not accepted | 415 | `audio_format` | speech (not called) |
| language hint other than ru or kk | 422 | `bad_language` | none |
| caller without StockPost | 403 | standard | none |
| tenant without the module | 404 | REQ-687 8a | none |

## 7. Test material

The tests of the implementing entry stub the provider and test the **server's handling of a given model
answer**, not model accuracy. The 7 typed phrases of `features-to-port.md` section 7, rewritten for a Letflow
test tenant (the codes below are the fixture of that entry: items `NUT-M8`, `NUT-M10`, `BLT-M8-40`; locations
`A-01`, `B-02`, `LA3` named "Слева A 3"; the tenant has no `NO-SUCH`, no `LE2`):

| # | Phrase | Stubbed model answer | Expected draft |
|---|---|---|---|
| 1 | приход замок восемьдесят штук слева а три | receipt, `BLT-M8-40`, location `LA3` with words «слева а три», 80 | receipt; BLT-M8-40; LA3; 80 |
| 2 | переместил пятнадцать гаек из а один в бэ два | transfer, `NUT-M8`, `NO-SUCH`, `NUT-M10`, `NUT-M8`, A-01 → B-02, 15 | transfer; NUT-M8, NUT-M10; A-01 → B-02; 15; dropped: NO-SUCH, duplicate NUT-M8 |
| 3 | расход кнопка выхода двадцать шесть штук | issue, location `LE2` with words absent from the phrase | issue; location dropped (`location_not_said`) |
| 4 | переместил семь гаек эм восемь из а один в бэ два | transfer, `NUT-M8`, A-01 → B-02, 7 | transfer; NUT-M8; A-01 → B-02; 7 |
| 5 | приход гайки двадцать штук на а один | receipt, `NUT-M8`, `NUT-M10`, A-01, 20 | receipt; two items (user chooses); A-01; 20 |
| 6 | приход | (a) model off; (b) answer without JSON | (a) transcript only; (b) error `bad_answer` |
| 7 | что-то | `unknown` | kind `unknown`; JSON mode per provider also checked |

Added Letflow cases (each with a stubbed answer): negative quantity dropped; kind outside the four becomes
`unknown`; to location with a non-transfer kind dropped; a location code that belongs to another tenant is
dropped (cross-tenant negative test); 11 MB file refused before any provider call; `lang=en` refused with 422;
key never present in any error body.

**The 20 recorded phrases do not exist yet.** Retirement criterion 3 needs 20 phrases, 10 Russian and 10
Kazakh, that **a person must record**. Each needs: the audio file (`.m4a` or WebM, under 10 MB), the language
(`ru` or `kk`), and the expected draft (kind, item codes, location, quantity) on a stated catalog. A draft list
with the catalog excerpt and the 20 phrase texts exists in `Qoimeks-team/project/voice-phrases-draft.md`; its
Kazakh lines are marked for a native speaker to check. Once recorded they are kept in a UAT fixture folder under
`test/fixtures/uat/` (proposal). The measure of criterion 3: **Letflow drafts are correct at least as often as
Qoimeks's drafts on the same phrases**, with the same model class where possible. This is a measurement with real
provider accounts, not a unit test.

## 8. What the owner must provide

1. The **20 recorded phrases** (10 Russian, 10 Kazakh) with the expected drafts; a native Kazakh speaker to check
   the Kazakh kind words and the phrases.
2. **Where the speech and language models run:** provider and endpoint for each step in QA (and later production);
   whether OpenAI-style endpoints are enough for the first slice.
3. **Accounts and keys** for those providers (sign-ups and purchases are the owner's, D-086), and whether keys
   are one platform key or per tenant, and who pays (D-022).
4. The phase D gate decision on the draft kinds.

## 9. Open questions (no answer given here)

1. Per-tenant provider keys or one platform key, and who pays for the calls (D-022; retirement criterion 9).
   Per-tenant keys need a tenant-facing secrets route that does not exist today.
2. Which provider accounts are used in QA and in production (a sign-up or purchase: D-086).
3. May tenant audio and catalog names be sent to an outside provider in production, and does that need a decision
   record?
4. How many catalog records the prompt may carry for a large tenant (and how a larger catalog is narrowed: by
   search words from the transcript first, or by a cap).
5. Do the Russian letter-name and zone-word rules stay specific to one warehouse or become tenant settings
   (features-to-port.md section 9 question 7)?
6. The kinds write off, hand over and return.
7. Does a saved document keep the source "voice" and the transcript (a Qoimeks movement does)? Today the design
   stores nothing.
8. Is a rate limit per user or tenant needed to bound provider cost?

## 10. Not in this design

The phone side (recording, language hint, the form showing the draft, the choice among several items) is item D3;
camera scan is item D1. No code, no dependency, no secret, no sign-up and no purchase is part of this file.
