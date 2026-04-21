require "uuid"

module Win32
  Log = ::Log.for("Win32")

  # Provides support for running a Crystal application as a Windows
  # service.
  module Service
    Log = Win32::Log.for("Service")

    @@service_connected = true
    @@service_control_handler : Proc(UInt32, Void)?
    @@service_dispatcher : Fiber::ExecutionContext::Isolated?
    @@service_main_inner : Proc(Array(String), Nil)?
    @@service_main_outer : Proc(UInt32, Pointer(Pointer(UInt8)), Void)?
    @@service_name = UUID.v4.to_s
    @@service_runner : Fiber::ExecutionContext::Isolated?
    @@service_started = false
    @@service_stopped = false
    @@service_status_handle : User32::SERVICE_STATUS_HANDLE?

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

        Process.on_terminate do |reason|
          stop blocking: false
        end

        @@service_control_handler = Proc(UInt32, Void).new do |control|
          Log.debug { "control handler: received `#{control}`" }
          case control
          when User32::SERVICE_CONTROL_STOP, User32::SERVICE_CONTROL_SHUTDOWN
            Log.debug { "control handler: calling `stop blocking: false`" }
            stop blocking: false
          else
            # do nothing
          end
        end

        @@service_main_inner = Proc(Array(String), Nil).new do |args|
          @@service_runner = Fiber::ExecutionContext::Isolated.new("RUNNER") do
            begin
              if connected?
                Log.debug { "runner: calling `User32.RegisterServiceCtrlHandlerA(#{@@service_name}, #{@@service_control_handler.not_nil!})`" }
                @@service_status_handle = User32.RegisterServiceCtrlHandlerA(@@service_name, @@service_control_handler.not_nil!)
              else
                Log.debug { "runner: not connected to WIN32 SERVICE CONTROLLER" }
              end

              set_started true

              if handle = @@service_status_handle
                Log.debug { "runner: setting status to SERVICE_RUNNING" }
                set_win32_service_status handle, User32::SERVICE_STATUS_CURRENT_STATE::SERVICE_RUNNING
              end

              if service_block = @@service_block
                Log.debug { "runner: calling `service_block(#{args})`" }
                service_block.call args
              end
            ensure
              set_started false
              if handle = @@service_status_handle
                Log.debug { "runner: setting status to SERVICE_STOPPED" }
                set_win32_service_status handle, User32::SERVICE_STATUS_CURRENT_STATE::SERVICE_STOPPED
              end
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

        @@service_dispatcher = Fiber::ExecutionContext::Isolated.new("DISPATCHER") do
          console_allocated = false
          begin
            console_allocated = User32.AllocConsole != 0
            services = uninitialized User32::SERVICE_TABLE_ENTRYA[2]
            services[0] = User32::SERVICE_TABLE_ENTRYA.new(lp_service_name: @@service_name, lp_service_proc: @@service_main_outer.not_nil!)
            services[1] = User32::SERVICE_TABLE_ENTRYA.new(lp_service_name: nil, lp_service_proc: nil)

            Log.debug { "dispatcher: calling `User32.StartServiceCtrlDispatcherA(#{services})`" }
            result = User32.StartServiceCtrlDispatcherA(services.to_unsafe)

            if result == 0
              @@service_connected = false
              if WinError.value == WinError::ERROR_FAILED_SERVICE_CONTROLLER_CONNECT
                # the application process was not started via the
                # Windows service controller, so we will run the
                # service main inner callback directly so the
                # application can still be run directly from the
                # console when required
                Log.debug { "dispatcher: ERROR_FAILED_SERVICE_CONTROLLER_CONNECT" }
                if inner = @@service_main_inner
                  inner.call Array(String).new(0)
                end
              else
                raise "#{WinError.value}"
              end
            end
          ensure
            User32.FreeConsole if console_allocated
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
      if started?
        set_started false
        if service_stop_block = @@service_stop_block
          service_stop_block.call
        end
        await if blocking
      end
    end

    # Waits for the service to finish running
    def self.await : Nil
      unless stopped?
        if dispatcher = @@service_dispatcher
          dispatcher.wait
        end
        if runner = @@service_runner
          runner.wait
        end
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
      unless @@service_started == started
        if handle = @@service_status_handle
          status = started ? User32::SERVICE_STATUS_CURRENT_STATE::SERVICE_START_PENDING : User32::SERVICE_STATUS_CURRENT_STATE::SERVICE_STOP_PENDING
          set_win32_service_status handle, status
        end
        @@service_started = started
      end
    end

    # Sets the given *status* on the service associated with the given *handle*
    private def self.set_win32_service_status(handle : User32::SERVICE_STATUS_HANDLE, status : User32::SERVICE_STATUS_CURRENT_STATE) : Nil
      if connected?
        service_status = User32::SERVICE_STATUS.new
        service_status.dw_service_type = User32::ENUM_SERVICE_TYPE::SERVICE_WIN32_OWN_PROCESS
        service_status.dw_current_state = status
        service_status.dw_win32_exit_code = WinError::ERROR_SUCCESS
        service_status.dw_service_specific_exit_code = 0
        service_status.dw_check_point = 0
        service_status.dw_wait_hint = 1000

        if service_status.dw_current_state == User32::SERVICE_STATUS_CURRENT_STATE::SERVICE_START_PENDING
          service_status.dw_controls_accepted = 0
        else
          service_status.dw_controls_accepted = User32::SERVICE_ACCEPT_SHUTDOWN | User32::SERVICE_ACCEPT_STOP
        end

        Log.debug { "set_win32_service_status calling `User32.SetServiceStatus(#{handle}, #{service_status}`" }
        unless User32.SetServiceStatus(handle, pointerof(service_status))
          raise "Error setting service status"
        end
      end
    end
  end
end

@[Link("user32")]
lib User32
  alias PSTR = UInt8*
  alias SERVICE_STATUS_HANDLE = LibC::IntPtrT
  alias LPSERVICE_MAIN_FUNCTIONW = Proc(UInt32, LibC::LPWSTR*, Void)
  alias LPSERVICE_MAIN_FUNCTIONA = Proc(UInt32, PSTR*, Void)
  alias LPHANDLER_FUNCTION = Proc(UInt32, Void)
  alias LPHANDLER_FUNCTION_EX = Proc(UInt32, UInt32, Void*, Void*, UInt32)

  SERVICE_NO_CHANGE                     = 4294967295_u32
  SERVICE_CONTROL_STOP                  =          1_u32
  SERVICE_CONTROL_PAUSE                 =          2_u32
  SERVICE_CONTROL_CONTINUE              =          3_u32
  SERVICE_CONTROL_INTERROGATE           =          4_u32
  SERVICE_CONTROL_SHUTDOWN              =          5_u32
  SERVICE_CONTROL_PARAMCHANGE           =          6_u32
  SERVICE_CONTROL_NETBINDADD            =          7_u32
  SERVICE_CONTROL_NETBINDREMOVE         =          8_u32
  SERVICE_CONTROL_NETBINDENABLE         =          9_u32
  SERVICE_CONTROL_NETBINDDISABLE        =         10_u32
  SERVICE_CONTROL_DEVICEEVENT           =         11_u32
  SERVICE_CONTROL_HARDWAREPROFILECHANGE =         12_u32
  SERVICE_CONTROL_POWEREVENT            =         13_u32
  SERVICE_CONTROL_SESSIONCHANGE         =         14_u32
  SERVICE_CONTROL_PRESHUTDOWN           =         15_u32
  SERVICE_CONTROL_TIMECHANGE            =         16_u32
  SERVICE_CONTROL_TRIGGEREVENT          =         32_u32
  SERVICE_CONTROL_LOWRESOURCES          =         96_u32
  SERVICE_CONTROL_SYSTEMLOWRESOURCES    =         97_u32
  SERVICE_ACCEPT_STOP                   =          1_u32
  SERVICE_ACCEPT_PAUSE_CONTINUE         =          2_u32
  SERVICE_ACCEPT_SHUTDOWN               =          4_u32
  SERVICE_ACCEPT_PARAMCHANGE            =          8_u32
  SERVICE_ACCEPT_NETBINDCHANGE          =         16_u32
  SERVICE_ACCEPT_HARDWAREPROFILECHANGE  =         32_u32
  SERVICE_ACCEPT_POWEREVENT             =         64_u32
  SERVICE_ACCEPT_SESSIONCHANGE          =        128_u32
  SERVICE_ACCEPT_PRESHUTDOWN            =        256_u32
  SERVICE_ACCEPT_TIMECHANGE             =        512_u32
  SERVICE_ACCEPT_TRIGGEREVENT           =       1024_u32
  SERVICE_ACCEPT_USER_LOGOFF            =       2048_u32
  SERVICE_ACCEPT_LOWRESOURCES           =       8192_u32
  SERVICE_ACCEPT_SYSTEMLOWRESOURCES     =      16384_u32

  enum ENUM_SERVICE_TYPE : UInt32
    SERVICE_DRIVER              = 11
    SERVICE_FILE_SYSTEM_DRIVER_ =  2
    SERVICE_KERNEL_DRIVER       =  1
    SERVICE_WIN32               = 48
    SERVICE_WIN32_OWN_PROCESS_  = 16
    SERVICE_WIN32_SHARE_PROCESS = 32
    SERVICE_ADAPTER             =  4
    SERVICE_FILE_SYSTEM_DRIVER  =  2
    SERVICE_RECOGNIZER_DRIVER   =  8
    SERVICE_WIN32_OWN_PROCESS   = 16
    SERVICE_USER_OWN_PROCESS    = 80
    SERVICE_USER_SHARE_PROCESS  = 96
  end

  enum SERVICE_STATUS_CURRENT_STATE : UInt32
    SERVICE_CONTINUE_PENDING = 5
    SERVICE_PAUSE_PENDING    = 6
    SERVICE_PAUSED           = 7
    SERVICE_RUNNING          = 4
    SERVICE_START_PENDING    = 2
    SERVICE_STOP_PENDING     = 3
    SERVICE_STOPPED          = 1
  end

  struct SERVICE_TABLE_ENTRYA
    lp_service_name : PSTR
    lp_service_proc : LPSERVICE_MAIN_FUNCTIONA
  end

  struct SERVICE_TABLE_ENTRYW
    lp_service_name : LibC::LPWSTR
    lp_service_proc : LPSERVICE_MAIN_FUNCTIONW
  end

  struct SERVICE_STATUS
    dw_service_type : ENUM_SERVICE_TYPE
    dw_current_state : SERVICE_STATUS_CURRENT_STATE
    dw_controls_accepted : UInt32
    dw_win32_exit_code : UInt32
    dw_service_specific_exit_code : UInt32
    dw_check_point : UInt32
    dw_wait_hint : UInt32
  end

  # Params #
  fun AllocConsole : LibC::BOOL
  # Params #
  fun FreeConsole : LibC::BOOL
  # Params # lpservicename : PSTR [In],lphandlerproc : LPHANDLER_FUNCTION [In]
  fun RegisterServiceCtrlHandlerA(lpservicename : PSTR, lphandlerproc : LPHANDLER_FUNCTION) : SERVICE_STATUS_HANDLE
  # Params # lpservicename : LibC::LPWSTR [In],lphandlerproc : LPHANDLER_FUNCTION [In]
  fun RegisterServiceCtrlHandlerW(lpservicename : LibC::LPWSTR, lphandlerproc : LPHANDLER_FUNCTION) : SERVICE_STATUS_HANDLE
  # Params # hservicestatus : SERVICE_STATUS_HANDLE [In],lpservicestatus : SERVICE_STATUS* [In]
  fun SetServiceStatus(hservicestatus : SERVICE_STATUS_HANDLE, lpservicestatus : SERVICE_STATUS*) : LibC::BOOL
  # Params # lpservicestarttable : SERVICE_TABLE_ENTRYA* [In]
  fun StartServiceCtrlDispatcherA(lpservicestarttable : SERVICE_TABLE_ENTRYA*) : LibC::BOOL
  # Params # lpservicestarttable : SERVICE_TABLE_ENTRYW* [In]
  fun StartServiceCtrlDispatcherW(lpservicestarttable : SERVICE_TABLE_ENTRYW*) : LibC::BOOL
end
