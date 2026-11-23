defmodule Ravner.Accounts.OneTimeLoginTest do
  use Ravner.DataCase, async: true

  alias Ravner.Accounts
  alias Ravner.Accounts.User
  alias Ravner.Accounts.UserToken
  alias Ravner.Inventory
  alias Ravner.Repo

  @admin_actor %User{id: 999_998, role: :admin, email: "superadmin@example.com"}

  defp unique_id, do: System.unique_integer([:positive])

  defp insert_user(attrs) do
    id = unique_id()
    email = attrs[:email] || "user-#{id}@example.com"
    role = attrs[:role] || :viewer

    %User{}
    |> Ecto.Changeset.change(%{
      email: email,
      hashed_password: "$2b$04$fakehashfakehashfakehashfake",
      confirmed_at:
        Map.get(attrs, :confirmed_at, DateTime.utc_now() |> DateTime.truncate(:second)),
      role: role,
      active: Map.get(attrs, :active, true),
      name: attrs[:name] || "User #{id}",
      supervisor_id: attrs[:supervisor_id]
    })
    |> Repo.insert!()
  end

  defp insert_person(attrs) do
    id = unique_id()

    attrs =
      Map.merge(
        %{
          first_name: "First#{id}",
          last_name: "Last#{id}",
          email: "person-#{id}@example.com"
        },
        Map.new(attrs)
      )

    {:ok, person} = Inventory.create_person(attrs, actor: @admin_actor)
    person
  end

  defp insert_brand(attrs) do
    id = unique_id()

    attrs =
      Map.merge(
        %{
          name: "Brand #{id}",
          slug: "brand-#{id}"
        },
        Map.new(attrs)
      )

    {:ok, brand} = Inventory.create_brand(attrs, actor: @admin_actor)
    brand
  end

  defp insert_organization(attrs) do
    id = unique_id()

    attrs =
      Map.merge(
        %{
          name: "Org #{id}",
          slug: "org-#{id}",
          type: :internal
        },
        Map.new(attrs)
      )

    {:ok, org} = Inventory.create_organization(attrs, actor: @admin_actor)
    org
  end

  describe "authorization rules" do
    test "admin can generate one-time login links for any active user" do
      admin = insert_user(%{role: :admin})
      pm = insert_user(%{role: :project_manager})
      cm = insert_user(%{role: :organization_manager})
      editor = insert_user(%{role: :editor})

      assert Accounts.can_generate_one_time_login?(admin, pm) == true
      assert Accounts.can_generate_one_time_login?(admin, cm) == true
      assert Accounts.can_generate_one_time_login?(admin, editor) == true
    end

    test "cannot generate one-time login for self" do
      admin = insert_user(%{role: :admin})
      assert Accounts.can_generate_one_time_login?(admin, admin) == false
    end

    test "non-admin cannot generate login link for global roles (admin, editor, viewer)" do
      dh = insert_user(%{role: :delivery_head})
      admin = insert_user(%{role: :admin})
      editor = insert_user(%{role: :editor})
      viewer = insert_user(%{role: :viewer})

      assert Accounts.can_generate_one_time_login?(dh, admin) == false
      assert Accounts.can_generate_one_time_login?(dh, editor) == false
      assert Accounts.can_generate_one_time_login?(dh, viewer) == false
    end

    test "editors and viewers cannot generate login links for anyone" do
      editor = insert_user(%{role: :editor})
      viewer = insert_user(%{role: :viewer})
      pm = insert_user(%{role: :project_manager})

      assert Accounts.can_generate_one_time_login?(editor, pm) == false
      assert Accounts.can_generate_one_time_login?(viewer, pm) == false
    end

    test "delivery tree: Delivery Head and Supervisor hierarchy" do
      dh = insert_user(%{role: :delivery_head})
      sup = insert_user(%{role: :pm_supervisor})
      pm_under_sup = insert_user(%{role: :project_manager, supervisor_id: sup.id})
      pm_under_other = insert_user(%{role: :project_manager, supervisor_id: dh.id})
      po = insert_user(%{role: :product_owner})

      # Delivery Head can generate for Supervisor and PMs, but not PO
      assert Accounts.can_generate_one_time_login?(dh, sup) == true
      assert Accounts.can_generate_one_time_login?(dh, pm_under_sup) == true
      assert Accounts.can_generate_one_time_login?(dh, po) == false

      # Supervisor can only generate for their direct PMs
      assert Accounts.can_generate_one_time_login?(sup, pm_under_sup) == true
      assert Accounts.can_generate_one_time_login?(sup, pm_under_other) == false
      assert Accounts.can_generate_one_time_login?(sup, dh) == false
    end

    test "client tree: Brand Manager and Company Manager hierarchy" do
      bm_user = insert_user(%{role: :brand_manager})
      bm_person = insert_person(%{user_id: bm_user.id})
      brand = insert_brand(%{brand_manager_id: bm_person.id})

      other_bm_user = insert_user(%{role: :brand_manager})
      other_bm_person = insert_person(%{user_id: other_bm_user.id})
      other_brand = insert_brand(%{brand_manager_id: other_bm_person.id})

      cm_user = insert_user(%{role: :organization_manager})
      cm_person = insert_person(%{user_id: cm_user.id})
      org = insert_organization(%{brand_id: brand.id, manager_id: cm_person.id})

      po_user = insert_user(%{role: :product_owner})
      _po_person = insert_person(%{user_id: po_user.id, organization_id: org.id})

      other_cm_user = insert_user(%{role: :organization_manager})
      other_cm_person = insert_person(%{user_id: other_cm_user.id})

      _other_org =
        insert_organization(%{brand_id: other_brand.id, manager_id: other_cm_person.id})

      # Brand manager can generate for CM and PO in their brand
      assert Accounts.can_generate_one_time_login?(bm_user, cm_user) == true
      assert Accounts.can_generate_one_time_login?(bm_user, po_user) == true
      # But not for users in other brands
      assert Accounts.can_generate_one_time_login?(bm_user, other_cm_user) == false

      # Company manager can generate for PO in their company
      assert Accounts.can_generate_one_time_login?(cm_user, po_user) == true
      # But not for Brand Manager or other CMs
      assert Accounts.can_generate_one_time_login?(cm_user, bm_user) == false
      assert Accounts.can_generate_one_time_login?(cm_user, other_cm_user) == false
    end
  end

  describe "generation and consumption" do
    test "generates link and successfully consumes token to log in and confirm user" do
      admin = insert_user(%{role: :admin})
      target = insert_user(%{role: :project_manager, confirmed_at: nil})

      assert {:ok, link} =
               Accounts.generate_one_time_login_link(target, admin, fn token ->
                 "https://example.com/users/log-in/one-time/#{token}"
               end)

      assert link =~ "https://example.com/users/log-in/one-time/"
      token = String.replace(link, "https://example.com/users/log-in/one-time/", "")

      # First consumption succeeds and confirms user
      assert {:ok, logged_in_user} = Accounts.consume_one_time_login_token(token)
      assert logged_in_user.id == target.id
      assert not is_nil(logged_in_user.confirmed_at)

      # Second consumption fails (token is single-use)
      assert {:error, :not_found} = Accounts.consume_one_time_login_token(token)
    end

    test "refuses link generation for inactive users" do
      admin = insert_user(%{role: :admin})
      inactive_user = insert_user(%{role: :project_manager, active: false})

      assert {:error, :inactive} =
               Accounts.generate_one_time_login_link(inactive_user, admin, & &1)
    end

    test "refuses consumption for deactivated users" do
      admin = insert_user(%{role: :admin})
      target = insert_user(%{role: :project_manager})

      {:ok, link} = Accounts.generate_one_time_login_link(target, admin, & &1)

      # Deactivate user after link generation
      target |> Ecto.Changeset.change(%{active: false}) |> Repo.update!()

      assert {:error, :inactive} = Accounts.consume_one_time_login_token(link)
    end

    test "refuses invalid or expired tokens" do
      assert {:error, :not_found} = Accounts.consume_one_time_login_token("invalid_token")

      # Expired token test
      admin = insert_user(%{role: :admin})
      target = insert_user(%{role: :project_manager})
      {:ok, raw_token} = Accounts.generate_one_time_login_link(target, admin, & &1)

      # Manually age token in database to 3 days ago (exceeding 2 days validity)
      three_days_ago = DateTime.utc_now() |> DateTime.add(-3, :day) |> DateTime.truncate(:second)
      Repo.update_all(UserToken, set: [inserted_at: three_days_ago])

      assert {:error, :not_found} = Accounts.consume_one_time_login_token(raw_token)
    end
  end
end
