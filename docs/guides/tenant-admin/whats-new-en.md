# What changed for company administrators since 9 November 2026 (English)

Other languages: [Русский](whats-new-ru.md) · [Қазақша](whats-new-kk.md). The three files have the same sections in the same order. The main guide is [en.md](en.md).

This page lists, in plain words, what is new for the person who administers Letflow for a company. Menu names are the English ones; the screen shows them in your language. Each new screen has a **Help** link with the details.

## 1. Import users from an Excel file

Under **Admin > Users** you can now create many users at once from an .xlsx file.

* Press "Download template", fill one row per user (user name, display name, e-mail) and save the file.
* Drop the file on the screen and press "Check file". Nothing is saved at this step. If a row is refused, the reason is shown next to it; fix it in your file and check again.
* When the check says "Ready to import", press "Import users".
* A file can have up to 200 rows and 2 MB. A user that already exists is never changed by an import.

## 2. Password reset instructions

On the page of a user there is a button "Send password reset instructions". It sends the user an e-mail that tells them to choose "Forgot password" on the sign-in page. You never see or set the password. Nothing is sent to an inactive user or to a user without an e-mail address.

## 3. Replay of an instance

On the **Graph** tab of a running or finished instance you can switch the view from "Live" to "Replay". Replay steps through the path the instance really took, one recorded step at a time, with the time of each step. Instances that ran before step recording started have no replay; the "Live" view still works for them.

## 4. Module rollouts (platform operators only)

If you are a platform operator, a new screen shows how a new version of a module is put onto the companies one by one, with the result for each company. A rollout that stopped after several failures can be resumed to retry the failed companies. Ordinary company administrators do not see this screen.

## 5. Sign-in for users you create (not switched on yet)

Users made on the Users screen or by the Excel import do not have a sign-in of their own yet. A button that would create a first password for them exists, but **it is switched off**: it answers "not available" and changes nothing. Do not retry it. Until the platform owner switches it on, ask your platform operator to create the sign-in for each new user, as before.

## 6. Long lists: "Load more" and the "showing the first" notice

Screens with many records no longer stop silently. The asset cards screen and the codes screen load their lists in parts: press "Load more" under the list, or narrow it with the filters and the search. The items, locations and org units screens, and the pickers on the stock and asset screens (item, location, employee), now read up to 10 000 records of a kind, so a record far down the list can be chosen. When a list is still longer than that, a notice on the screen says how many records are shown and that the rest cannot be reached from there. If you see such a notice, narrow the list with the filters. The screen **Help: long lists** (`/help/longLists`) explains it in three tasks.
