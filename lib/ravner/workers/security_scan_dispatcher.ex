defmodule Ravner.Workers.SecurityScanDispatcher do
  @moduledoc """
  Dispatches ScanWorker jobs for domains that are due for a security scan.
  """
  use Oban.Worker, queue: :default

  import Ecto.Query
  alias Ravner.Repo
  alias Ravner.Domains.DomainMetadata

  @impl Oban.Worker
  def perform(_job) do
    # Find domains where scan_interval_days is not null AND
    # (last_security_scan_at is null OR last_security_scan_at + interval < NOW())
    
    query =
      from(m in DomainMetadata,
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
