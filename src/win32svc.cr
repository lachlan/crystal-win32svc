require "uuid"
require "win32cr"
require "win32cr/foundation"
require "win32cr/system/console"
require "win32cr/system/services"

module Win32
  # Provides support for running a Crystal application as a Windows
  # service.
  module Service
    @@service_connected = true
    @@service_control_handler : Proc(UInt32, Void)?
    @@service_dispatcher : Thread?
    @@service_main_inner : Proc(Array(String), Nil)?
    @@service_main_outer : Proc(UInt32, Pointer(Pointer(UInt8)), Void)?
    @@service_name = UUID.v4.to_s
    @@service_runner : Thread?
    @@service_started = false
    @@service_stopped = false
    @@service_status_handle : LibWin32::SERVICE_STATUS_HANDLE?
    @@service_lock = Mutex.new
    @@service_stop_channel = Channel(Bool).new

    # Registers the given *block* to handle the Windows service stop
    # event. The *block* will be called some time later when and if
    # the Windows service receives a stop or shutdown control from the
    # Windows service controller.
    def self.on_stop(&block) : Nil
      @@service_stop_block = block
    end

    # Runs the given *block* as a Windows service. The *block* should
    # monitor the `Win32::Service.started?` boolean and exit when it
    # becomes `false` to ensure the service stops when requested.
    #
    # ```
    # Win32::Service.run do |args|
    #   while Win32::Service.started?
    #     # do stuff
    #   end
    # end
    #
    # Win32::Service.await
    # ```
    def self.run(&block : Proc(Array(String), Nil)) : Nil
      unless started?
        @@service_block = block

        @@service_control_handler = Proc(UInt32, Void).new do |control|
          case control
          when LibWin32::SERVICE_CONTROL_STOP, LibWin32::SERVICE_CONTROL_SHUTDOWN
            stop blocking: false
          else
            # do nothing
          end
        end

        @@service_main_inner = Proc(Array(String), Nil).new do |args|
          @@service_runner = Thread.new do
            begin
              @@service_status_handle = LibWin32.RegisterServiceCtrlHandlerA(@@service_name, @@service_control_handler.not_nil!) if connected?

              set_started true

              if handle = @@service_status_handle
                set_win32_service_status handle, LibWin32::SERVICE_STATUS_CURRENT_STATE::SERVICE_RUNNING
              end

              if service_block = @@service_block
                service_block.call args
              end
            ensure
              set_started false
              if handle = @@service_status_handle
                set_win32_service_status handle, LibWin32::SERVICE_STATUS_CURRENT_STATE::SERVICE_STOPPED
              end
              @@service_stop_channel.send true
            end
          end
        end

        @@service_main_outer = Proc(UInt32, Pointer(Pointer(UInt8)), Void).new do |argc, argv|
          if inner = @@service_main_inner
            # prepare command line arguments as an array of strings
            args = Array(String).new(argc)
            argv.to_slice(argc).each do |chars|
              args << String.new(chars)
            end

            inner.call args
          end
        end

        @@service_dispatcher = Thread.new do
          console_allocated = false
          begin
            console_allocated = LibWin32.AllocConsole != 0
            services = uninitialized LibWin32::SERVICE_TABLE_ENTRYA[2]
            services[0] = LibWin32::SERVICE_TABLE_ENTRYA.new(lp_service_name: @@service_name, lp_service_proc: @@service_main_outer.not_nil!)
            services[1] = LibWin32::SERVICE_TABLE_ENTRYA.new(lp_service_name: nil, lp_service_proc: nil)

            result = LibWin32.StartServiceCtrlDispatcherA(services.to_unsafe)

            if result == 0
              @@service_connected = false
              if WinError.value == WinError::ERROR_FAILED_SERVICE_CONTROLLER_CONNECT
                # the application process was not started via the
                # Windows service controller, so we will run the
                # service main inner callback directly so the
                # application can still be run directly from the
                # console when required
                if inner = @@service_main_inner
                  inner.call Array(String).new(0)
                end
              else
                raise "#{WinError.value}"
              end
            end
          ensure
            LibWin32.FreeConsole if console_allocated
            @@service_stop_channel.send true
          end
        end
      end
    end

    # Stops the service
    def self.stop : Nil
      stop blocking: true
    end

    # Stops the service, optionally waiting for process to complete
    private def self.stop(blocking : Bool) : Nil
      @@service_lock.synchronize do
        if started?
          set_started false
          if service_stop_block = @@service_stop_block
            service_stop_block.call
          end
          await if blocking
        end
      end
    end

    # Waits for the service to finish running
    def self.await : Nil
      unless stopped?
        @@service_stop_channel.receive # service main
        @@service_stop_channel.receive # service dispatcher
        @@service_stopped = true
      end
    end

    # Returns whether the service is started
    def self.started? : Bool
      @@service_started
    end

    # Returns whether the service is connected to the Windows Service
    # Controller. If false, this indicates the process was started in
    # a console directly rather than via the Windows Service
    # Controller.
    private def self.connected? : Bool
      @@service_connected
    end

    # Returns whether the service has stopped
    private def self.stopped? : Bool
      @@service_stopped
    end

    # Sets whether the service is started or stopped
    private def self.set_started(started : Bool) : Nil
      @@service_lock.synchronize do
        unless @@service_started == started
          if handle = @@service_status_handle
            status = started ? LibWin32::SERVICE_STATUS_CURRENT_STATE::SERVICE_START_PENDING : LibWin32::SERVICE_STATUS_CURRENT_STATE::SERVICE_STOP_PENDING
            set_win32_service_status handle, status
          end
          @@service_started = started
        end
      end
    end

    # Sets the given *status* on the service associated with the given *handle*
    private def self.set_win32_service_status(handle : LibWin32::SERVICE_STATUS_HANDLE, status : LibWin32::SERVICE_STATUS_CURRENT_STATE) : Nil
      @@service_lock.synchronize do
        if connected?
          service_status = LibWin32::SERVICE_STATUS.new
          service_status.dw_service_type = LibWin32::ENUM_SERVICE_TYPE::SERVICE_WIN32_OWN_PROCESS
          service_status.dw_current_state = status
          service_status.dw_win32_exit_code = LibWin32::WIN32_ERROR::NO_ERROR
          service_status.dw_service_specific_exit_code = 0
          service_status.dw_check_point = 0
          service_status.dw_wait_hint = 1000

          if service_status.dw_current_state == LibWin32::SERVICE_STATUS_CURRENT_STATE::SERVICE_START_PENDING
            service_status.dw_controls_accepted = 0
          else
            service_status.dw_controls_accepted = LibWin32::SERVICE_ACCEPT_SHUTDOWN | LibWin32::SERVICE_ACCEPT_STOP
          end

          unless LibWin32.SetServiceStatus(handle, pointerof(service_status))
            raise "Error setting service status"
          end
        end
      end
    end
  end
end
