require "spec_helper"
require "skylight/instrumenter"

enable = false
begin
  require "skylight/railtie"
  require "sidekiq/testing"
  enable = true
rescue LoadError => e
  puts "[INFO] Skipping Sidekiq integration specs; #{e}"
end

if enable
  describe "Sidekiq integration" do
    let(:report_environment) { "production" }
    let(:report_component) { "worker" }

    before :each do
      @original_env = ENV.to_hash
      set_agent_env
      ENV["SKYLIGHT_ENABLE_SIDEKIQ"] = "true"

      Sidekiq.logger.level = Logger::FATAL
      Sidekiq::Testing.inline!

      # `Sidekiq.server?` doesn't return true in testing
      allow(Sidekiq).to receive(:server?).and_return(true)

      # `Sidekiq.configure_server` doesn't run in testing usually, stub it
      # out so that it does
      allow(Sidekiq).to receive(:configure_server) do |&block|
        block.call(Sidekiq::Testing)
      end

      # Allow source locations to point to this directory
      Skylight.start!(root: __dir__)

      stub_const(
        "MyWorker",
        Class.new do
          include Sidekiq::Worker

          def perform(error_key = nil)
            Skylight.instrument category: "app.inside" do
              Skylight.instrument category: "app.zomg" do
                # nothing
                SpecHelper.clock.skip 1

                maybe_raise(error_key)
              end

              Skylight.instrument(category: "app.after_zomg") { SpecHelper.clock.skip 1 }
            end
          end

          private

          def maybe_raise(key)
            return unless key

            err = { "runtime_error" => RuntimeError, "shutdown" => Sidekiq::Shutdown }.fetch(key)

            raise err
          end
        end
      )
    end

    after :each do
      ENV.replace(@original_env)
      Skylight.stop!
      Sidekiq::Testing.disable!
    end

    context "with agent", :http, :agent do
      before :each do
        stub_config_validation
        stub_session_request
      end

      it "successfully calls into app" do
        MyWorker.perform_async

        server.wait resource: "/report"

        batch = server.reports[0]
        expect(batch).to_not be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]
        expect(endpoint.name).to eq("MyWorker<sk-segment>default</sk-segment>")
        expect(endpoint.traces.count).to eq(1)
        trace = endpoint.traces[0]

        names = trace.filter_spans.map { |s| s.event.category }

        expect(names).to eq(%w[app.sidekiq.worker app.inside app.zomg app.after_zomg])

        perform_line = MyWorker.instance_method(:perform).source_location[1]
        expect(batch.source_location(trace.spans[0])).to end_with("sidekiq_spec.rb:#{perform_line}")
      end

      it "records failed jobs in the error queue" do
        begin
          MyWorker.perform_async("runtime_error")
        rescue RuntimeError
        end

        server.wait resource: "/report"

        batch = server.reports[0]
        expect(batch).to_not be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]
        expect(endpoint.name).to eq("MyWorker<sk-segment>error</sk-segment>")
        expect(endpoint.traces.count).to eq(1)
        trace = endpoint.traces[0]

        names = trace.filter_spans.map { |s| s.event.category }

        expect(names).to eq(%w[app.sidekiq.worker app.inside app.zomg])

        perform_line = MyWorker.instance_method(:perform).source_location[1]
        expect(batch.source_location(trace.spans[0])).to end_with("sidekiq_spec.rb:#{perform_line}")
      end

      it "records killed jobs in the error queue" do
        begin
          MyWorker.perform_async("shutdown")
        rescue Sidekiq::Shutdown
        end

        server.wait resource: "/report"

        batch = server.reports[0]
        expect(batch).to_not be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]
        expect(endpoint.name).to eq("MyWorker<sk-segment>error</sk-segment>")
        expect(endpoint.traces.count).to eq(1)
        trace = endpoint.traces[0]

        names = trace.filter_spans.map { |s| s.event.category }

        expect(names).to eq(%w[app.sidekiq.worker app.inside app.zomg])

        perform_line = MyWorker.instance_method(:perform).source_location[1]
        expect(batch.source_location(trace.spans[0])).to end_with("sidekiq_spec.rb:#{perform_line}")
      end

      if defined?(Sidekiq::Extensions::PsychAutoload) && defined?(Rails)
        # Sidekiq::Extensions will be removed in Sidekiq 7
        # The !defined?(::Rails) is used internally in sidekiq
        # to determine whether extensions should be applied to all objects,
        # so we should only run this test when that will not happen.
        Psych::Visitors::ToRuby.prepend(Sidekiq::Extensions::PsychAutoload)

        it "records the proxied method for DelayedClass" do
          stub_const(
            "MyClass",
            Class.new do
              def self.delayable_method
                Skylight.instrument category: "app.inside" do
                  Skylight.instrument category: "app.delayed" do
                    SpecHelper.clock.skip 1
                  end
                end
              end

              # NOTE: We can't use the typical Sidekiq::Extensions.enable_delay! method,
              # because it interacts badly with Delayed::Job.
              require "sidekiq/extensions/generic_proxy"
              require "sidekiq/extensions/class_methods"

              def self.delay(options = {})
                Sidekiq::Extensions::Proxy.new(Sidekiq::Extensions::DelayedClass, self, options)
              end
            end
          )

          MyClass.delay.delayable_method

          server.wait resource: "/report"

          batch = server.reports[0]
          expect(batch).to_not be nil
          expect(batch.endpoints.count).to eq(1)
          endpoint = batch.endpoints[0]
          # Not all versions of sidekiq set display_class correctly
          # expect(endpoint.name).to eq("MyClass.delayable_method<sk-segment>default</sk-segment>")
          expect(endpoint.traces.count).to eq(1)
          trace = endpoint.traces[0]

          names = trace.filter_spans.map { |s| s.event.category }

          expect(names).to eq(%w[app.sidekiq.worker app.inside app.delayed])

          # This is not ideal, but we're tracking Sidekiq's internal Proxy
          expect(batch.source_location(trace.spans[0])).to end_with("sidekiq")
        end
      end
    end
  end
end
