defmodule Ravner.Workers.A11yScanDispatcher do
  @moduledoc """
  Cron dispatcher: enqueues a11y scans for domains with scheduling enabled.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  import Ecto.Query

  alias Ravner.Domains.DomainMetadata
  alias Ravner.Repo
  alias Ravner.Workers.A11yScanWorker

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    domain_ids =
      from(m in DomainMetadata,
        where: not is_nil(m.a11y_scan_interval_days),
        where: m.http_status == 200,
        where:
          is_nil(m.last_a11y_scan_at) or
            (m.a11y_scan_interval_days == 7 and
               m.last_a11y_scan_at < datetime_add(^now, -7, "day")) or
            (m.a11y_scan_interval_days == 30 and
               m.last_a11y_scan_at < datetime_add(^now, -30, "day")),
        select: m.domain_id
      )
      |> Repo.all()

    Enum.each(domain_ids, fn domain_id ->
      %{domain_id: domain_id}
      |> A11yScanWorker.new(unique: [period: 3600, fields: [:args], keys: [:domain_id]])
      |> Oban.insert()
    end)

    :ok
  end
end
