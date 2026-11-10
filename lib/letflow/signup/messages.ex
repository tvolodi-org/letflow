defmodule Letflow.Signup.Messages do
  @moduledoc """
  T-1579: the verification mail in ru/kk/en. Pure. The terms line is a neutral placeholder until the
  owner supplies the text (question Q6).
  """

  @languages ~w(ru kk en)

  @spec languages() :: [String.t()]
  def languages, do: @languages

  @doc "Renders `%{subject, body}` for a language; unknown languages fall back to English."
  @spec verification(String.t(), String.t()) :: %{subject: String.t(), body: String.t()}
  def verification(language, link) when language in @languages do
    {subject, intro, outro, terms} = texts(language)
    %{subject: subject, body: Enum.join([intro, "", link, "", outro, "", terms], "\n")}
  end

  def verification(_other, link), do: verification("en", link)

  @doc """
  T-1593: the one-time first-credential mail (temporary password, forced change at first sign-in).
  The workspace link follows in a later mail (part b). The password exists only in the rendered body.
  """
  @spec first_credential(String.t(), String.t(), String.t()) :: %{
          subject: String.t(),
          body: String.t()
        }
  def first_credential(language, username, password) do
    {subject, intro, user_label, pass_label, outro} = credential_texts(lang(language))

    %{
      subject: subject,
      body:
        Enum.join(
          [intro, "", "#{user_label}: #{username}", "#{pass_label}: #{password}", "", outro],
          "\n"
        )
    }
  end

  @doc "T-1593: sent instead of the credential when the temporary password is no longer available."
  @spec reset_hint(String.t()) :: %{subject: String.t(), body: String.t()}
  def reset_hint(language) do
    {subject, body} = hint_texts(lang(language))
    %{subject: subject, body: body}
  end

  defp lang(language) when language in @languages, do: language
  defp lang(_other), do: "en"

  defp credential_texts("en"),
    do:
      {"Your workspace account",
       "Your workspace account has been created. Use this temporary password to sign in:",
       "User name", "Temporary password",
       "You must change the password at first sign-in. A second message with your workspace link will follow."}

  defp credential_texts("ru"),
    do:
      {"Учётная запись вашего рабочего пространства",
       "Учётная запись для вашего рабочего пространства создана. Для входа используйте временный пароль:",
       "Имя пользователя", "Временный пароль",
       "При первом входе пароль нужно сменить. Ссылка на рабочее пространство придёт отдельным письмом."}

  defp credential_texts("kk"),
    do:
      {"Жұмыс кеңістігіңіздің тіркелгісі",
       "Жұмыс кеңістігіне арналған тіркелгі құрылды. Кіру үшін уақытша құпия сөзді пайдаланыңыз:",
       "Пайдаланушы аты", "Уақытша құпия сөз",
       "Алғаш кіргенде құпия сөзді ауыстыру керек. Жұмыс кеңістігіне сілтеме бөлек хатпен келеді."}

  defp hint_texts("en"),
    do:
      {"Your workspace account",
       "Your workspace account exists, but the temporary password can no longer be shown. " <>
         "On the sign-in page of your workspace choose \"Forgot password\" to set a new one."}

  defp hint_texts("ru"),
    do:
      {"Учётная запись вашего рабочего пространства",
       "Учётная запись создана, но временный пароль больше нельзя показать. " <>
         "На странице входа в рабочее пространство выберите «Забыли пароль», чтобы задать новый."}

  defp hint_texts("kk"),
    do:
      {"Жұмыс кеңістігіңіздің тіркелгісі",
       "Тіркелгі құрылды, бірақ уақытша құпия сөзді енді көрсету мүмкін емес. " <>
         "Жұмыс кеңістігінің кіру бетінде «Құпия сөзді ұмыттым» батырмасын басып, жаңасын орнатыңыз."}

  defp texts("en"),
    do:
      {"Confirm your e-mail address",
       "Open this link to confirm your e-mail address and continue creating your workspace:",
       "The link works for a limited time. If you did not ask for this, ignore this message.",
       "Terms of use: text to be provided."}

  defp texts("ru"),
    do:
      {"Подтвердите адрес электронной почты",
       "Откройте ссылку, чтобы подтвердить адрес электронной почты и продолжить создание рабочего пространства:",
       "Ссылка действует ограниченное время. Если вы не отправляли запрос, проигнорируйте это письмо.",
       "Условия использования: текст будет предоставлен."}

  defp texts("kk"),
    do:
      {"Электрондық пошта мекенжайын растаңыз",
       "Электрондық пошта мекенжайын растап, жұмыс кеңістігін құруды жалғастыру үшін сілтемені ашыңыз:",
       "Сілтеме шектеулі уақыт жарамды. Егер сіз сұрау жібермеген болсаңыз, бұл хатты елемеңіз.",
       "Пайдалану шарттары: мәтін кейінірек ұсынылады."}
end
