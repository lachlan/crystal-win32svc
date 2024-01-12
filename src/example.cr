require "log"
require "./win32svc"

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

Win32::Service.await
