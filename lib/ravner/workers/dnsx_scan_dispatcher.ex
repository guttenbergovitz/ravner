defmodule Ravner.Workers.DnsxScanDispatcher do
  @moduledoc """
  Dispatches ScanWorker jobs for domains that are due for a DNSX scan.
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
        where: not is_nil(m.dns_scan_interval_days),
        where:
          is_nil(m.dns_scanned_at) or
            fragment(
              "? + ? * interval '1 day' < ?",
              m.dns_scanned_at,
              m.dns_scan_interval_days,
              from_now(0, "second")
            ),
        select: m.domain_id
      )

    query
    |> Repo.all()
    |> Enum.map(fn id ->
      %{domain_id: id, scan_type: "dnsx"}
      |> Ravner.Workers.ScanWorker.new()
    end)
    |> Oban.insert_all()

    :ok
  end
end
