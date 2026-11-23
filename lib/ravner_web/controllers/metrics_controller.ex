defmodule RavnerWeb.MetricsController do
  @moduledoc """
  Controller exposing Prometheus / OpenMetrics scrape endpoint at `/metrics`.

  Returns metric counters, gauges, and summaries for all synthetic domain checks,
  vulnerabilities, SLA availability, and Erlang BEAM runtime metrics.
  """
  use RavnerWeb, :controller

  alias Ravner.Telemetry.PrometheusSerializer

  @content_type "text/plain; version=0.0.4; charset=utf-8"

  @doc """
  Renders the OpenMetrics / Prometheus scrape text.
  """
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    metrics_text = PrometheusSerializer.format()

    conn
    |> put_resp_content_type(@content_type)
    |> send_resp(200, metrics_text)
  end
end
