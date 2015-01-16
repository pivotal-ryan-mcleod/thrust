require 'spec_helper'

describe Thrust::IOS::XCodeTools do
  let(:thrust_executor) { Thrust::FakeExecutor.new }
  let(:out) { StringIO.new }
  let(:build_configuration) { 'Release' }
  let(:project_name) { 'AwesomeProject' }
  let(:build_sdk) { 'iphoneos' }
  let(:target) { 'AppTarget' }
  let(:git) { double(Thrust::Git, checkout_file: 'checkout_file') }
  let(:build_directory) do
    FileUtils.mkdir_p('build').first.tap do |build_dir|
      FileUtils.mkdir_p(File.join(build_dir, "Release-iphoneos"))
    end
  end

  before do
    Thrust::Git.stub(:new).and_return(git)
    FileUtils.stub(:cmp).and_return(true)
  end

  describe '.initialize' do
    it 'requires either a project_name or workspace_name' do
      expect { Thrust::IOS::XCodeTools.new(thrust_executor, out, build_configuration, build_directory) }.to raise_error
    end

    it 'does not allow both a project_name and workspace_name' do
      expect { Thrust::IOS::XCodeTools.new(thrust_executor, out, build_configuration, build_directory, workspace_name: 'workspace', project_name: 'project') }.to raise_error
    end
  end

  describe '#clean_build' do
    subject { Thrust::IOS::XCodeTools.new(thrust_executor, out, build_configuration, build_directory, project_name: project_name) }

    it 'deletes the build folder' do
      subject.clean_build
      expect(File.directory?('build')).to be_false
    end
  end

  describe '#test' do
    subject { Thrust::IOS::XCodeTools.new(thrust_executor, out, build_configuration, build_directory, project_name: project_name) }

    it 'delegates to thrust executor' do
      command_result = double()

      thrust_executor.stub(:check_command_for_failure).and_return(command_result)

      subject.test('scheme', 'build_configuration', 'os_version', 'device_name', '33', 'build_dir').should == command_result
      expect(thrust_executor).to have_received(:check_command_for_failure).with("xcodebuild test -scheme 'scheme' -configuration 'build_configuration' -destination 'OS=os_version,name=device_name' -destination-timeout '33' SYMROOT='build_dir'")
    end

    it 'defaults destination-timeout to 30' do
      thrust_executor.stub(:check_command_for_failure)

      subject.test('scheme', 'build_configuration', 'os_version', 'device_name', nil, 'build_dir')
      expect(thrust_executor).to have_received(:check_command_for_failure).with(/-destination-timeout '30'/)
    end
  end

  context 'for an .xcodeproj based project' do
    subject { Thrust::IOS::XCodeTools.new(thrust_executor, out, build_configuration, build_directory, project_name: project_name) }

    describe '#build_scheme_or_target' do
      context 'when the build succeeds' do
        before do
          subject.build_scheme_or_target(target, build_sdk)
        end

        context 'when the build_sdk is not macosx' do
          it 'calls xcodebuild with the build command' do
            expect(thrust_executor.system_or_exit_history.last).to eq({
              cmd: 'set -o pipefail && xcodebuild -project AwesomeProject.xcodeproj -target "AppTarget" -configuration Release -sdk iphoneos clean build SYMROOT="build" CONFIGURATION_BUILD_DIR="build/Release-iphoneos" 2>&1 | grep -v \'backing file\'',
              output_file: 'build/Release-build.output'
            })
          end
        end

        context 'when the build_sdk is macosx' do
          let(:build_sdk) { 'macosx' }

          it 'does not include CONFIGURATION_BUILD_DIR' do
            expect(thrust_executor.system_or_exit_history.last).to eq({
              cmd: 'set -o pipefail && xcodebuild -project AwesomeProject.xcodeproj -target "AppTarget" -configuration Release -sdk macosx clean build SYMROOT="build" 2>&1 | grep -v \'backing file\'',
              output_file: 'build/Release-build.output'
            })
          end
        end
      end

      context 'when the build fails' do
        before do
          thrust_executor.on_next_system_or_exit do |cmd, output_file|
            File.open(output_file, 'w') {|f| f.write('build facepalm') }
            raise(Thrust::Executor::CommandFailed, 'build no worky')
          end
        end

        it 'prints the build log' do
          expect {
            subject.build_scheme_or_target(target, build_sdk)
          }.to raise_error Thrust::Executor::CommandFailed
          expect(out.string).to include('build facepalm')
        end
      end
    end
  end

  context 'for an .xcworkspace based project' do
    let (:workspace_name) { 'AwesomeWorkspace' }
    subject { Thrust::IOS::XCodeTools.new(thrust_executor, out, build_configuration, build_directory, workspace_name: workspace_name) }

    describe '#build_scheme_or_target' do
      it 'calls xcodebuild with the build command' do
        subject.build_scheme_or_target(target, build_sdk)

        expect(thrust_executor.system_or_exit_history.last).to eq({
                                                                    cmd: 'set -o pipefail && xcodebuild -workspace AwesomeWorkspace.xcworkspace -scheme "AppTarget" -configuration Release -sdk iphoneos clean build SYMROOT="build" CONFIGURATION_BUILD_DIR="build/Release-iphoneos" 2>&1 | grep -v \'backing file\'',
                                                                    output_file: 'build/Release-build.output'
                                                                  })
      end
    end
  end

  describe '#cleanly_create_ipa' do
    let(:app_name) { 'AppName' }
    let(:signing_identity) { 'iPhone Distribution' }
    let(:provision_search_query) { 'query' }
    let(:provisioning_path) { 'provisioning-path' }
    subject { Thrust::IOS::XCodeTools.new(thrust_executor, out, build_configuration, build_directory, project_name: project_name) }

    before do
      subject.stub(:`).and_return(provisioning_path)
    end

    def create_ipa
      subject.cleanly_create_ipa(target, app_name, signing_identity, provision_search_query)
    end

    it 'cleans the build' do
      subject.should_receive(:clean_build).and_call_original
      create_ipa
    end

    it 'kills the simulator' do
      create_ipa

      expect(thrust_executor.system_history).to eq([
        {cmd: 'killall -m -KILL "gdb"', output_file: nil},
        {cmd: 'killall -m -KILL "otest"', output_file: nil},
        {cmd: 'killall -m -KILL "iPhone Simulator"', output_file: nil}
      ])
    end

    it 'builds the app' do
      subject.should_receive(:build_scheme_or_target).with(target, build_sdk)
      create_ipa
    end

    it 'creates the ipa and then resigns it' do
      create_ipa

      expect(thrust_executor.system_or_exit_history[1]).to eq({cmd: "xcrun -sdk iphoneos -v PackageApplication 'build/Release-iphoneos/AppName.app' -o 'build/Release-iphoneos/AppName.ipa' --embed 'provisioning-path'", output_file: nil})
      expect(thrust_executor.system_or_exit_history[2]).to eq({cmd: "cd 'build/Release-iphoneos' && unzip 'AppName.ipa'", output_file: nil})
      expect(thrust_executor.system_or_exit_history[3]).to eq({cmd: "/usr/bin/codesign --verify --force --preserve-metadata=identifier,entitlements --sign 'iPhone Distribution' 'build/Release-iphoneos/Payload/AppName.app'", output_file: nil})
      expect(thrust_executor.system_or_exit_history[4]).to eq({cmd: "cd 'build/Release-iphoneos' && zip -qr 'AppName.ipa' 'Payload'", output_file: nil})
    end

    it 'returns the name of the ipa' do
      ipa_name = create_ipa

      expect(ipa_name).to eq('build/Release-iphoneos/AppName.ipa')
    end

    context 'when it can not find the provisioning profile' do
      let(:provisioning_path) { 'nonexistent-file' }

      it 'raises an error' do
        subject.cleanly_create_ipa(target, app_name, signing_identity, provisioning_path)
      end
    end

    context 'when xcrun embeds the wrong provisioning profile' do
      it 'raises an error' do
        expect do
        FileUtils.stub(:cmp).and_return(false)
        create_ipa
        end.to raise_error(Thrust::IOS::XCodeTools::ProvisioningProfileNotEmbedded)
      end
    end
  end
end
