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

      boolean = false
      context "Check configuration files for Privilege escallation #{boolean}." do
        let(:params) do
          { 'core_fqdn' => 'epmcore.example.com',
            'privilegeescalationallowed' => false,
            'core_certificate' => '187227ec.0', }
        end

        config_files = ['agent_settings', 'broker_config', 'inventory', 'policy', 'schedule', 'software_distribution', 'vulnerability', 'hardware']
        config_files.each do |config_file|
          it {
            is_expected.to contain_file("/opt/landesk/etc/#{config_file}.conf")
              .with_ensure('file')
              .with_owner('landesk')
              .with_group('landesk')
              .with_mode('0640')
              .with_content(%r{^\s*"privilegeEscalationAllowed" : false*})
          }
        end
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

      # 34         it { is_expected.to contain_class('chrony::install').that_comes_before('Class[chrony::config]') }
      # 35         it { is_expected.to contain_class('chrony::config').that_notifies('Class[chrony::service]') }

      #
      #        # TODO: redo this  it { is_expected.to contain_file('/etc/sudoers.d/10_landesk').with_content(%r{^landesk\s+ALL=\(ALL\)\s+NOPASSWD:\s+ALL$}) }
      #
      #        # Ensure landesk is in sudoers
      #        # landesk ALL=(ALL)  NOPASSWD: ALL
      #        # Defaults:landesk !requiretty
      #        #
    end
  end
end
