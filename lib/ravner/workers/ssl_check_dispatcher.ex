defmodule Ravner.Workers.SslCheckDispatcher do
  @moduledoc """
  Dispatches SslCheckWorker jobs.
  """
  use Oban.Worker, queue: :default

  import Ecto.Query

  alias Ravner.Domains.Domain
  alias Ravner.Domains.DomainMetadata
  alias Ravner.Repo
  alias Ravner.Workers.ScanWorker

  @scannable_states Domain.scannable_states()

  @impl Oban.Worker
  def perform(_job) do
    domain_ids =
      from(m in DomainMetadata,
        join: d in Domain,
        on: d.id == m.domain_id,
        where: d.lifecycle_state in ^@scannable_states,
        where: d.technical_status != :redirect,
        where: not is_nil(m.ssl_check_interval_days),
        where:
          is_nil(m.ssl_scanned_at) or
            fragment(
              "? + ? * interval '1 day' < ?",
              m.ssl_scanned_at,
              m.ssl_check_interval_days,
              from_now(0, "second")
            ),
        select: m.domain_id
      )
      |> Repo.all()

    domain_ids
    |> Enum.map(fn domain_id ->
      %{domain_id: domain_id, scan_type: "ssl"}
      |> ScanWorker.new()
    end)
    |> Oban.insert_all()

    :ok
  end
end
