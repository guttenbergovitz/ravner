defmodule Ravner.Repo.Migrations.AddRdapScannedAtToDomainMetadata do
  use Ecto.Migration

  def change do
    alter table(:domain_metadata) do
      add(:rdap_scanned_at, :utc_datetime)
    end
  end
end
