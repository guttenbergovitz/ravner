defmodule Ravner.Accounts.GovernancePoliciesTest do
  use Ravner.DataCase, async: true

  alias Ravner.Accounts.User
  alias Ravner.Accounts.UserInviteResource
  alias Ravner.Inventory
  alias Ravner.Inventory.Organization
  alias Ravner.Inventory.Project
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
      confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second),
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

  describe "Organization Ash policies" do
    test "Brand Manager can create organization under their brand, but not under another brand" do
      bm_user = insert_user(%{role: :brand_manager})
      bm_person = insert_person(%{user_id: bm_user.id})
      my_brand = insert_brand(%{brand_manager_id: bm_person.id})

      other_brand = insert_brand(%{})

      # Creating under my brand succeeds
      id1 = unique_id()

      assert {:ok, _org} =
               Organization
               |> Ash.Changeset.for_create(
                 :create,
                 %{name: "My Org #{id1}", slug: "my-org-#{id1}", brand_id: my_brand.id},
                 actor: bm_user
               )
               |> Ash.create()

      # Creating under another brand fails with forbidden
      id2 = unique_id()

      assert {:error, %Ash.Error.Forbidden{}} =
               Organization
               |> Ash.Changeset.for_create(
                 :create,
                 %{name: "Other Org #{id2}", slug: "other-org-#{id2}", brand_id: other_brand.id},
                 actor: bm_user
               )
               |> Ash.create()
    end

    test "Company Manager can update their own organization, but cannot update another" do
      cm_user = insert_user(%{role: :organization_manager})
      cm_person = insert_person(%{user_id: cm_user.id})
      my_org = insert_organization(%{manager_id: cm_person.id})
      other_org = insert_organization(%{})

      # Updating my org succeeds
      assert {:ok, _} =
               my_org
               |> Ash.Changeset.for_update(:update, %{notes: "Updated note"}, actor: cm_user)
               |> Ash.update()

      # Updating other org fails
      assert {:error, %Ash.Error.Forbidden{}} =
               other_org
               |> Ash.Changeset.for_update(:update, %{notes: "Hacked note"}, actor: cm_user)
               |> Ash.update()
    end
  end

  describe "Project Ash policies" do
    test "Company Manager can create project under their organization, but not under another" do
      cm_user = insert_user(%{role: :organization_manager})
      cm_person = insert_person(%{user_id: cm_user.id})
      my_org = insert_organization(%{manager_id: cm_person.id})
      other_org = insert_organization(%{})

      # Creating under my org succeeds
      id1 = unique_id()

      assert {:ok, _project} =
               Project
               |> Ash.Changeset.for_create(
                 :create,
                 %{name: "Project #{id1}", slug: "proj-#{id1}", organization_id: my_org.id},
                 actor: cm_user
               )
               |> Ash.create()

      # Creating under another org fails
      id2 = unique_id()

      assert {:error, %Ash.Error.Forbidden{}} =
               Project
               |> Ash.Changeset.for_create(
                 :create,
                 %{name: "Project #{id2}", slug: "proj-#{id2}", organization_id: other_org.id},
                 actor: cm_user
               )
               |> Ash.create()
    end
  end

  describe "UserInviteResource Ash policies" do
    test "Delivery Head can invite supervisors and PMs, but not global roles or brand managers" do
      dh = insert_user(%{role: :delivery_head})

      # Can invite supervisor
      assert {:ok, _} =
               UserInviteResource
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   token: "token-#{unique_id()}",
                   email: "sup-#{unique_id()}@example.com",
                   role: :pm_supervisor,
                   invited_by_id: dh.id,
                   expires_at: DateTime.utc_now() |> DateTime.add(2, :day)
                 },
                 actor: dh
               )
               |> Ash.create()

      # Can invite PM
      assert {:ok, _} =
               UserInviteResource
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   token: "token-#{unique_id()}",
                   email: "pm-#{unique_id()}@example.com",
                   role: :project_manager,
                   invited_by_id: dh.id,
                   expires_at: DateTime.utc_now() |> DateTime.add(2, :day)
                 },
                 actor: dh
               )
               |> Ash.create()

      # Cannot invite admin
      assert {:error, %Ash.Error.Forbidden{}} =
               UserInviteResource
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   token: "token-#{unique_id()}",
                   email: "admin-#{unique_id()}@example.com",
                   role: :admin,
                   invited_by_id: dh.id,
                   expires_at: DateTime.utc_now() |> DateTime.add(2, :day)
                 },
                 actor: dh
               )
               |> Ash.create()

      # Cannot invite brand manager
      assert {:error, %Ash.Error.Forbidden{}} =
               UserInviteResource
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   token: "token-#{unique_id()}",
                   email: "bm-#{unique_id()}@example.com",
                   role: :brand_manager,
                   invited_by_id: dh.id,
                   expires_at: DateTime.utc_now() |> DateTime.add(2, :day)
                 },
                 actor: dh
               )
               |> Ash.create()
    end

    test "Supervisor can only invite PMs reporting to them" do
      sup = insert_user(%{role: :pm_supervisor})
      other_sup = insert_user(%{role: :pm_supervisor})

      # Inviting PM with supervisor_id = self succeeds
      assert {:ok, _} =
               UserInviteResource
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   token: "token-#{unique_id()}",
                   email: "pm1-#{unique_id()}@example.com",
                   role: :project_manager,
                   supervisor_id: sup.id,
                   invited_by_id: sup.id,
                   expires_at: DateTime.utc_now() |> DateTime.add(2, :day)
                 },
                 actor: sup
               )
               |> Ash.create()

      # Inviting PM under another supervisor fails
      assert {:error, %Ash.Error.Forbidden{}} =
               UserInviteResource
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   token: "token-#{unique_id()}",
                   email: "pm2-#{unique_id()}@example.com",
                   role: :project_manager,
                   supervisor_id: other_sup.id,
                   invited_by_id: sup.id,
                   expires_at: DateTime.utc_now() |> DateTime.add(2, :day)
                 },
                 actor: sup
               )
               |> Ash.create()
    end
  end

  describe "Person Ash policies" do
    test "Company Manager can create person under their organization, but not under another" do
      cm_user = insert_user(%{role: :organization_manager})
      cm_person = insert_person(%{user_id: cm_user.id})
      my_org = insert_organization(%{manager_id: cm_person.id})
      other_org = insert_organization(%{})

      id1 = unique_id()

      assert {:ok, _} =
               Ravner.Inventory.Person
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   first_name: "John#{id1}",
                   last_name: "Doe#{id1}",
                   email: "john#{id1}@example.com",
                   organization_id: my_org.id
                 },
                 actor: cm_user
               )
               |> Ash.create()

      id2 = unique_id()

      assert {:error, %Ash.Error.Forbidden{}} =
               Ravner.Inventory.Person
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   first_name: "Jane#{id2}",
                   last_name: "Doe#{id2}",
                   email: "jane#{id2}@example.com",
                   organization_id: other_org.id
                 },
                 actor: cm_user
               )
               |> Ash.create()
    end
  end

  describe "UserResource Ash policies" do
    test "Supervisor can update PM they supervise, but cannot update other users" do
      sup = insert_user(%{role: :pm_supervisor})
      pm = insert_user(%{role: :project_manager, supervisor_id: sup.id})
      other_pm = insert_user(%{role: :project_manager})

      pm_resource = Ash.get!(Ravner.Accounts.UserResource, pm.id, actor: @admin_actor)
      other_resource = Ash.get!(Ravner.Accounts.UserResource, other_pm.id, actor: @admin_actor)

      # Supervisor updates their supervised PM
      assert {:ok, _} =
               pm_resource
               |> Ash.Changeset.for_update(:admin_update, %{name: "Updated PM Name"}, actor: sup)
               |> Ash.update()

      # Supervisor cannot update other PM
      assert {:error, %Ash.Error.Forbidden{}} =
               other_resource
               |> Ash.Changeset.for_update(:admin_update, %{name: "Hacked PM Name"}, actor: sup)
               |> Ash.update()
    end
  end
end
