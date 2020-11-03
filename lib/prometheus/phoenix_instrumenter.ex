defmodule Prometheus.PhoenixInstrumenter do
  @moduledoc """

  Phoenix instrumenter generator for Prometheus. Implemented as Phoenix instrumenter.

  ### Usage

  1. Define your instrumenter:

  ```elixir
  defmodule MyApp.Endpoint.Instrumenter do
    use Prometheus.PhoenixInstrumenter
  end
  ```

  2. Call `MyApp.Endpoint.Instrumenter.setup/0` when application starts (e.g. supervisor setup):

  ```elixir
  MyApp.Endpoint.Instrumenter.setup()
  ```

  3. Add `MyApp.Endpoint.Instrumenter` to Phoenix endpoint instrumenters list:

  ```elixir
  config :myapp, MyApp.Endpoint,
    ...
    instrumenters: [MyApp.Endpoint.Instrumenter]
    ...

  ```

  ### Metrics

  Metrics implemented for the following built-in events:

  - `phoenix_controller_call`
    - `phoenix_controller_call_duration_<duration_unit>`;
  - `phoenix_controller_render`
    - `phoenix_controller_render_duration_<duration_unit>`;
  - `phoenix_channel_join`
    - `phoenix_channel_join_duration_<duration_unit>`;
  - `phoenix_channel_receive`
    - `phoenix_channel_receive_duration_<duration_unit>`.

  Predefined controller call labels:
   - action - action name (*default*);
   - controller - controller module name (*default*);
   - status - reponse status.

  Predefined controller render labels (Phoenix <1.5 only):
   - format - name of the format of the template (*default*);
   - template - name of the template (*default*);
   - view - name of the view (*default*).
   
  Predefined error view render labels (Phoenix >=1.5 only):
   - status - response status (*default*);
   - function - name of the function where the error happened;
   - module - name of the module where the error happened.

  Predefined channel join/receive labels:
   - channel - current channel module (*default*);
   - endpoint - endpoint module where this socket originated;
   - handler - socket module where this socket originated;
   - pubsub_server - registered name of the socket's pubsub server;
   - serializer - serializer for socket messages;
   - topic - string topic  (*default*);
   - transport - socket's transport (*default*);

  Predefined channel receive labels:
   - event - event name (*default*).

  Predefined common http request labels:
   - host - request host;
   - method - request method;
   - port - request port;
   - scheme - request scheme.

  Predefined compile metadata labels (Phoenix <1.5 only):
   - application - name of OTP application;
   - file - name of file where instrumented function resides;
   - function - name of the instrumented function;
   - line - source line number;
   - module - instrumented function's module.

  ### Configuration

  Instrumenter configured via `:prometheus` application environment `MyApp.Endpoint.Instrumenter` key
  (i.e. app env key is the name of the instrumenter).

  Default configuration:

  ```elixir
  config :prometheus, MyApp.Endpoint.Instrumenter,
    controller_call_labels: [:controller, :action],
    duration_buckets: :prometheus_http.microseconds_duration_buckets(),
    registry: :default,
    duration_unit: :microseconds
  ```

  Available duration units:
   - microseconds;
   - milliseconds;
   - seconds;
   - minutes;
   - hours;
   - days.

  Bear in mind that buckets are ***<duration_unit>*** so if you are not using default unit
  you also have to override buckets.

  ### Custom Labels

  Custom labels can be defined by implementing label_value/2 function in instrumenter directly or
  by calling exported function from other module.

  ```elixir
  config :prometheus, MyApp.Endpoint.Instrumenter,
    controller_call_labels: [:controller,
                             :my_private_label,
                             {:label_from_other_module, Module}, # eqv to {Module, label_value}
                             {:non_default_label_value, {Module, custom_fun}}]

  defmodule MyApp.Endpoint.Instrumenter do
    use Prometheus.PhoenixInstrumenter

    def label_value(:my_private_label, conn) do
      ...
    end
  end
  ```
  """

  import Phoenix.Controller
  require Logger
  require Prometheus.Contrib.HTTP
  alias Prometheus.Contrib.HTTP

  use Prometheus.Config,
    controller_call_labels: [:action, :controller],
    controller_render_labels: [:format, :template, :view],
    controller_error_rendered_labels: [:status],
    channel_join_labels: [:channel, :topic, :transport],
    channel_receive_labels: [:channel, :topic, :transport, :event],
    duration_buckets: HTTP.microseconds_duration_buckets(),
    registry: :default,
    duration_unit: :microseconds

  use Prometheus.Metric

  ## support different endpoints via endpoint label
  defmacro __using__(_opts) do
    module_name = __CALLER__.module

    controller_call_labels = Config.controller_call_labels(module_name)
    ncontroller_call_labels = normalize_labels(controller_call_labels)
    duration_buckets = Config.duration_buckets(module_name)

    controller_render_labels = Config.controller_render_labels(module_name)
    ncontroller_render_labels = normalize_labels(controller_render_labels)
    render_duration_buckets = Config.duration_buckets(module_name)

    controller_error_rendered_labels = Config.controller_error_rendered_labels(module_name)
    ncontroller_error_rendered_labels = normalize_labels(controller_error_rendered_labels)
    error_rendered_duration_buckets = Config.duration_buckets(module_name)

    channel_join_labels = Config.channel_join_labels(module_name)
    nchannel_join_labels = normalize_labels(channel_join_labels)
    channel_join_duration_buckets = Config.duration_buckets(module_name)

    channel_receive_labels = Config.channel_receive_labels(module_name)
    nchannel_receive_labels = normalize_labels(channel_receive_labels)
    channel_receive_duration_buckets = Config.duration_buckets(module_name)

    registry = Config.registry(module_name)
    duration_unit = Config.duration_unit(module_name)

    quote do
      import Phoenix.Controller
      require Logger
      use Prometheus.Metric

      def setup do
        Histogram.declare(
          name: unquote(:"phoenix_controller_call_duration_#{duration_unit}"),
          help: unquote("Whole controller pipeline execution time in #{duration_unit}."),
          labels: unquote(ncontroller_call_labels),
          buckets: unquote(duration_buckets),
          duration_unit: unquote(duration_unit),
          registry: unquote(registry)
        )

        # only observed under Phoenix <1.5
        Histogram.declare(
          name: unquote(:"phoenix_controller_render_duration_#{duration_unit}"),
          help: unquote("View rendering time in #{duration_unit}."),
          labels: unquote(ncontroller_render_labels),
          buckets: unquote(render_duration_buckets),
          duration_unit: unquote(duration_unit),
          registry: unquote(registry)
        )

        # only observed under Phoenix >=1.5
        Histogram.declare(
          name: unquote(:"phoenix_controller_error_rendered_duration_#{duration_unit}"),
          help: unquote("View error rendering time in #{duration_unit}."),
          labels: unquote(ncontroller_error_rendered_labels),
          buckets: unquote(error_rendered_duration_buckets),
          duration_unit: unquote(duration_unit),
          registry: unquote(registry)
        )

        Histogram.declare(
          name: unquote(:"phoenix_channel_join_duration_#{duration_unit}"),
          help: unquote("Phoenix channel join handler time in #{duration_unit}"),
          labels: unquote(nchannel_join_labels),
          buckets: unquote(channel_join_duration_buckets),
          duration_unit: unquote(duration_unit),
          registry: unquote(registry)
        )

        Histogram.declare(
          name: unquote(:"phoenix_channel_receive_duration_#{duration_unit}"),
          help: unquote("Phoenix channel receive handler time in #{duration_unit}"),
          labels: unquote(nchannel_receive_labels),
          buckets: unquote(channel_receive_duration_buckets),
          duration_unit: unquote(duration_unit),
          registry: unquote(registry)
        )

        # for Phoenix >=1.5, where instrumentation is done using telemetry
        telemetry_setup()
      end

      defp telemetry_setup() do
        events = [
          [:phoenix, :endpoint, :stop],
          [:phoenix, :error_rendered],
          [:phoenix, :channel_joined],
          [:phoenix, :channel_handled_in]
        ]

        Logger.info("Attaching the phoenix telemetry events: #{inspect(events)}")

        :telemetry.attach_many(
          "telemetry_web_event_handler" <> Atom.to_string(unquote(module_name)),
          events,
          &handle_event/4,
          nil
        )
      end

      def handle_event(
            [:phoenix, :endpoint, :stop],
            %{duration: duration},
            %{conn: conn} = metadata,
            _config
          ) do
        labels = unquote(construct_labels(controller_call_labels, :conn))

        Histogram.observe(
          [
            registry: unquote(registry),
            name: unquote(:"phoenix_controller_call_duration_#{duration_unit}"),
            labels: labels
          ],
          duration
        )
      end

      def handle_event(
            [:phoenix, :error_rendered],
            %{duration: duration},
            %{conn: conn, status: status, stacktrace: stacktrace} = metadata,
            _config
          ) do
        labels = unquote(construct_labels(controller_error_rendered_labels, :conn_error_rendered))

        Histogram.observe(
          [
            registry: unquote(registry),
            name: unquote(:"phoenix_controller_error_rendered_duration_#{duration_unit}"),
            labels: labels
          ],
          duration
        )
      end

      def handle_event(
            [:phoenix, :channel_joined],
            %{duration: duration},
            %{socket: socket} = metadata,
            _config
          ) do
        labels = unquote(construct_labels(channel_join_labels, :socket))

        Histogram.observe(
          [
            registry: unquote(registry),
            name: unquote(:"phoenix_channel_join_duration_#{duration_unit}"),
            labels: labels
          ],
          duration
        )
      end

      def handle_event(
            [:phoenix, :channel_handled_in],
            %{duration: duration},
            %{socket: socket, event: event} = metadata,
            _config
          ) do
        labels = unquote(construct_labels(channel_receive_labels, :socket))

        Histogram.observe(
          [
            registry: unquote(registry),
            name: unquote(:"phoenix_channel_receive_duration_#{duration_unit}"),
            labels: labels
          ],
          duration
        )
      end

      def phoenix_controller_call(:start, compile, data) do
        Map.put(data, :compile, compile)
      end

      def phoenix_controller_call(:stop, time_diff, %{conn: conn, compile: compile} = data) do
        labels = unquote(construct_labels(controller_call_labels, :conn))

        Histogram.observe(
          [
            registry: unquote(registry),
            name: unquote(:"phoenix_controller_call_duration_#{duration_unit}"),
            labels: labels
          ],
          time_diff
        )
      end

      def phoenix_controller_render(:start, compile, data) do
        Map.put(data, :compile, compile)
      end

      def phoenix_controller_render(
            :stop,
            time_diff,
            %{view: view, template: template, format: format, conn: conn, compile: compile} = data
          ) do
        labels = unquote(construct_labels(controller_render_labels, :conn))

        Histogram.observe(
          [
            registry: unquote(registry),
            name: unquote(:"phoenix_controller_render_duration_#{duration_unit}"),
            labels: labels
          ],
          time_diff
        )
      end
    end
  end

  defp normalize_labels(labels) do
    for label <- labels do
      case label do
        {name, _} -> name
        name -> name
      end
    end
  end

  defp construct_labels(labels, type) do
    for label <- labels, do: label_value(label, type)
  end

  ## controller labels
  defp label_value(:action, type) when type in [:conn, :conn_error_rendered] do
    quote do
      try do
        action_name(conn)
      rescue
        _ -> nil
      end
    end
  end

  defp label_value(:controller, type) when type in [:conn, :conn_error_rendered] do
    quote do
      try do
        inspect(controller_module(conn))
      rescue
        _ -> nil
      end
    end
  end

  defp label_value(:status, :conn) do
    quote do
      inspect(conn.status)
    end
  end

  # for some reasone error_rendered rolls its own status which we prefere in these cases
  # otherwise :conn_error_rendered is equivalent to :conn
  defp label_value(:status, :conn_error_rendered) do
    quote do
      inspect(status)
    end
  end

  ## view labels
  defp label_value(:format, _) do
    quote do
      format
    end
  end

  defp label_value(:template, _) do
    quote do
      template
    end
  end

  defp label_value(:view, _) do
    quote do
      view
    end
  end

  ## request labels
  defp label_value(:host, type) when type in [:conn, :conn_error_rendered] do
    quote do
      conn.host
    end
  end

  defp label_value(:method, type) when type in [:conn, :conn_error_rendered] do
    quote do
      conn.method
    end
  end

  defp label_value(:port, type) when type in [:conn, :conn_error_rendered] do
    quote do
      conn.port
    end
  end

  defp label_value(:scheme, type) when type in [:conn, :conn_error_rendered] do
    quote do
      conn.scheme
    end
  end

  ## channel metrics
  defp label_value(:channel, :socket) do
    quote do
      inspect(socket.channel)
    end
  end

  defp label_value(:endpoint, :socket) do
    quote do
      inspect(socket.endpoint)
    end
  end

  defp label_value(:handler, :socket) do
    quote do
      inspect(socket.handler)
    end
  end

  defp label_value(:pubsub_server, :socket) do
    quote do
      inspect(socket.pubsub_server)
    end
  end

  defp label_value(:serializer, :socket) do
    quote do
      inspect(socket.serializer)
    end
  end

  defp label_value(:topic, :socket) do
    quote do
      socket.topic
    end
  end

  defp label_value(:transport, :socket) do
    quote do
      to_string(socket.transport)
    end
  end

  ## channel receive labels
  defp label_value(:event, _) do
    quote do
      event
    end
  end

  ## compile metadata labels
  defp label_value(:application, _) do
    quote do
      inspect(compile.application)
    end
  end

  defp label_value(:file, _) do
    quote do
      compile.file
    end
  end

  defp label_value(:function, :conn_error_rendered) do
    quote do
      [{_module, function, _, _} | _] = stacktrace
      inspect(function)
    end
  end

  defp label_value(:function, _) do
    quote do
      inspect(compile.function)
    end
  end

  defp label_value(:line, _) do
    quote do
      compile.line
    end
  end

  defp label_value(:module, :conn_error_rendered) do
    quote do
      [{module, _function, _, _} | _] = stacktrace
      inspect(module)
    end
  end

  defp label_value(:module, _) do
    quote do
      inspect(compile.module)
    end
  end

  defp label_value({label, {module, fun}}, type) when type in [:conn, :conn_error_rendered] do
    quote do
      unquote(module).unquote(fun)(unquote(label), conn)
    end
  end

  defp label_value({label, {module, fun}}, :socket) do
    quote do
      unquote(module).unquote(fun)(unquote(label), socket)
    end
  end

  defp label_value({label, module}, type) when type in [:conn, :conn_error_rendered] do
    quote do
      unquote(module).label_value(unquote(label), conn)
    end
  end

  defp label_value({label, module}, :socket) do
    quote do
      unquote(module).label_value(unquote(label), socket)
    end
  end

  defp label_value(label, type) when type in [:conn, :conn_error_rendered] do
    quote do
      label_value(unquote(label), conn)
    end
  end

  defp label_value(label, :socket) do
    quote do
      label_value(unquote(label), socket)
    end
  end
end
