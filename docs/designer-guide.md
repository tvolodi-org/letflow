# Designer guide: the business process editor

For people who design business processes and do not program. It describes what is on `main` today. A piece that
is not built yet is marked "not available yet". Other languages: [Русский](designer-guide.ru.md),
[Қазақша](designer-guide.kk.md). The three files have the same sections and the same anchors.

Words in **bold** are the names of buttons, tabs and fields exactly as the product shows them in English.
The HTML comment under each heading lists the message keys that the docs test checks against the product's
messages file (`web/src/i18n/processDiagramMessages.ts`, `web/src/pages/definitions/definitionsMessages.ts`).
Keys start with `pd.` (process diagram messages) or `defs.` (definitions list messages).

Contents: [1](#sec-what-is-a-process) · [2](#sec-steps-and-editor) · [3](#sec-add-edit-step) ·
[4](#sec-function-picker) · [5](#sec-notification-step) · [6](#sec-start-and-end) · [7](#sec-validation-messages) ·
[8](#sec-save-version-activate) · [9](#sec-test-cases) · [10](#sec-runs-and-retry) · [11](#sec-platform-only)

<a id="sec-what-is-a-process"></a>
## 1. What a process definition is and what a run is
<!-- labels: defs.title -->

A **process definition** is the drawing of a business process: its steps, the arrows between them, who does each
human step and which values travel with the process. You find definitions under **Business processes**.
A definition has versions. Only one version is **Active** at a time; the others are **Draft**, **Deprecated**
or **Archived**.

A **run** (the product also says "instance") is one real passage through the process, for example one tenant
registration. A run always follows the version that was active when it started. Changing a definition never
changes a run that is already going.

<a id="sec-steps-and-editor"></a>
## 2. The Steps tab and the Editor tab
<!-- labels: pd.view.diagram, pd.view.editor, pd.mode.steps, pd.view.edit, pd.view.versions -->

Open a process from the list (**Open process**). At the top of the page there is a switch with the buttons
**Diagram**, **Versions**, **Edit diagram** and **Editor**. Which of them you see depends on your permissions.

* **Diagram**: a read-only picture of the process. A second switch, **Show as**, shows the same process either
  as the picture or as the list **Steps**. Click a step to see its details (type, role, function, template).
* **Edit diagram**: change the picture directly: add steps, draw arrows, edit the properties of a step.
* **Editor**: the full editor with the node palette, the property panel, the validation bar and the raw
  definition. Forms, module writes, interface and endpoint of a step are edited only here.
* **Versions**: compare two versions on one picture (read only).

If one of the two edit views has unsaved changes, the other is switched off until you save or discard.

<a id="sec-add-edit-step"></a>
## 3. Add and edit a step
<!-- labels: pd.edit.addType, pd.edit.add, pd.edit.panel.node, pd.edit.field.label, pd.edit.connectGo, pd.edit.deleteStep, pd.edit.undo, pd.edit.redo -->

1. Open **Edit diagram**.
2. Choose the kind in **Step type** (Start, End, User task, Service task, Decision, Parallel, Timer,
   Sub-process) and press **Add step**.
3. Click the new step. The panel **Step properties** opens. Give it a name in **Label**. A user task also
   needs a **Role**; a timer needs a **Duration (ISO 8601)**, for example `PT1H` for one hour.
4. To connect two steps, drag from one step to the other, or choose the target in **Connect from this step to**
   and press **Connect**. An arrow that leaves a **Decision** needs a **Condition**, or **Default route**.
5. **Delete step** removes a step with its arrows. **Undo** and **Redo** step back and forward.

The product refuses some moves at once with a short message, for example "A step cannot connect to itself.",
"These steps are already connected.", "Nothing can lead into the start." or "Nothing can leave the end.".
Nothing is saved until you save (section 8).

<a id="sec-function-picker"></a>
## 4. The function picker and the typed argument mapping
<!-- labels: pd.edit.platform.function, pd.edit.platform.functionPlaceholder, pd.edit.platform.arguments, pd.edit.platform.source, pd.edit.platform.source.var, pd.edit.platform.source.const, pd.edit.platform.outputs, pd.edit.platform.useFunction, pd.edit.platform.useScript -->

A **Service task** does work without a person. It can call a **platform function** from the function catalogue.

1. Select the service task, then press **Use a platform function**.
2. Open **Function** and choose from the list (**Choose a function**). The catalogue is fixed by the platform;
   a function that is not in it cannot be typed in by hand.
3. Under **Arguments** each argument of the function has a type and is marked "required" or "optional".
   For each one choose **Value from**:
   * **A variable of the process**: give the variable name (not empty, without a dot, not a name of the system);
   * **A fixed value**: type the value; it must fit the argument type (a number, true or false, or valid JSON).
4. **Values written into the process** lists what the function adds to the process.

A *typed mapping* means each argument has a declared type and the product checks that what you connect fits it.
A refusal looks like this: the field turns red with a short text such as "This value must be a number." or
"The name of a variable: not empty, without a dot, and not a name of the system.", or the step shows
"Two arguments of different types read the same variable; this step cannot be activated.". Fix the mapping and the
red text goes away.

A write-like function takes its arguments from the start form or from earlier steps, never from a variable that a
person fills in later.

**Use a script instead** drops the function and lets you name a script. A step cannot have a function and a
script at the same time.

<a id="sec-notification-step"></a>
## 5. The notification step
<!-- labels: pd.edit.notify.useNotification, pd.edit.notify.channel, pd.edit.notify.channel.email, pd.edit.notify.channel.file, pd.edit.notify.template, pd.edit.notify.recipient, pd.edit.notify.values, pd.edit.notify.problem.template_missing, pd.edit.notify.problem.recipient_missing -->

A service task can send a notification instead of calling a function. Press **Send a notification**, then fill in:

* **Channel**: **E-mail** or **File**. A file notification also needs a **File name**: a plain name, not a path.
* **Template**: choose from the registered templates (**Choose a template**). Templates are not written here.
* **Recipient variable**: the name of a process variable that holds the address. A fixed address is never stored in
  the definition.
* **Values**: what each placeholder of the template receives, from a variable of the process or a fixed value.

If something is missing the editor says, for example, "Choose a template for the notification." or
"Name the variable the address is read from.".

**The outbound allow-list.** A process may reach outside the company only through a destination the company has
allowed. The list is **empty by default** (deny by default): until a destination is added, a notification to that
recipient domain is refused. Only a person who holds the permission "outbound destinations manage" may add one;
in practice this is the company administrator (or the platform administrator). A process designer does not get it
automatically. The allow-list is a settings page, not a part of the editor; ask your administrator to add the
domain before you activate the process.

<a id="sec-start-and-end"></a>
## 6. Start and end of a process
<!-- labels: pd.type.START, pd.type.END, pd.edit.refusal.second_start, pd.edit.refusal.delete_start -->

Every process has exactly one **Start** and at least one **End**.

* Nothing can lead into the start, nothing can leave an end.
* The start cannot be deleted ("The start cannot be deleted.") and a second one cannot be added
  ("There is only one start.").
* Every step must be reachable from the start, and from every step there must be a way to an end.
* Who may start a run is decided by the start permission of the definition, not by the drawing.

<a id="sec-validation-messages"></a>
## 7. The validation messages
<!-- labels: pd.edit.violations, pd.edit.valid, pd.edit.checking, pd.edit.checkFailed -->

The editor checks the process while you work: **Checking…**, then **Valid** or the number of problems, and the
list **Problems found by the validator**. If the check cannot run you see "Could not check; you can still save.",
and the server checks again when you save and activate. The messages come from the server and are in English in
every language. `<step>`, `<arrow>` and `<other>` below stand for the id of the step or arrow.

| Message | What to do |
|---|---|
| No START node found in the definition graph | Add a **Start** step. |
| Found N START nodes; exactly one is required | Delete the extra starts. |
| No END node found in the definition graph | Add an **End** step. |
| Duplicate node ID '`<step>`' | Two steps have the same id; delete one and add it again. |
| Node count N exceeds the maximum of M / Edge count N exceeds the maximum of M | The process is too large; split it with a sub-process. |
| Edge '`<arrow>`' has dangling source reference: node '`<step>`' does not exist (also: dangling target) | An arrow points to a deleted step; delete the arrow or reconnect it. |
| Node '`<step>`' is isolated (insufficient incoming or outgoing edges for its type) | Connect the step in and out. |
| Node '`<step>`' (TYPE) is not reachable from any START node | Draw an arrow that leads to this step from the start. |
| Node '`<step>`' (TYPE) has no path to any END node | Draw an arrow from this step towards an end. |
| Cycle detected: edge from node 'A' to node 'B' creates a cycle not passing through a gateway node | A loop must pass through a **Decision**; add one. |
| Node '`<step>`' (TYPE) has no default outgoing edge (is_default: true); an instance whose conditions all evaluate false would stop with no matching route | Mark one arrow as **Default route**. |
| Edge '`<arrow>`' is a non-default outgoing edge from an EXCLUSIVE_GATEWAY and requires a non-empty condition | Fill **Condition** or make the arrow the default. |
| Edge '`<arrow>`' is not a non-default EXCLUSIVE_GATEWAY outgoing edge or a HUMAN_TASK outgoing edge and must not have a condition | Clear the condition. |
| Edge '`<arrow>`' is marked is_default but also has a non-null condition | A default arrow has no condition; clear it. |
| Edge '`<arrow>`' is an additional default edge from EXCLUSIVE_GATEWAY node '`<step>`'; only one default edge is permitted per gateway | Keep one default arrow. |
| HUMAN_TASK node '`<step>`' has at least one really-conditioned outgoing edge but no fallback edge | Add a default arrow after the user task. |
| Node '`<step>`' (HUMAN_TASK) is missing a non-empty 'role' attribute | Fill **Role**. |
| Node '`<step>`' (SERVICE_TASK) is missing a non-empty 'endpoint' attribute (and no non-empty 'service_id' attribute is present as an alternative) | Choose a function, a notification or a script for the service task. |
| Node '`<step>`' (SERVICE_TASK) has an invalid 'script_key'/'script_version' pair | Script key: lower-case letters, digits and `_`, starts with a letter; version: a whole number from 1. |
| Node '`<step>`' (SERVICE_TASK) binds a script and also carries an 'endpoint' or 'service_id' | Keep one way of working: script or service. |
| Node '`<step>`' (SERVICE_TASK) binds a platform call and also carries an 'endpoint', 'service_id' or 'script_key' | Keep the function or the other, not both. |
| Node '`<step>`' carries an invalid 'notify' attribute (code) | The notification is incomplete; see section 5, the code names the field (for example `template_missing`, `recipient_missing`). |
| Node '`<step>`' (SERVICE_TASK) has an invalid 'timeout_ms' attribute; must be an integer in 1..300000 | Use a whole number of milliseconds up to 300000. |
| Node '`<step>`' (TIMER) has an invalid 'duration_iso8601' attribute | Write the duration as ISO 8601, for example `PT30M`. |
| ... 'escalation_timer_duration' / 'reminder_timer_duration' invalid, or its role missing, or a role without a duration | Escalation and reminder need both a valid duration and a role. |
| ... 'required_outputs' / 'required_permission' / 'distinct_from' invalid, or used on a step that is not a HUMAN_TASK | These settings exist only on user tasks, with valid entries. |
| Node '`<step>`' (HUMAN_TASK) lists '`<other>`' in distinct_from, but no node '`<other>`' exists in this definition / is not a HUMAN_TASK / is reachable only after '`<step>`' | The "must be done by a different person" rule must name an existing user task that comes earlier. |
| Node '`<step>`' (HUMAN_TASK) lists itself in distinct_from | Remove the step from its own list. |
| Edge '`<arrow>`' (condition text error) | The condition has a syntax error; the message says where. |
| Extension point '...' names node '`<step>`' which is not in the definition graph | A hook points to a step that does not exist. |

Messages about platform steps, notification templates and sub-process interfaces appear in the same list. A
platform step in a company tenant is refused; see section 11.

<a id="sec-save-version-activate"></a>
## 8. Save, version, activate, roll back in one step
<!-- labels: pd.edit.saveDraft, defs.publish, defs.activate, defs.rollback, defs.copyAsDraft, pd.edit.discard -->

* **Save draft** stores your changes as a **Draft** version. If the definition was already active, saving makes a
  new draft with the next version number; the active one is not touched. If someone changed the definition while
  you were editing, you are asked: **Save anyway** or **Reload**. **Discard changes** drops what you did not save.
* **Publish saved version** (in the editor) or **Activate** (in the list) switches a draft on. The older active
  version becomes **Deprecated**; new runs use the new one, running runs keep theirs. Activation runs the full
  check again, and runs the test cases (section 9). If it refuses, the problems are shown under the button.
* **Copy as draft** makes an editable copy of any version.
* **Rollback…** (list) puts the previous version back as active in one step. Pick the version and confirm. It is
  refused if that version was never active or is already active.
* **Archive** hides a version you no longer need.

<a id="sec-test-cases"></a>
## 9. Test cases before activation (G16)
<!-- labels: -->

A definition may declare **test cases**: a starting set of values, the human tasks to complete by themselves, and
what the run must end with. Before a version is switched on, every declared case is walked in memory (no run is
created, no mail is sent). If one fails, activation is refused and nothing changes. A refusal names the case and a
short reason, for example `status_mismatch` (the run ended differently), `variable_mismatch` (a value is not what
you expected) or `node_not_visited` (the run did not reach a step you named). It never shows the values.

A version without test cases is activated as before. Writing test cases on the screen is **not available yet**;
for now they are part of the definition's data and are described in `docs/definition-test-cases.md`.

<a id="sec-runs-and-retry"></a>
## 10. Where to see a run: instances, the step log, retry
<!-- labels: pd.replay.modeReplay, pd.replay.listLabel, pd.state.error -->

* **Instances** in the side menu lists the runs. Open one to see its diagram: the steps are coloured by state
  (**Done**, **Active**, **Error**, **Skipped**, **Not reached**).
* **Replay** walks through the steps that were recorded, one by one (**First step**, **Previous step**,
  **Next step**, **Last step**). The list **Recorded steps** shows who, when and the result of each step.
* A platform step or a notification that failed too many times is put into the **DLQ** (dead-letter queue, in the
  side menu). Open the entry and press retry: the step runs once more. If it works, the run goes on from there.
  A retry gives no extra rights; it needs the dead-letter permission and, for a platform step, platform authority.

<a id="sec-platform-only"></a>
## 11. What only the platform operator may do
<!-- labels: -->

* **Platform steps** (functions that create or change a tenant, such as registering a company) exist only in the
  platform tenant. A definition of an ordinary company cannot carry one; the editor refuses it.
* The function catalogue is fixed by the platform: new functions are added by a code change, not in the editor.
  In a company tenant the function picker may show "The platform function catalogue is not available in this tenant."
* Adding an outbound destination is not a designer right (section 5).
* Standard definitions that come with a module are locked: copy them as a draft to change a version of your own.
