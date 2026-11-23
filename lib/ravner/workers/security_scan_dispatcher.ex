defmodule Ravner.Workers.SecurityScanDispatcher do
  @moduledoc """
  Dispatches ScanWorker jobs for domains that are due for a security scan.
  """
  use Oban.Worker, queue: :default

  import Ecto.Query
  alias Ravner.Repo
  alias Ravner.Domains.Domain
  alias Ravner.Domains.DomainMetadata

  @scannable_states Domain.scannable_states()

  @impl Oban.Worker
  def perform(_job) do
    query =
      from(m in DomainMetadata,
        join: d in Domain,
        on: d.id == m.domain_id,
        where: d.lifecycle_state in ^@scannable_states,
        where: d.technical_status != :redirect,
        where: not is_nil(m.scan_interval_days),
        where:
          is_nil(m.last_security_scan_at) or
            fragment(
              "? + ? * interval '1 day' < ?",
              m.last_security_scan_at,
              m.scan_interval_days,
              from_now(0, "second")
            ),
        select: m.domain_id
      )

    query
    |> Repo.all()
    # Stagger enqueues over up to 30 minutes to smooth out the hourly spike —
    # heavy scans (naabu + nuclei) are expensive OS processes.
    |> Enum.map(fn id ->
      %{domain_id: id, scan_type: "security_scan"}
      |> Ravner.Workers.ScanWorker.new(schedule_in: :rand.uniform(1_800))
    end)
    |> Oban.insert_all()

    :ok
  end
end
