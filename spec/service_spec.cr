require "./spec_helper"

describe Win32::Service do
  it "run without the Windows service controller" do
    did_run = false
    Win32::Service.run do
      did_run = true
    end
    sleep 1.second
    # Win32::Service.await #required crystal spec to be run with -Dpreview_mt flag to work correctly
    did_run.should eq(true)
  end
end
