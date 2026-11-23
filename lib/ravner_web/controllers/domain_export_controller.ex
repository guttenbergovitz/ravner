defmodule RavnerWeb.DomainExportController do
  use RavnerWeb, :controller

  alias Ravner.Domains

  def index(conn, params) do
    scope = conn.assigns[:current_scope]

    search = Map.get(params, "search", "")
    ip = Map.get(params, "ip", "")
    lifecycle = parse_lifecycle(Map.get(params, "lifecycle", ""))
    include_subs = Map.get(params, "include_subdomains", "false") == "true"

    domains =
      Domains.list_domains_filtered_all(
        search: search,
        ip: ip,
        lifecycle: lifecycle,
        include_subdomains: include_subs,
        scope: scope
      )

    csv = Domains.to_csv(domains)

    suffix = if include_subs, do: "_all", else: "_apex"

    timestamp =
      DateTime.utc_now()
      |> Calendar.strftime("%Y%m%d_%H%M%S")

    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header(
      "content-disposition",
      "attachment; filename=\"ravner_domains#{suffix}_#{timestamp}.csv\""
    )
    |> send_resp(200, csv)
  end

  defp parse_lifecycle(""), do: nil
  defp parse_lifecycle(nil), do: nil

  defp parse_lifecycle(s) do
    valid = [
      :priority,
      :active,
      :placeholder,
      :under_review,
      :deprecated,
      :decommissioned,
      :abandoned
    ]

    atom = String.to_existing_atom(s)
    if atom in valid, do: atom, else: nil
  rescue
    _ -> nil
  end
end
