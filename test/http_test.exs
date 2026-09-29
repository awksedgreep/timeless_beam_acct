# Where an answer is expected, the time allowed for it is generous: it is
# given back as soon as the answer comes, and a machine that is busy with
# something else is not a plane that is down.
defmodule TimelessBeamAcct.HttpTest do
  use ExUnit.Case, async: true

  alias TimelessBeamAcct.{Http, TestPlane}

  # Asked for by name below, and not applications this one depends on.
  @compile {:no_warn_undefined, [:ssl, :public_key]}

  setup do
    {:ok, plane: start_supervised!(TestPlane)}
  end

  defp elapsed(work) do
    started = System.monotonic_time(:millisecond)
    result = work.()
    {result, System.monotonic_time(:millisecond) - started}
  end

  test "a post arrives with its headers and its body", %{plane: plane} do
    TestPlane.respond_with(plane, 200, "stored")

    headers = [{"Content-Type", "text/plain"}, {"Authorization", "Bearer secret"}]

    assert {:ok, 200, "stored"} =
             Http.post(
               TestPlane.url(plane) <> "/api/v1/import?a=1",
               ["m ", ["1"]],
               headers,
               5_000
             )

    assert [request] = TestPlane.requests(plane)
    assert request.method == "POST"
    assert request.path == "/api/v1/import?a=1"
    assert request.body == "m 1"
    assert request.headers["content-type"] == "text/plain"
    assert request.headers["authorization"] == "Bearer secret"
    assert request.headers["content-length"] == "3"
    assert request.headers["connection"] == "close"
    assert request.headers["host"] == "127.0.0.1:#{TestPlane.port(plane)}"
    assert request.headers["user-agent"] =~ ~r/\Atimeless-beam-acct\/\d+\.\d+\.\d+/
  end

  test "a get asks for a path and sends no body", %{plane: plane} do
    TestPlane.respond_with(plane, 200, "ok")

    assert {:ok, 200, "ok"} = Http.get(TestPlane.url(plane) <> "/health", [], 5_000)

    assert [%{method: "GET", path: "/health", body: ""} = request] = TestPlane.requests(plane)
    refute Map.has_key?(request.headers, "content-length")
  end

  test "a URL with no path asks for the root", %{plane: plane} do
    assert {:ok, 200, ""} = Http.get(TestPlane.url(plane), [], 5_000)
    assert [%{path: "/"}] = TestPlane.requests(plane)
  end

  test "a status that is not a success is returned, and is not an error", %{plane: plane} do
    TestPlane.respond_with(plane, 500, "the store is full")
    assert {:ok, 500, "the store is full"} = Http.post(TestPlane.url(plane), "x", [], 5_000)

    TestPlane.respond_with(plane, 401, ~s({"error":"unauthorized"}))
    assert {:ok, 401, ~s({"error":"unauthorized"})} = Http.get(TestPlane.url(plane), [], 5_000)
  end

  test "a body is read whether it has a length, comes in chunks, or ends at the close",
       %{plane: plane} do
    body = String.duplicate("what was answered, ", 40)
    TestPlane.respond_with(plane, 200, body)

    for mode <- [:content_length, :chunked, :until_close] do
      TestPlane.mode(plane, mode)

      assert {:ok, 200, ^body} = Http.post(TestPlane.url(plane), "x", [], 5_000),
             "the body was not read as #{inspect(mode)}"
    end
  end

  test "an answer with no body is read as an empty one", %{plane: plane} do
    for mode <- [:content_length, :chunked, :until_close] do
      TestPlane.mode(plane, mode)
      assert {:ok, 200, ""} = Http.post(TestPlane.url(plane), "x", [], 5_000)
    end

    TestPlane.respond_with(plane, 204, "")
    assert {:ok, 204, ""} = Http.post(TestPlane.url(plane), "x", [], 5_000)
  end

  test "no more of a body is kept than would be shown", %{plane: plane} do
    body = :binary.copy(<<"0123456789abcdef">>, 8 * 1024)
    assert byte_size(body) == 128 * 1024
    TestPlane.respond_with(plane, 200, body)

    for mode <- [:content_length, :chunked, :until_close] do
      TestPlane.mode(plane, mode)
      assert {:ok, 200, kept} = Http.get(TestPlane.url(plane), [], 2_000)
      assert byte_size(kept) == 64 * 1024, "#{inspect(mode)} kept #{byte_size(kept)} bytes"
      assert kept == binary_part(body, 0, 64 * 1024)
    end
  end

  test "a body larger than a packet arrives whole", %{plane: plane} do
    body = :crypto.strong_rand_bytes(300_000)
    assert {:ok, 200, ""} = Http.post(TestPlane.url(plane), body, [], 2_000)
    assert [%{body: ^body}] = TestPlane.requests(plane)
  end

  test "a connection that is refused is an error, at once", %{plane: plane} do
    url = TestPlane.url(plane)
    TestPlane.stop_listening(plane)

    {result, took} = elapsed(fn -> Http.post(url, "x", [], 500) end)

    assert result == {:error, :econnrefused}
    assert took < 400
  end

  test "a plane that comes back is found where it was", %{plane: plane} do
    url = TestPlane.url(plane)
    TestPlane.stop_listening(plane)
    assert {:error, :econnrefused} = Http.post(url, "x", [], 500)

    :ok = TestPlane.listen(plane)
    assert TestPlane.url(plane) == url
    assert {:ok, 200, ""} = Http.post(url, "x", [], 5_000)
  end

  test "a server that accepts and never answers is an error within the time given",
       %{plane: plane} do
    TestPlane.mode(plane, :hang)

    {result, took} = elapsed(fn -> Http.post(TestPlane.url(plane), "x", [], 200) end)

    assert result == {:error, :timeout}
    assert took >= 200
    assert took < 1_000
  end

  test "the time given is for the whole request, and not for each step of it",
       %{plane: plane} do
    # Sixty pieces, fifty milliseconds apart: no one read waits for long,
    # and the answer takes three seconds to arrive.
    TestPlane.respond_with(plane, 200, String.duplicate("x", 400))
    TestPlane.mode(plane, {:drip, 50})

    {result, took} = elapsed(fn -> Http.get(TestPlane.url(plane), [], 300) end)

    assert result == {:error, :timeout}
    assert took >= 300
    assert took < 1_500
  end

  test "no time is no time", %{plane: plane} do
    assert {:error, :timeout} = Http.get(TestPlane.url(plane), [], 0)
  end

  test "what answers and is not HTTP is an error" do
    {:ok, listening} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, port} = :inet.port(listening)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listening, 2_000)
        :ok = :gen_tcp.send(socket, "SSH-2.0-OpenSSH_9.9\r\n")
        :gen_tcp.recv(socket, 0, 1_000)
        :gen_tcp.close(socket)
      end)

    assert {:error, {:bad_response, _}} = Http.get("http://127.0.0.1:#{port}/", [], 500)

    Task.await(server)
    :gen_tcp.close(listening)
  end

  test "an answer that ends before its length is an error" do
    {:ok, listening} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, port} = :inet.port(listening)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listening, 2_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\nshort")
        :gen_tcp.close(socket)
      end)

    assert {:error, :closed} = Http.get("http://127.0.0.1:#{port}/", [], 500)

    Task.await(server)
    :gen_tcp.close(listening)
  end

  test "a URL that is not http or https is refused, and nothing is sent" do
    for url <- ["ftp://127.0.0.1/", "127.0.0.1:8428", "http://", "", "/health", nil] do
      assert {:error, {:bad_url, ^url}} = Http.post(url, "x", [], 200)
    end
  end

  test "a header that would be two is refused, and nothing is sent", %{plane: plane} do
    url = TestPlane.url(plane)

    assert {:error, {:bad_header, "Authorization"}} =
             Http.post(url, "x", [{"Authorization", "Bearer a\r\nX-Other: b"}], 200)

    assert {:error, {:bad_header, _}} = Http.post(url, "x", [{"A: b\r\nC", "d"}], 200)
    assert {:error, {:bad_header, _}} = Http.post(url, "x", [{:accept, "d"}], 200)
    assert TestPlane.requests(plane) == []
  end

  test "reasons are put into words" do
    assert Http.format_error(:econnrefused) == "connection refused"
    assert Http.format_error(:timeout) == "timed out"
    assert Http.format_error(:nxdomain) == "non-existing domain"
    assert Http.format_error(:closed) =~ "closed"
    assert Http.format_error(:ssl_unavailable) =~ "ssl"
    assert Http.format_error({:bad_url, "ftp://x"}) =~ ~s("ftp://x")

    assert Http.format_error({:tls_alert, {:unknown_ca, ~c"TLS client:  Unknown\n CA"}}) ==
             "TLS client: Unknown CA"

    # What has no words is at least named.
    assert Http.format_error(:some_reason) == "some_reason"
    assert Http.format_error({:some, "reason"}) == ~s({:some, "reason"})
  end

  describe "https" do
    setup do
      # Mix leaves out of the code path what the project does not depend
      # on. A node that has ssl is what is being tested, so it is put back.
      for app <- [:asn1, :public_key, :ssl], :code.lib_dir(app) == {:error, :bad_name} do
        [ebin | _] =
          "#{:code.root_dir()}/lib/#{app}-*/ebin" |> Path.wildcard() |> Enum.sort(:desc)

        true = :code.add_pathz(String.to_charlist(ebin))
      end

      name = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}

      # The defaults are a key and a digest that TLS no longer accepts.
      made = [digest: :sha256, key: {:namedCurve, :secp256r1}]

      data =
        :public_key.pkix_test_data(%{
          server_chain: %{root: made, intermediates: [], peer: made ++ [extensions: [name]]},
          client_chain: %{root: made, intermediates: [], peer: made}
        })

      {:ok, _} = Application.ensure_all_started(:ssl)

      {:ok, listening} =
        :ssl.listen(
          0,
          [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}, log_level: :none] ++
            Keyword.take(data.server_config, [:cert, :key, :cacerts])
        )

      {:ok, {_address, port}} = :ssl.sockname(listening)
      test = self()

      server =
        spawn_link(fn ->
          with {:ok, socket} <- :ssl.transport_accept(listening, 5_000),
               {:ok, socket} <- :ssl.handshake(socket, 2_000),
               {:ok, request} <- :ssl.recv(socket, 0, 2_000) do
            send(test, {:asked, request})

            :ssl.send(
              socket,
              "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n" <>
                "6\r\nstored\r\n5\r\n here\r\n0\r\n\r\n"
            )

            :ssl.close(socket)
          else
            other -> send(test, {:refused, other})
          end
        end)

      on_exit(fn -> :ssl.close(listening) end)

      {:ok, port: port, server: server, trusted: data.client_config[:cacerts]}
    end

    test "a plane whose certificate is trusted is posted to", context do
      assert {:ok, 200, "stored here"} =
               Http.post("https://localhost:#{context.port}/insert", "body", [], 2_000,
                 cacerts: context.trusted
               )

      assert_receive {:asked, request}
      assert request =~ "POST /insert HTTP/1.1\r\n"
      assert request =~ "Host: localhost:#{context.port}\r\n"
    end

    test "a plane whose certificate is not trusted is not", context do
      assert {:error, {:tls_alert, {:unknown_ca, _}}} =
               Http.post("https://localhost:#{context.port}/insert", "body", [], 2_000)

      refute_received {:asked, _}
    end

    test "a plane whose certificate is for another name is not", context do
      assert {:error, {:tls_alert, {alert, said}}} =
               Http.post("https://127.0.0.1:#{context.port}/insert", "body", [], 2_000,
                 cacerts: context.trusted
               )

      # Which alert it is has changed from one release of OTP to the next.
      assert alert in [:bad_certificate, :handshake_failure]
      assert to_string(said) =~ "hostname_check_failed" or alert == :bad_certificate

      refute_received {:asked, _}
    end
  end
end
