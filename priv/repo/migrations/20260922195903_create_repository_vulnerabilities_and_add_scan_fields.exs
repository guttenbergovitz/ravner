defmodule Ravner.Repo.Migrations.CreateRepositoryVulnerabilitiesAndAddScanFields do
  use Ecto.Migration

  def change do
    alter table(:project_repositories) do
      add(:scan_status, :string, default: "unscanned", null: false)
      add(:last_scanned_at, :utc_datetime)
      add(:vulnerability_count, :integer, default: 0, null: false)
      add(:critical_vuln_count, :integer, default: 0, null: false)
      add(:high_vuln_count, :integer, default: 0, null: false)
      add(:medium_vuln_count, :integer, default: 0, null: false)
      add(:low_vuln_count, :integer, default: 0, null: false)
    end

    create(index(:project_repositories, [:scan_status]))

    create table(:project_repository_vulnerabilities) do
      add(:project_repository_id, references(:project_repositories, on_delete: :delete_all),
        null: false
      )

      add(:ecosystem, :string, null: false)
      add(:package_name, :string, null: false)
      add(:package_version, :string, null: false)
      add(:cve_id, :string, null: false)
      add(:osv_id, :string, null: false)
      add(:severity, :string, null: false)
      add(:summary, :text)
      add(:details, :text)
      add(:fixed_version, :string)
      add(:manifest_file, :string)
      add(:references, {:array, :string}, default: [])

      timestamps(type: :utc_datetime)
    end

    create(index(:project_repository_vulnerabilities, [:project_repository_id]))
    create(index(:project_repository_vulnerabilities, [:cve_id]))
    create(index(:project_repository_vulnerabilities, [:severity]))
    create(index(:project_repository_vulnerabilities, [:ecosystem, :package_name]))
  end
end
