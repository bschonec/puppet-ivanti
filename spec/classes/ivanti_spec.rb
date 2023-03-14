# frozen_string_literal: true

require 'spec_helper'

describe 'ivanti' do
  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      let(:params) do
        { 'core_fqdn' => 'epmcore.example.com',
          'core_certificate' => '187227ec.0', }
      end

      context 'Checking for package installation' do
        it { is_expected.to compile.with_all_deps }

        # Check for packages needed to be installed.
        packages = ['ivanti-software-distribution', 'ivanti-base-agent', 'ivanti-pds2', 'ivanti-schedule', 'ivanti-inventory', 'ivanti-vulnerability', 'ivanti-cba8']
        packages.each do |package|
          it {
            is_expected.to contain_package(package.to_s)
              .with_ensure('installed')
          }
        end
      end

      context 'Checking that core certificate is installed' do
        it {
          is_expected.to contain_file('/opt/landesk/var/cbaroot/certs/187227ec.0')
            .with_owner('landesk')
            .with_group('landesk')
            .with_mode('0644')
            .that_requires('Package[ivanti-software-distribution]')
            .that_requires('Package[ivanti-base-agent]')
            .that_requires('Package[ivanti-pds2]')
            .that_requires('Package[ivanti-schedule]')
            .that_requires('Package[ivanti-inventory]')
            .that_requires('Package[ivanti-inventory]')
            .that_requires('Package[ivanti-vulnerability]')
            .that_requires('Package[ivanti-cba8]')
        }
      end

      config_files = ['agent_settings', 'broker_config', 'inventory', 'policy', 'schedule', 'software_distribution', 'vulnerability', 'hardware']
      [true, false].each do |privilege|
        context "Check configuration files for Privilege escallation #{privilege}." do
          let(:params) do
            super().merge({ 'privilegeescalationallowed' => privilege })
          end

          config_files.each do |config_file|
            it {
              is_expected.to contain_file("/opt/landesk/etc/#{config_file}.conf")
                .with_ensure('file')
                .with_owner('landesk')
                .with_group('landesk')
                .with_mode('0640')
                .with_content(%r{^\s*"privilegeEscalationAllowed" : #{privilege}*})
                .that_notifies('Service[cba8]')
            }
          end
        end
      end

      context 'Check landesk.conf file for owner/group/mode, Core and Device ID.' do
        let(:params) do
          super().merge({ 'device_id' => '1d251b42-adf3-c329-b2d6-8fcf146128d4' })
        end

        it {
          is_expected.to contain_file('/opt/landesk/etc/landesk.conf')
            .with_ensure('file')
            .with_owner('landesk')
            .with_group('landesk')
            .with_mode('0644')
            .with_content(%r{^Core=epmcore\.example\.com.*$})
            .with_content(%r{^Device ID=\{1d251b42-adf3-c329-b2d6-8fcf146128d4\}$})
            .that_notifies('Service[cba8]')
        }
      end

      context 'Check permissions of directories that get created by Landesk agents' do
        extra_dirs = ['/var/cbaroot/broker', '/var/cbaroot/certs', '/var/tmp', '/scan_repository']
        extra_dirs.each do |extra_dir|
          it {
            is_expected.to contain_file("/opt/landesk#{extra_dir}")
              .with_ensure('directory')
              .with_owner('landesk')
              .with_group('landesk')
              .with_recurse('true')
          }
        end

        it {
          is_expected.to contain_file('/opt/landesk/cache')
            .with_ensure('directory')
            .with_owner('landesk')
            .with_group('landesk')
        }
      end

      execs = ['agent_settings', 'broker_config', 'ldiscan', 'vulscan', 'map-fetchpolicy']
      context 'Check Exec resources' do
        execs.each do |exec|
          it {
              is_expected.to contain_exec(exec)
              #.with_command("/etc/landesk/bin/#{exec} -V")
              .with_user('root')
              .with_refreshonly('true')
          }
        end
      end
    end
  end
end
