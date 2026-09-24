defmodule Reacher.Filter.PhoenixTest do
  use ExUnit.Case, async: false

  import Reacher.TestProject, only: [in_project: 2]

  test "does not report controller actions referenced by a router" do
    in_project(
      fn module ->
        controller = Module.concat(module, Controller)
        html = Module.concat(module, HTML)
        router = Module.concat(module, Router)

        """
        defmodule #{inspect(controller)} do
          def listed(_conn, _params), do: :ok
          def unlisted(_conn, _params), do: :ok
        end

        defmodule #{inspect(html)} do
          def listed(assigns), do: assigns
          def unlisted(assigns), do: assigns
        end

        defmodule #{inspect(router)} do
          def __routes__ do
            [%{plug: #{inspect(controller)}, plug_opts: :listed}]
          end
        end
        """
      end,
      fn module ->
        controller = Module.concat(module, Controller)
        html = Module.concat(module, HTML)
        unreachable = Reacher.analyze() |> MapSet.new()

        refute MapSet.member?(unreachable, {controller, :listed, 2})
        refute MapSet.member?(unreachable, {html, :listed, 1})
        assert MapSet.member?(unreachable, {controller, :unlisted, 2})
        assert MapSet.member?(unreachable, {html, :unlisted, 1})
      end
    )
  end

  test "does not report Phoenix entry points present in compiled metadata" do
    in_project(
      fn module ->
        plug = Module.concat(module, Plug)
        session = Module.concat(module, Session)
        hook = Module.concat(module, Hook)
        component = Module.concat(module, Component)
        renderer = Module.concat(module, Renderer)
        endpoint = Module.concat(module, Endpoint)
        router = Module.concat(module, Router)
        unrelated = Module.concat(module, Unrelated)

        """
        defmodule #{inspect(plug)} do
          def init(options), do: options
          def call(conn, _options), do: conn
        end

        defmodule #{inspect(session)} do
          def build(conn), do: %{"path" => conn.request_path}
        end

        defmodule #{inspect(hook)} do
          def on_mount(_name, _params, _session, socket), do: {:cont, socket}
        end

        defmodule #{inspect(component)} do
          def __components__, do: %{card: %{}}
          def card(assigns), do: assigns
        end

        defmodule #{inspect(renderer)} do
          def render(template, assigns), do: {template, assigns}
        end

        defmodule #{inspect(endpoint)} do
          def __sockets__ do
            [{"/socket", Example.Socket, [websocket: [check_origin: {__MODULE__, :check_origin, []}]]}]
          end

          def config(:render_errors), do: [formats: [json: #{inspect(renderer)}]]
          def check_origin(_uri), do: true
        end

        defmodule #{inspect(router)} do
          def __routes__ do
            [
              %{plug: #{inspect(plug)}, plug_opts: []},
              %{
                plug: Phoenix.LiveView.Plug,
                plug_opts: :show,
                metadata: %{
                  phoenix_live_view: {
                    Example.Live,
                    :show,
                    [],
                    %{
                      extra: %{
                        session: {#{inspect(session)}, :build, []},
                        on_mount: [%{function: Function.capture(#{inspect(hook)}, :on_mount, 4)}]
                      }
                    }
                  }
                }
              }
            ]
          end
        end

        defmodule #{inspect(unrelated)} do
          def call(conn, _options), do: conn
          def build(conn), do: conn
          def on_mount(_name, _params, _session, socket), do: {:cont, socket}
          def card(assigns), do: assigns
          def render(template, assigns), do: {template, assigns}
          def check_origin(_uri), do: true
        end
        """
      end,
      fn module ->
        plug = Module.concat(module, Plug)
        session = Module.concat(module, Session)
        hook = Module.concat(module, Hook)
        component = Module.concat(module, Component)
        renderer = Module.concat(module, Renderer)
        endpoint = Module.concat(module, Endpoint)
        unrelated = Module.concat(module, Unrelated)
        unreachable = Reacher.analyze() |> MapSet.new()

        for mfa <- [
              {plug, :call, 2},
              {session, :build, 1},
              {hook, :on_mount, 4},
              {renderer, :render, 2},
              {endpoint, :check_origin, 1}
            ] do
          refute MapSet.member?(unreachable, mfa)
        end

        # Component metadata describes declarations, not dynamic registrations.
        assert MapSet.member?(unreachable, {component, :card, 1})

        for mfa <- [
              {unrelated, :call, 2},
              {unrelated, :build, 1},
              {unrelated, :on_mount, 4},
              {unrelated, :card, 1},
              {unrelated, :render, 2},
              {unrelated, :check_origin, 1}
            ] do
          assert MapSet.member?(unreachable, mfa)
        end
      end
    )
  end
end
