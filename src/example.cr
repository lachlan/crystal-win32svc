require "simplog"
require "./win32svc"

Log.setup_from_env(backend: SimpLog::FileBackend.new, default_level: :debug)

# handle request to stop the service
Win32::Service.on_stop do
  Log.info { "Service requested to stop" }
end

i = 0

# run the service
Win32::Service.run do |args|
  Log.info { "Run loop started: #{args}" }

  while Win32::Service.started?
    Log.info { "Run loop iteration: #{i}" }
    i += 1
    sleep 1.second
    break unless i < 10
  end

  Log.info { "Run loop ended" }
end

# ...do other stuff...

Log.info { "Awaiting service" }
Win32::Service.await

Log.info { "Service ended" }
