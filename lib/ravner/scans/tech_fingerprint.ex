defmodule Ravner.Scans.TechFingerprint do
  @moduledoc """
  Native Wappalyzer-style technology fingerprinting.

  Matches HTTP responses against a `technologies.json` fingerprint database
  (Wappalyzer format), replacing the external `webanalyze` binary. The
  database is refreshed periodically by
  `Ravner.Workers.TechnologiesUpdateWorker`.

  Rule types requiring JavaScript execution or raw sockets (`js`, `dom`,
  `probe`, `dns`) are not supported and silently ignored.
  """

  require Logger

  @cache_key {__MODULE__, :compiled}
  @max_body_bytes 300_000

  @type evidence :: %{
          String.t() => String.t() | [String.t()] | non_neg_integer() | nil
        }

  @doc """
  Fingerprints a fetched page and returns detected technology evidence.

  Returns `{:error, :fingerprints_not_found}` when no technologies file is
  available.
  """
  @spec analyze(String.t(), Req.Response.t()) :: {:ok, [evidence()]} | {:error, term()}
  def analyze(url, %Req.Response{} = response) when is_binary(url) do
    with {:ok, db} <- database() do
      targets = build_targets(url, response)

      detected =
        db.techs
        |> Enum.flat_map(&match_tech(&1, targets))
        |> add_implied(db.techs)
        |> Enum.uniq_by(& &1["name"])
        |> Enum.map(&Map.put(&1, "url", url))

      {:ok, detected}
    end
  end

  @default_timeout 10_000
  @default_user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

  @doc """
  Fetches `url` via HTTP and fingerprints it using the compiled technologies database.
  """
  @spec fingerprint_url(String.t(), keyword()) :: {:ok, [evidence()]} | {:error, term()}
  def fingerprint_url(url, opts \\ []) when is_binary(url) do
    timeout = Keyword.get(opts, :receive_timeout, @default_timeout)
    user_agent = Keyword.get(opts, :user_agent, @default_user_agent)
    redirect = Keyword.get(opts, :redirect, true)

    req_opts = [
      url: url,
      redirect: redirect,
      max_redirects: 5,
      retry: false,
      decode_body: false,
      receive_timeout: timeout,
      headers: [{"user-agent", user_agent}]
    ]

    case Req.get(req_opts) do
      {:ok, %Req.Response{} = response} ->
        case analyze(url, response) do
          {:ok, evidence} -> {:ok, evidence}
          {:error, :fingerprints_not_found} -> {:error, "technologies database not found"}
          {:error, reason} -> {:error, reason}
        end

      {:error, exception} ->
        {:error, "tech fingerprint fetch failed: #{inspect(exception)}"}
    end
  end

  @doc """
  Resolves the path to the technologies database file.
  """
  @spec technologies_path() :: String.t() | nil
  def technologies_path do
    candidates = [
      System.get_env("WAPPALYZER_TECHNOLOGIES_PATH"),
      Application.get_env(:ravner, :wappalyzer_technologies_path),
      default_path()
    ]

    Enum.find(candidates, fn
      path when is_binary(path) -> File.exists?(path)
      _ -> false
    end)
  end

  @doc """
  Path where the update worker writes the database (may not exist yet).
  """
  @spec storage_path() :: String.t()
  def storage_path do
    Application.get_env(:ravner, :wappalyzer_technologies_path) || default_path()
  end

  defp default_path do
    Path.join(:code.priv_dir(:ravner) |> to_string(), "wappalyzer/technologies.json")
  end

  # ─── Database loading & compilation ──────────────────────────────────────

  defp database do
    case technologies_path() do
      nil ->
        {:error, :fingerprints_not_found}

      path ->
        mtime =
          case File.stat(path, time: :posix) do
            {:ok, %{mtime: mtime}} -> mtime
            _ -> 0
          end

        case :persistent_term.get(@cache_key, nil) do
          {^path, ^mtime, db} -> {:ok, db}
          _ -> load_and_compile(path, mtime)
        end
    end
  end

  defp load_and_compile(path, mtime) do
    with {:ok, raw} <- File.read(path),
         {:ok, decoded} <- Jason.decode(raw) do
      db = compile_database(decoded)
      :persistent_term.put(@cache_key, {path, mtime, db})
      {:ok, db}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp compile_database(%{"technologies" => techs} = decoded) do
    categories = Map.get(decoded, "categories", %{})

    category_names =
      Map.new(categories, fn {id, cat} -> {to_string(id), cat["name"] || to_string(id)} end)

    %{
      techs: Enum.map(techs, fn {name, spec} -> compile_tech(name, spec, category_names) end)
    }
  end

  defp compile_database(techs) when is_map(techs) do
    compile_database(%{"technologies" => techs, "categories" => %{}})
  end

  defp compile_tech(name, spec, category_names) do
    %{
      name: name,
      categories: categories_for(spec, category_names),
      implies: List.wrap(spec["implies"]) |> Enum.map(&strip_attrs/1),
      matchers:
        Enum.flat_map(
          [:url, :headers, :cookies, :meta, :html, :scripts],
          &compile_rule(&1, Map.get(spec, Atom.to_string(&1)))
        )
    }
  end

  defp categories_for(spec, category_names) do
    case spec["category_names"] do
      names when is_list(names) and names != [] ->
        names

      _ ->
        spec
        |> Map.get("cats", [])
        |> List.wrap()
        |> Enum.map(&Map.get(category_names, to_string(&1)))
        |> Enum.reject(&is_nil/1)
    end
  end

  defp compile_rule(_type, nil), do: []

  defp compile_rule(type, patterns) when is_list(patterns) do
    Enum.flat_map(patterns, &compile_pattern(type, nil, &1))
  end

  defp compile_rule(type, patterns) when is_map(patterns) do
    Enum.flat_map(patterns, fn {key, value} ->
      value
      |> List.wrap()
      |> Enum.flat_map(&compile_pattern(type, String.downcase(key), &1))
    end)
  end

  defp compile_rule(type, pattern) when is_binary(pattern),
    do: compile_pattern(type, nil, pattern)

  defp compile_rule(_, _), do: []

  # Wappalyzer pattern syntax: "<regex>\;confidence:75\;version:\1"
  defp compile_pattern(type, key, pattern) when is_binary(pattern) do
    {regex_src, attrs} = split_attrs(pattern)

    case Regex.compile(regex_src, "i") do
      {:ok, regex} ->
        [
          %{
            type: type,
            key: key,
            regex: regex,
            source: regex_src,
            version: Map.get(attrs, "version"),
            confidence: parse_confidence(Map.get(attrs, "confidence"))
          }
        ]

      {:error, _} ->
        []
    end
  end

  defp compile_pattern(_, _, _), do: []

  defp split_attrs(pattern) do
    [regex_src | attr_parts] = String.split(pattern, "\\;")

    attrs =
      Map.new(attr_parts, fn part ->
        case String.split(part, ":", parts: 2) do
          [k, v] -> {k, v}
          _ -> {part, ""}
        end
      end)

    {regex_src, attrs}
  end

  defp strip_attrs(pattern) when is_binary(pattern) do
    pattern |> String.split("\\;") |> hd()
  end

  defp strip_attrs(other), do: to_string(other)

  defp parse_confidence(nil), do: 100

  defp parse_confidence(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 100
    end
  end

  # ─── Matching ────────────────────────────────────────────────────────────

  defp build_targets(url, response) do
    body =
      case response.body do
        body when is_binary(body) -> binary_part(body, 0, min(byte_size(body), @max_body_bytes))
        _ -> ""
      end

    %{
      url: url,
      headers: Map.new(response.headers, fn {k, v} -> {String.downcase(k), v} end),
      cookies: extract_cookies(response),
      meta: extract_meta(body),
      scripts: extract_script_srcs(body),
      html: body
    }
  end

  defp extract_cookies(response) do
    response
    |> Req.Response.get_header("set-cookie")
    |> Enum.map(fn header ->
      header |> String.split(";", parts: 2) |> hd() |> String.split("=", parts: 2)
    end)
    |> Enum.filter(&match?([_, _], &1))
    |> Map.new(fn [name, value] -> {String.trim(name), String.trim(value)} end)
  end

  defp extract_meta(body) do
    ~r/<meta\s[^>]*>/i
    |> Regex.scan(body)
    |> Enum.flat_map(fn [tag] ->
      name = attr_value(tag, "name") || attr_value(tag, "property")
      content = attr_value(tag, "content")

      if name && content, do: [{String.downcase(name), content}], else: []
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp extract_script_srcs(body) do
    Regex.scan(~r/<script\s[^>]*src=["']([^"']+)["']/i, body)
    |> Enum.map(fn [_, src] -> src end)
  end

  defp attr_value(tag, attr) do
    case Regex.run(~r/#{attr}\s*=\s*["']([^"']*)["']/i, tag) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp match_tech(tech, targets) do
    tech.matchers
    |> Enum.reduce_while(nil, fn matcher, best ->
      case run_matcher(matcher, targets) do
        nil ->
          {:cont, best}

        {version, confidence} when is_binary(version) and version != "" ->
          {:halt, {version, confidence}}

        {_no_version, confidence} ->
          new_best =
            case best do
              {nil, prev_conf} -> {nil, max(prev_conf, confidence)}
              {v, c} -> {v, c}
              nil -> {nil, confidence}
            end

          {:cont, new_best}
      end
    end)
    |> case do
      nil ->
        []

      {version, confidence} ->
        [
          %{
            "name" => tech.name,
            "version" => version,
            "categories" => tech.categories,
            "confidence" => confidence,
            "source" => "wappalyzer:direct",
            "implied" => false
          }
        ]
    end
  end

  defp run_matcher(%{type: :url, regex: regex} = m, targets),
    do: match_value(regex, targets.url, m)

  defp run_matcher(%{type: :html, regex: regex} = m, targets),
    do: match_value(regex, targets.html, m)

  defp run_matcher(%{type: :scripts, regex: regex} = m, targets),
    do: Enum.find_value(targets.scripts, &match_value(regex, &1, m))

  defp run_matcher(%{type: :headers, key: key, regex: regex, source: src} = m, targets) do
    case Map.fetch(targets.headers, key || "") do
      :error ->
        nil

      {:ok, values} ->
        if src == "" do
          {"", m.confidence}
        else
          Enum.find_value(List.wrap(values), &match_value(regex, &1, m))
        end
    end
  end

  defp run_matcher(%{type: :cookies, key: key, regex: regex, source: src} = m, targets) do
    case Map.fetch(targets.cookies, key || "") do
      :error ->
        nil

      {:ok, value} ->
        if src == "", do: {"", m.confidence}, else: match_value(regex, value, m)
    end
  end

  defp run_matcher(%{type: :meta, key: key, regex: regex, source: src} = m, targets) do
    case Map.fetch(targets.meta, key || "") do
      :error ->
        nil

      {:ok, values} ->
        if src == "" do
          {"", m.confidence}
        else
          Enum.find_value(List.wrap(values), &match_value(regex, &1, m))
        end
    end
  end

  defp match_value(_regex, nil, _m), do: nil

  defp match_value(regex, value, m) when is_binary(value) do
    case Regex.run(regex, value) do
      nil -> nil
      captures -> {render_version(m.version, captures), m.confidence}
    end
  end

  defp render_version(nil, _captures), do: nil
  defp render_version("", _captures), do: nil

  defp render_version(template, captures) do
    Regex.replace(~r/\\(\d)/, template, fn _, idx ->
      Enum.at(captures, String.to_integer(idx)) || ""
    end)
    |> String.trim()
    |> String.trim(".")
    |> case do
      "" -> nil
      version -> version
    end
  end

  defp add_implied(detected, techs) do
    detected_names = MapSet.new(detected, & &1["name"])

    implied =
      Enum.flat_map(detected, fn ev ->
        tech = Enum.find(techs, &(&1.name == ev["name"]))

        if tech do
          tech.implies
          |> Enum.reject(&MapSet.member?(detected_names, &1))
          |> Enum.map(fn name ->
            implied_tech = Enum.find(techs, &(&1.name == name))

            %{
              "name" => name,
              "version" => nil,
              "categories" => (implied_tech && implied_tech.categories) || [],
              "confidence" => 50,
              "source" => "wappalyzer:implied",
              "implied" => true
            }
          end)
        else
          []
        end
      end)

    case implied do
      [] -> detected
      _ -> add_implied(detected ++ implied, techs)
    end
  end
end
