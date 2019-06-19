require 'json'
require_relative "../../../base"

require Vagrant.source_root.join("plugins/providers/hyperv/driver")

describe VagrantPlugins::HyperV::Driver do
  def generate_result(obj)
    "===Begin-Output===\n" +
      JSON.dump(obj) +
      "\n===End-Output==="
  end

  def generate_error(msg)
    "===Begin-Error===\n#{JSON.dump(error: msg)}\n===End-Error===\n"
  end

  let(:result){
    Vagrant::Util::Subprocess::Result.new(
      result_exit, result_stdout, result_stderr) }
  let(:subject){ described_class.new(vm_id) }
  let(:vm_id){ 1 }
  let(:result_stdout){ "" }
  let(:result_stderr){ "" }
  let(:result_exit){ 0 }

  context "public methods" do
    before{ allow(subject).to receive(:execute_powershell).and_return(result) }

    describe "#execute" do
      it "should convert symbol into path string" do
        expect(subject).to receive(:execute_powershell).with(kind_of(String), any_args)
          .and_return(result)
        subject.execute(:thing)
      end

      it "should append extension when converting symbol" do
        expect(subject).to receive(:execute_powershell).with("thing.ps1", any_args)
          .and_return(result)
        subject.execute(:thing)
      end

      context "when command returns non-zero exit code" do
        let(:result_exit){ 1 }

        it "should raise an error" do
          expect{ subject.execute(:thing) }.to raise_error(VagrantPlugins::HyperV::Errors::PowerShellError)
        end
      end

      context "when command stdout matches error pattern" do
        let(:result_stdout){ generate_error("Error Message") }

        it "should raise an error" do
          expect{ subject.execute(:thing) }.to raise_error(VagrantPlugins::HyperV::Errors::PowerShellError)
        end
      end

      context "with valid JSON output" do
        let(:result_stdout){ generate_result(:custom => "value") }

        it "should return parsed JSON data" do
          expect(subject.execute(:thing)).to eq("custom" => "value")
        end
      end

      context "with invalid JSON output" do
        let(:result_stdout){ "value" }
        it "should return nil" do
          expect(subject.execute(:thing)).to be_nil
        end
      end
    end

    describe "#has_vmcx_support?" do
      context "when support is available" do
        let(:result_stdout){ generate_result(:result => true) }

        it "should be true" do
          expect(subject.has_vmcx_support?).to eq(true)
        end
      end

      context "when support is not available" do
        let(:result_stdout){ generate_result(:result => false) }

        it "should be false" do
          expect(subject.has_vmcx_support?).to eq(false)
        end
      end
    end

    describe "#set_vm_integration_services" do
      it "should map known integration services names automatically" do
        expect(subject).to receive(:execute) do |name, args|
          expect(args[:Name]).to eq("Shutdown")
        end
        subject.set_vm_integration_services(shutdown: true)
      end

      it "should set enable when value is true" do
        expect(subject).to receive(:execute) do |name, args|
          expect(args[:Enable]).to eq(true)
        end
        subject.set_vm_integration_services(shutdown: true)
      end

      it "should not set enable when value is false" do
        expect(subject).to receive(:execute) do |name, args|
          expect(args[:Enable]).to be_nil
        end
        subject.set_vm_integration_services(shutdown: false)
      end

      it "should pass unknown key names directly through" do
        expect(subject).to receive(:execute) do |name, args|
          expect(args[:Name]).to eq("CustomKey")
        end
        subject.set_vm_integration_services(CustomKey: true)
      end
    end

    describe "#sync_files" do
      let(:dirs) { %w[dir1 dir2] }
      let(:files) { %w[file1 file2] }
      let(:guest_ip) do
        {}.tap do |ip|
          ip["ip"] = "guest_ip"
        end
      end
      let(:windows_path) { "WIN_PATH" }
      let(:windows_temp) { "TEMP_DIR" }
      let(:wsl_temp) { "WSL_TEMP" }
      let(:file_list) { double("file") }

      before do
        allow(subject).to receive(:read_guest_ip).and_return(guest_ip)
        allow(Vagrant::Util::Platform).to receive(:windows_temp).and_return(windows_temp)
        allow(Vagrant::Util::Subprocess).to receive(:execute).
          with("wslpath", "-u", "-a", windows_temp).and_return(double(exit_code: 0, stdout: wsl_temp))
        allow(File).to receive(:open) do |fn, type, &proc|
          proc.call file_list

          allow(Vagrant::Util::Platform).to receive(:format_windows_path).
            with(fn, :disable_unc).and_return(windows_path)
          allow(FileUtils).to receive(:rm_f).with(fn)
        end.and_return(file_list)
        allow(file_list).to receive(:write).with(files.to_json)
        allow(subject).to receive(:execute).with(:sync_files,
                                                 vm_id: vm_id,
                                                 guest_ip: guest_ip["ip"],
                                                 file_list: windows_path)
      end

      after { subject.sync_files vm_id, dirs, files, is_win_guest: false }

      %i[Windows WSL].each do |host_type|
        context "in #{host_type} environment" do
          let(:is_wsl) { host_type == :WSL }
          let(:temp_dir) { is_wsl ? wsl_temp : windows_temp }

          before do
            allow(Vagrant::Util::Platform).to receive(:wsl?).and_return(is_wsl)
          end

          it "reads guest ip" do
            expect(subject).to receive(:read_guest_ip).and_return(guest_ip)
          end

          it "gets Windows temporary dir where dir list is written" do
            expect(Vagrant::Util::Platform).to receive(:windows_temp).and_return(windows_temp)
          end

          if host_type == :WSL
            it "converts Windows temporary dir to Unix style for WSL" do
              expect(Vagrant::Util::Subprocess).to receive(:execute).
                with("wslpath", "-u", "-a", windows_temp).and_return(double(exit_code: 0, stdout: wsl_temp))
            end
          end

          it "writes dir list to temporary file" do
            expect(File).to receive(:open) do |fn, type, &proc|
              expect(fn).to match(/#{temp_dir}\/\.hv_sync_files_.*/)
              expect(type).to eq('w')

              proc.call file_list

              expect(Vagrant::Util::Platform).to receive(:format_windows_path).
                with(fn, :disable_unc).and_return(windows_path)
              expect(FileUtils).to receive(:rm_f).with(fn)
            end.and_return(file_list)
            expect(file_list).to receive(:write).with(files.to_json)
          end

          it "calls sync files powershell script" do
            expect(subject).to receive(:execute).with(:sync_files,
                                                      vm_id: vm_id,
                                                      guest_ip: guest_ip["ip"],
                                                      file_list: windows_path)
          end
        end
      end
    end
  end

  describe "#execute_powershell" do
    before{ allow(Vagrant::Util::PowerShell).to receive(:execute) }

    it "should call the PowerShell module to execute" do
      expect(Vagrant::Util::PowerShell).to receive(:execute)
      subject.send(:execute_powershell, "path", {})
    end

    it "should modify the path separators" do
      expect(Vagrant::Util::PowerShell).to receive(:execute)
        .with("\\path\\to\\script.ps1", any_args)
      subject.send(:execute_powershell, "/path/to/script.ps1", {})
    end

    it "should include ErrorAction option as Stop" do
      expect(Vagrant::Util::PowerShell).to receive(:execute) do |path, *args|
        expect(args).to include("-ErrorAction")
        expect(args).to include("Stop")
      end
      subject.send(:execute_powershell, "path", {})
    end

    it "should automatically include module path" do
      expect(Vagrant::Util::PowerShell).to receive(:execute) do |path, *args|
        opts = args.detect{|i| i.is_a?(Hash)}
        expect(opts[:module_path]).not_to be_nil
      end
      subject.send(:execute_powershell, "path", {})
    end

    it "should covert hash options into arguments" do
      expect(Vagrant::Util::PowerShell).to receive(:execute) do |path, *args|
        expect(args).to include("-Custom")
        expect(args).to include("'Value'")
      end
      subject.send(:execute_powershell, "path", "Custom" => "Value")
    end

    it "should treat keys with `true` value as switches" do
      expect(Vagrant::Util::PowerShell).to receive(:execute) do |path, *args|
        expect(args).to include("-Custom")
        expect(args).not_to include("'true'")
      end
      subject.send(:execute_powershell, "path", "Custom" => true)
    end

    it "should not include keys with `false` value" do
      expect(Vagrant::Util::PowerShell).to receive(:execute) do |path, *args|
        expect(args).not_to include("-Custom")
      end
      subject.send(:execute_powershell, "path", "Custom" => false)
    end
  end
end
