defmodule Letflow.LoginDirectory.PlanUserChangeTest do
  @moduledoc """
  REQ-435 -- `Letflow.LoginDirectory.plan_user_change/2`, the pure single source
  of truth for what a user change does to the directory (design §3.3): every
  combination of (before eligible?, after eligible?) where eligible means
  `status == :active` and a valid email shape. No DB, no pepper.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Identity.User
  alias Letflow.LoginDirectory

  defp user(status, email), do: %User{status: status, email: email}

  test "create (before nil): eligible -> upsert" do
    assert LoginDirectory.plan_user_change(nil, user(:active, "a@x.com")) == [
             {:upsert, "a@x.com"}
           ]
  end

  test "create: inactive, nil email or invalid email -> nothing" do
    assert LoginDirectory.plan_user_change(nil, user(:inactive, "a@x.com")) == []
    assert LoginDirectory.plan_user_change(nil, user(:active, nil)) == []
    assert LoginDirectory.plan_user_change(nil, user(:active, "not-an-email")) == []
    assert LoginDirectory.plan_user_change(nil, user(:active, "")) == []
  end

  test "active -> inactive: remove-if-unreferenced of the old email" do
    assert LoginDirectory.plan_user_change(user(:active, "a@x.com"), user(:inactive, "a@x.com")) ==
             [{:remove_if_unreferenced, "a@x.com"}]
  end

  test "inactive -> active: upsert" do
    assert LoginDirectory.plan_user_change(user(:inactive, "a@x.com"), user(:active, "a@x.com")) ==
             [{:upsert, "a@x.com"}]
  end

  test "inactive -> inactive: nothing, even with a new email" do
    assert LoginDirectory.plan_user_change(user(:inactive, "a@x.com"), user(:inactive, "b@x.com")) ==
             []
  end

  test "active -> active with the same normalised email (case/whitespace only): nothing" do
    assert LoginDirectory.plan_user_change(user(:active, "a@x.com"), user(:active, " A@X.com ")) ==
             []
  end

  test "active -> active with a different email: remove the old, then upsert the new (in that order)" do
    assert LoginDirectory.plan_user_change(user(:active, "a@x.com"), user(:active, "b@x.com")) ==
             [{:remove_if_unreferenced, "a@x.com"}, {:upsert, "b@x.com"}]
  end

  test "active valid -> active invalid email: remove only; invalid -> valid: upsert only" do
    assert LoginDirectory.plan_user_change(user(:active, "a@x.com"), user(:active, "nope")) ==
             [{:remove_if_unreferenced, "a@x.com"}]

    assert LoginDirectory.plan_user_change(user(:active, "nope"), user(:active, "a@x.com")) ==
             [{:upsert, "a@x.com"}]

    assert LoginDirectory.plan_user_change(user(:active, "a@x.com"), user(:active, nil)) ==
             [{:remove_if_unreferenced, "a@x.com"}]
  end

  test "an over-length address (> 255 bytes) is ineligible" do
    long = String.duplicate("x", 250) <> "@x.com"
    assert LoginDirectory.plan_user_change(nil, user(:active, long)) == []
  end
end
