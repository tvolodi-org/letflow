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
