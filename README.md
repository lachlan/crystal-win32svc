# win32svc

Crystal lang shard which provides support for running a Crystal
application as a Windows service.

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     win32svc:
       github: lachlan/crystal-win32svc
   ```

2. Run `shards install`

## Usage

3. Pass a block to `Win32::Service.run` to run that block as the
   service logic. The block should either monitor the
   `Win32::Service.started?` boolean and exit when it becomes `false`,
   or register a block to handle Windows service stop and shutdown
   events by calling `Win32::Service.on_stop`, to ensure the service
   stops when requested by the Windows service controller.

```crystal
require "win32svc"

# optionally register a block as the stop event handler
Win32::Service.on_stop do
  Log.info { "Service requested to stop" }
  # ...stop running the service
end

# run the service
Win32::Service.run do |args|
  # continue running while service remains started
  while Win32::Service.started?
    # ...run loop for doing stuff...
  end
end

# wait for the service to finish
Win32::Service.await
```

4. Compile `shards build -Dpreview_mt` - to run as a Windows Service
   necessarily requires at least 2 threads: the main thread which is
   transformed into the service dispatcher, and another thread to run
   the service itself. For this to work, it requires compiling using
   the `preview_mt` flag to enable multithreading in Crystal.

5. Create Windows service

```bat
sc create <ServiceName> binpath= <ExecutablePath>
sc config <ServiceName> start= <boot|system|auto|demand|disabled|delayed-auto>
sc config <ServiceName> DisplayName= "<Service Display Name>"
sc description <ServiceName> "<Service Description>"
```

6. Run Windows service

```bat
sc start <ServiceName>
...
sc stop <ServiceName>
```

## Contributing

1. Fork it (<https://github.com/lachlan/crystal-win32svc/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Lachlan Dowding](https://github.com/lachlan) - creator and maintainer
