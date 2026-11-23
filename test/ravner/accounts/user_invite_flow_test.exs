defmodule Ravner.Accounts.UserInviteFlowTest do
  use RavnerWeb.ConnCase, async: true

  alias Ravner.Accounts
  alias Ravner.Accounts.{ScopeResolver, User}
  alias Ravner.AccountsFixtures
  alias Ravner.Inventory

  setup do
    admin = AccountsFixtures.user_fixture(%{role: :admin})
    supervisor = AccountsFixtures.user_fixture(%{role: :pm_supervisor})
    {:ok, admin: admin, supervisor: supervisor}
  end

  describe "user invite lifecycle and scope linking" do
    test "create invite with supervisor and accept sets user role, supervisor, and activates account",
         %{admin: admin, supervisor: supervisor} do
      email = "invited-pm-#{System.unique_integer([:positive])}@example.com"

      {:ok, invite} =
        Accounts.create_invite(
          %{
            "email" => email,
            "role" => "project_manager",
            "name" => "Invited PM",
            "supervisor_id" => supervisor.id
          },
          admin.id,
          actor: admin
        )

      assert invite.email == email
      assert invite.role == :project_manager
      assert invite.supervisor_id == supervisor.id
      assert is_nil(invite.accepted_at)

      # Valid invite query returns invite
      found = Accounts.get_valid_invite(invite.token)
      assert found.id == invite.id

      # Accept invite
      {:ok, new_user} = Accounts.accept_invite(invite, "verysecretpassword123!")

      assert new_user.email == email
      assert new_user.role == :project_manager
      assert new_user.supervisor_id == supervisor.id
      assert new_user.active == true
      assert not is_nil(new_user.confirmed_at)
      assert Accounts.User.valid_password?(new_user, "verysecretpassword123!")

      # Token is now consumed
      assert is_nil(Accounts.get_valid_invite(invite.token))

      # ScopeResolver sees the supervisor link
      scope = ScopeResolver.resolve(new_user)
      assert scope.role == :project_manager
    end

    test "accept invite auto-links to existing person record and updates user_id", %{admin: admin} do
      email = "po-candidate-#{System.unique_integer([:positive])}@example.com"

      {:ok, org} =
        Inventory.create_organization(
          %{
            name: "Test Org",
            slug: "test-org-#{System.unique_integer([:positive])}",
            type: :client
          },
          actor: admin
        )

      # Pre-existing person (created by brand manager / org manager during team setup)
      {:ok, person} =
        Inventory.create_person(
          %{
            first_name: "Polly",
            last_name: "Owner",
            email: email,
            organization_id: org.id
          },
          actor: admin
        )

      assert is_nil(person.user_id)

      {:ok, invite} =
        Accounts.create_invite(
          %{
            "email" => email,
            "role" => "product_owner",
            "name" => "Polly Owner",
            "target_organization_id" => org.id
          },
          admin.id,
          actor: admin
        )

      {:ok, new_user} = Accounts.accept_invite(invite, "supersecurepass456!")

      # Person user_id is now updated to the new user id
      reloaded_person = Ravner.Repo.get!(Inventory.Person, person.id)
      assert reloaded_person.user_id == new_user.id

      # ScopeResolver resolves organization for the product owner
      scope = ScopeResolver.resolve(new_user)
      assert scope.role == :product_owner
      assert scope.person.id == person.id
    end

    test "accept invite with target_project_id assigns person as project PM", %{admin: admin} do
      email = "invited-lead-pm-#{System.unique_integer([:positive])}@example.com"

      {:ok, org} =
        Inventory.create_organization(
          %{
            name: "Org Alpha",
            slug: "org-alpha-#{System.unique_integer([:positive])}",
            type: :internal
          },
          actor: admin
        )

      {:ok, project} =
        Inventory.create_project(
          %{
            name: "Alpha Project",
            slug: "alpha-proj-#{System.unique_integer([:positive])}",
            organization_id: org.id
          },
          actor: admin
        )

      assert is_nil(project.project_manager_id)

      {:ok, invite} =
        Accounts.create_invite(
          %{
            "email" => email,
            "role" => "project_manager",
            "name" => "Lead PM",
            "target_project_id" => project.id
          },
          admin.id,
          actor: admin
        )

      assert invite.target_project_id == project.id

      {:ok, user} = Accounts.accept_invite(invite, "passphrase123456!")
      assert user.email == email

      # Reload project - PM should now be set!
      reloaded_project = Inventory.get_project!(project.id)
      assert not is_nil(reloaded_project.project_manager_id)
      assert reloaded_project.project_manager.email == email

      # Scope resolution includes the project
      scope = ScopeResolver.resolve(user)
      assert project.id in scope.project_ids
    end

    test "accept invite with target_brand_id assigns person as Brand Manager", %{admin: admin} do
      email = "invited-bm-#{System.unique_integer([:positive])}@example.com"

      {:ok, brand} =
        Inventory.create_brand(
          %{
            name: "Brand Retail",
            slug: "brand-retail-#{System.unique_integer([:positive])}"
          },
          actor: admin
        )

      assert is_nil(brand.brand_manager_id)

      {:ok, invite} =
        Accounts.create_invite(
          %{
            "email" => email,
            "role" => "brand_manager",
            "name" => "Retail BM",
            "target_brand_id" => brand.id
          },
          admin.id,
          actor: admin
        )

      assert invite.target_brand_id == brand.id

      {:ok, user} = Accounts.accept_invite(invite, "passphrase123456!")
      assert user.email == email

      # Reload brand - brand_manager should now be set!
      reloaded_brand = Inventory.get_brand!(brand.id)
      assert not is_nil(reloaded_brand.brand_manager_id)
      assert reloaded_brand.brand_manager.email == email

      # Scope resolution includes the brand
      scope = ScopeResolver.resolve(user)
      assert brand.id in scope.brand_ids
    end
  end

  describe "UserInviteController web flow" do
    test "GET /users/invite/:token renders accept invite page", %{conn: conn, admin: admin} do
      email = "web-invite-#{System.unique_integer([:positive])}@example.com"

      {:ok, invite} =
        Accounts.create_invite(
          %{"email" => email, "role" => "viewer", "name" => "Web Viewer"},
          admin.id,
          actor: admin
        )

      conn = get(conn, ~p"/users/invite/#{invite.token}")
      html = response(conn, 200)

      assert html =~ "Accept Invite"
      assert html =~ email
      assert html =~ "Viewer"
    end

    test "POST /users/invite/:token creates user and logs them in", %{conn: conn, admin: admin} do
      email = "post-invite-#{System.unique_integer([:positive])}@example.com"

      {:ok, invite} =
        Accounts.create_invite(
          %{"email" => email, "role" => "project_manager", "name" => "PM Test"},
          admin.id,
          actor: admin
        )

      conn =
        post(conn, ~p"/users/invite/#{invite.token}", %{
          "user" => %{
            "password" => "validpassphrase789!"
          }
        })

      assert redirected_to(conn) == ~p"/dashboard"
      assert get_session(conn, :user_token)

      created_user = Ravner.Repo.get_by(User, email: email)
      assert created_user
      assert created_user.role == :project_manager
    end

    test "GET /users/invite/:invalid_token redirects to login with flash", %{conn: conn} do
      conn = get(conn, ~p"/users/invite/nonexistent-token-xyz")
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid or has expired"
    end
  end
end
