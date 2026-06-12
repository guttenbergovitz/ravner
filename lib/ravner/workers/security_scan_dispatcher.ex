defmodule Ravner.Workers.SecurityScanDispatcher do
  @moduledoc """
  Dispatches ScanWorker jobs for domains that are due for a security scan.
  """
  use Oban.Worker, queue: :default

  import Ecto.Query
  alias Ravner.Repo
  alias Ravner.Domains.Domain
  alias Ravner.Domains.DomainMetadata

  @impl Oban.Worker
  def perform(_job) do
    query =
      from(m in DomainMetadata,
        join: d in Domain,
        on: d.id == m.domain_id,
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
    |> Enum.map(fn id ->
      %{domain_id: id, scan_type: "security_scan"}
      |> Ravner.Workers.ScanWorker.new()
    end)
    |> Oban.insert_all()

    :ok
  end
end
