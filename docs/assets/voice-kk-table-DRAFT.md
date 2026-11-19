# Kazakh letter-name and digit table for the voice prompt: DRAFT, NOT LIVE

GH 4828 / T-2326. Not read by any code and not part of the prompt (`VoicePrompt`). It goes live only
after a native Kazakh speaker has checked it (listed in `project/qoimeks-needs-human.md` of the team
lab, "Kazakh voice", 2026-11-20). The old Qoimeks prompt has no such table either.

Letter names (spoken as in Kazakh/Russian spelling aloud, to be confirmed by the native check):
а A, бэ B, цэ C, дэ D, е E, эф F, гэ G, ха/аш H, и I, жэ/йот J, ка K, эл L, эм M, эн N, о O, пэ P, қу Q,
эр R, эс S, тэ T, у U, вэ V, дубль-вэ W, икс X, игрек Y, зэт Z.

Digits: нөл 0, бір 1, екі 2, үш 3, төрт 4, бес 5, алты 6, жеті 7, сегіз 8, тоғыз 9, он 10, жиырма 20,
отыз 30, қырық 40, елу 50, алпыс 60, жетпіс 70, сексен 80, тоқсан 90, жүз 100.

To enable: add one line to `VoicePrompt.rules/0` and the same Kazakh names to the letter table in
`VoiceDraft` (`@letter_names`), so the exact-spelling check covers Kazakh, after the native check.
