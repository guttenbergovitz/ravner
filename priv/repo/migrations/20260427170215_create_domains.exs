defmodule Ravner.Repo.Migrations.CreateDomains do
  use Ecto.Migration

  def change do
    create table(:domains) do
      add(:name, :string, null: false)
      add(:type, :string, null: false, default: "domain")
      add(:parent_domain_id, references(:domains, on_delete: :nilify_all))
      add(:url, :string)
      add(:lifecycle_state, :string, null: false, default: "active")
      add(:pm_email, :string)
      add(:po_email, :string)
      add(:delivery_organization, :string)
      add(:hosting_platform, :string)
      add(:domain_registrar, :string)
      add(:repository_url, :string)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:domains, [:name]))
    create(index(:domains, [:parent_domain_id]))
    create(index(:domains, [:lifecycle_state]))
  end
end
