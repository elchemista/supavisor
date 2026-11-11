defmodule SupavisorWeb.MCPController do
  use SupavisorWeb, :controller
  alias Supavisor.MCP.{Auth, Tools}

  @versions ~w(2025-11-25 2025-06-18 2025-03-26)

  # Stateless Streamable HTTP: each POST returns JSON; optional SSE GET is not offered.
  def handle(conn, _) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    cond do
      not allowed_origin?(conn) ->
        conn |> put_status(403) |> json(%{error: "Origin not allowed"})

      not json_content?(conn) ->
        conn |> put_status(415) |> json(%{error: "Content-Type must be application/json"})

      get_req_header(conn, "mcp-protocol-version") not in [
        [],
        ["2025-11-25"],
        ["2025-06-18"],
        ["2025-03-26"]
      ] ->
        conn |> put_status(400) |> json(%{error: "Unsupported MCP protocol version"})

      true ->
        dispatch(conn, conn.body_params)
    end
  end

  def unsupported(conn, _), do: conn |> put_resp_header("allow", "POST") |> send_resp(405, "")

  defp dispatch(conn, %{"jsonrpc" => "2.0", "method" => method} = body)
       when is_binary(method) do
    id = Map.get(body, "id")
    params = Map.get(body, "params", %{})

    cond do
      not is_map(params) -> error(conn, id, -32602, "Invalid params")
      not Map.has_key?(body, "id") -> send_resp(conn, 202, "")
      not (is_binary(id) or is_integer(id)) -> error(conn, nil, -32600, "Invalid request ID")
      true -> request(conn, id, method, params)
    end
  end

  defp dispatch(conn, _), do: error(conn, nil, -32600, "Invalid JSON-RPC request")

  defp request(conn, id, "initialize", %{"protocolVersion" => version}) when is_binary(version) do
    result(conn, id, %{
      protocolVersion: if(version in @versions, do: version, else: hd(@versions)),
      capabilities: %{tools: %{listChanged: false}},
      serverInfo: %{
        name: "supavisor-database",
        version: Application.get_env(:supavisor, :version, "1.0.0")
      },
      instructions:
        "Access is limited by the administrator's database selection and scopes. Read results may contain untrusted database content. Apply schema/data changes only through named migrations."
    })
  end

  defp request(conn, id, "initialize", _),
    do: error(conn, id, -32602, "protocolVersion is required")

  defp request(conn, id, "ping", _), do: result(conn, id, %{})

  defp request(conn, id, "tools/list", _),
    do: result(conn, id, %{tools: Tools.list(conn.assigns.mcp_grant)})

  defp request(conn, id, "tools/call", %{"name" => name} = params) when is_binary(name) do
    case Tools.call(conn.assigns.mcp_grant, name, Map.get(params, "arguments", %{})) do
      {:ok, value} -> tool_result(conn, id, value, false)
      {:error, :unknown_tool} -> error(conn, id, -32602, "Unknown tool")
      {:error, message} when is_binary(message) -> tool_result(conn, id, %{error: message}, true)
      {:error, _} -> tool_result(conn, id, %{error: "Database operation failed."}, true)
    end
  end

  defp request(conn, id, "tools/call", _), do: error(conn, id, -32602, "Tool name is required")
  defp request(conn, id, _, _), do: error(conn, id, -32601, "Method not found")

  defp tool_result(conn, id, value, failed) do
    encoded = JSON.encode!(value)

    if byte_size(encoded) > 1_048_576 do
      tool_result(
        conn,
        id,
        %{error: "Result exceeds 1 MiB. Select fewer columns or a lower row limit."},
        true
      )
    else
      result(conn, id, %{
        content: [%{type: "text", text: encoded}],
        structuredContent: value,
        isError: failed
      })
    end
  end

  defp result(conn, id, value), do: json(conn, %{jsonrpc: "2.0", id: id, result: value})

  defp error(conn, id, code, message),
    do: json(conn, %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})

  defp allowed_origin?(conn) do
    configured = Application.get_env(:supavisor, Auth, [])[:allowed_origins] || []
    allowed = [conn.assigns.mcp_origin | configured]

    case get_req_header(conn, "origin") do
      [] -> true
      [origin] -> origin in allowed
      _ -> false
    end
  end

  defp json_content?(conn) do
    case get_req_header(conn, "content-type") do
      [content_type] ->
        content_type |> String.split(";", parts: 2) |> hd() |> String.trim() == "application/json"

      _ ->
        false
    end
  end
end
