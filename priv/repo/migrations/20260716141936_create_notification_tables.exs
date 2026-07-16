defmodule Ravner.Repo.Migrations.CreateNotificationTables do
  use Ecto.Migration

  def change do
    # Global/group/per-domain notification policies
    create table(:uptime_notification_policies) do
      add :name, :string, null: false
      add :scope, :string, null: false
      add :domain_id, references(:domains, on_delete: :delete_all)
      add :enabled, :boolean, default: true, null: false
      add :still_down_interval_minutes, :integer, default: 30
      add :max_reminders, :integer, default: 5

      timestamps(type: :utc_datetime)
    end

    create index(:uptime_notification_policies, [:scope])
    create index(:uptime_notification_policies, [:domain_id])

    create unique_index(:uptime_notification_policies, [:scope],
             where: "scope = 'global'",
             name: :uptime_notification_policies_global_unique
           )

    # Named notification groups
    create table(:uptime_notification_groups) do
      add :name, :string, null: false
      add :description, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:uptime_notification_groups, [:name])

    # Join: policies <-> groups
    create table(:uptime_policy_groups, primary_key: false) do
      add :policy_id, references(:uptime_notification_policies, on_delete: :delete_all),
        null: false

      add :group_id, references(:uptime_notification_groups, on_delete: :delete_all), null: false
    end

    create unique_index(:uptime_policy_groups, [:policy_id, :group_id])

    # Recipients (belong to a group OR directly to a policy)
    create table(:uptime_notification_recipients) do
      add :policy_id, references(:uptime_notification_policies, on_delete: :delete_all)
      add :group_id, references(:uptime_notification_groups, on_delete: :delete_all)
      add :user_id, references(:users, on_delete: :delete_all)
      add :email, :string
      add :phone, :string
      add :channels, :string, null: false, default: "email"

      timestamps(type: :utc_datetime)
    end

    create index(:uptime_notification_recipients, [:policy_id])
    create index(:uptime_notification_recipients, [:group_id])

    # Delivery tracking (idempotency)
    create table(:uptime_notification_deliveries) do
      add :downtime_window_id, references(:downtime_windows, on_delete: :delete_all), null: false

      add :recipient_id, references(:uptime_notification_recipients, on_delete: :delete_all),
        null: false

      add :event_type, :string, null: false
      add :sequence, :integer, default: 0
      add :channel, :string, null: false
      add :delivered_at, :utc_datetime
      add :error, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(
             :uptime_notification_deliveries,
             [:downtime_window_id, :recipient_id, :event_type, :sequence, :channel],
             name: :uptime_deliveries_idempotent_idx
           )
  end
end
