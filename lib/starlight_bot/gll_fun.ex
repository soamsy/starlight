defmodule StarlightBot.GllFun do
  @site "https://gll-fun.com"
  @rest_base "https://admin.gll-fun.com/rest/v1"

  @main_js_re ~r{/static/js/main\.[a-f0-9]+\.js}
  @chunk_map_re ~r/(\d+):"([a-f0-9]{6,})"/
  @jwt_re ~r/ey[A-Za-z0-9_-]{10,}\.ey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/

  @bundle_changed_error "gll-fun's bundle layout changed, update StarlightBot.GllFun"

  def fetch_api_key do
    with {:ok, home} <- get(@site <> "/"),
         [main_js_path] <- Regex.run(@main_js_re, home),
         {:ok, main_js} <- get(@site <> main_js_path) do
      chunk_bodies =
        @chunk_map_re
        |> Regex.scan(main_js)
        |> Enum.flat_map(fn [_, id, hash] ->
          case get("#{@site}/static/js/#{id}.#{hash}.chunk.js") do
            {:ok, body} -> [body]
            _ -> []
          end
        end)

      case find_supabase_key([main_js | chunk_bodies]) do
        nil -> {:error, @bundle_changed_error}
        key -> {:ok, key}
      end
    else
      _ -> {:error, @bundle_changed_error}
    end
  end

  def rest(table, api_key, query \\ %{"select" => "*"}) do
    qs = Enum.map_join(query, "&", fn {k, v} -> "#{k}=#{URI.encode_www_form(v)}" end)

    case get("#{@rest_base}/#{table}?#{qs}", [{"apikey", api_key}]) do
      {:ok, body} -> {:ok, Jason.decode!(body)}
      {:error, reason} -> {:error, reason}
    end
  end

  def download_image(url), do: get(url)

  defp find_supabase_key(bodies) do
    Enum.find_value(bodies, fn body ->
      @jwt_re
      |> Regex.scan(body)
      |> List.flatten()
      |> Enum.find(&supabase_jwt?/1)
    end)
  end

  defp supabase_jwt?(token) do
    with [_header, payload, _sig] <- String.split(token, ".", parts: 3),
         {:ok, decoded} <- Base.url_decode64(pad_base64(payload)),
         {:ok, %{"iss" => "supabase"}} <- Jason.decode(decoded) do
      true
    else
      _ -> false
    end
  end

  defp pad_base64(s) do
    case rem(byte_size(s), 4) do
      0 -> s
      n -> s <> String.duplicate("=", 4 - n)
    end
  end

  defp get(url, extra_headers \\ [], timeout \\ 30_000) do
    Application.ensure_all_started(:ssl)
    uri = URI.parse(url)
    host = String.to_charlist(uri.host)
    path = uri.path || "/"
    path = if uri.query, do: path <> "?" <> uri.query, else: path

    with {:ok, sock} <-
           :ssl.connect(host, uri.port || 443, [
             :binary,
             active: false,
             verify: :verify_peer,
             cacerts: :public_key.cacerts_get(),
             server_name_indication: host,
             customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
           ], timeout),
         :ok <- :ssl.send(sock, build_request(uri.host, path, extra_headers)),
         {:ok, head, rest} <- read_head(sock, <<>>, timeout) do
      {status, headers} = parse_head(head)
      body = read_body(sock, headers, rest, timeout)
      :ssl.close(sock)
      if status == 200, do: {:ok, body}, else: {:error, status}
    end
  end

  defp build_request(host, path, extra_headers) do
    header_lines =
      [
        "Host: #{host}",
        "User-Agent: starlight-bot theme_packs importer",
        "Accept: */*",
        "Connection: close"
      ] ++ Enum.map(extra_headers, fn {k, v} -> "#{k}: #{v}" end)

    Enum.join(["GET #{path} HTTP/1.1" | header_lines], "\r\n") <> "\r\n\r\n"
  end

  defp read_head(sock, buffer, timeout) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        {:ok, head, rest}

      [_] ->
        case :ssl.recv(sock, 0, timeout) do
          {:ok, data} -> read_head(sock, buffer <> data, timeout)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp parse_head(head) do
    [status_line | header_lines] = String.split(head, "\r\n")

    status =
      case Regex.run(~r/^HTTP\/[\d.]+ (\d+)/, status_line) do
        [_, code] -> String.to_integer(code)
        _ -> nil
      end

    headers =
      Enum.reduce(header_lines, %{}, fn line, acc ->
        case String.split(line, ": ", parts: 2) do
          [k, v] -> Map.put(acc, String.downcase(k), v)
          _ -> acc
        end
      end)

    {status, headers}
  end

  defp read_body(sock, headers, rest, timeout) do
    cond do
      String.contains?(Map.get(headers, "transfer-encoding", ""), "chunked") ->
        read_chunked(sock, rest, timeout, <<>>)

      len = Map.get(headers, "content-length") ->
        read_exact(sock, rest, String.to_integer(len), timeout)

      true ->
        read_until_closed(sock, rest, timeout)
    end
  end

  defp read_exact(_sock, buffer, len, _timeout) when byte_size(buffer) >= len,
    do: binary_part(buffer, 0, len)

  defp read_exact(sock, buffer, len, timeout) do
    case :ssl.recv(sock, 0, timeout) do
      {:ok, data} -> read_exact(sock, buffer <> data, len, timeout)
      {:error, _} -> buffer
    end
  end

  defp read_until_closed(sock, buffer, timeout) do
    case :ssl.recv(sock, 0, timeout) do
      {:ok, data} -> read_until_closed(sock, buffer <> data, timeout)
      {:error, _} -> buffer
    end
  end

  defp read_chunked(sock, buffer, timeout, acc) do
    case :binary.split(buffer, "\r\n") do
      [size_hex, rest] ->
        size = String.to_integer(String.trim(size_hex), 16)

        if size == 0 do
          acc
        else
          {chunk_data, remaining} = take_chunk(sock, rest, size, timeout)
          read_chunked(sock, remaining, timeout, acc <> chunk_data)
        end

      [_] ->
        case :ssl.recv(sock, 0, timeout) do
          {:ok, data} -> read_chunked(sock, buffer <> data, timeout, acc)
          {:error, _} -> acc
        end
    end
  end

  defp take_chunk(_sock, buffer, size, _timeout) when byte_size(buffer) >= size + 2 do
    {binary_part(buffer, 0, size), binary_part(buffer, size + 2, byte_size(buffer) - size - 2)}
  end

  defp take_chunk(sock, buffer, size, timeout) do
    case :ssl.recv(sock, 0, timeout) do
      {:ok, data} -> take_chunk(sock, buffer <> data, size, timeout)
      {:error, _} -> {buffer, <<>>}
    end
  end
end
