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
          it { is_expected.to contain_package(package.to_s).with_ensure('installed') }
        end

        context 'Checking that core certificate is installed' do
          it {
            is_expected.to contain_file('/opt/landesk/var/cbaroot/certs/187227ec.0').with(
              'owner' => 'landesk',
              'group' => 'landesk',
              'mode' => '0644',
            )
          }
        end

        context 'Check configuration files for Privilege escallation true' do
          #  config_files = ['agent_settings', 'broker_config', 'inventory', 'policy', 'schedule', 'software_distribution', 'vulnerability', 'hardware']
          #  config_files.each do |config_file|
          it {
            is_expected.to contain_file('/opt/landesk/etc/policy.conf').with(
                'ensure' => 'file',
                #                  'owner' => 'landesk',
                #    'group' => 'landesk',
                #    'mode' => '0640',
              )
            #       #      # is_expected.to contain_file("/opt/landesk/etc/#{config_file}").with(
            #      #   .with_content(%rprivilegeEscalationAllowed)
            # )
          }
          #  end
        end

        context 'Check permissions of directories that get created by Landesk agents' do
          extra_dirs = ['/var/cbaroot/broker', '/var/cbaroot/certs', '/var/tmp', '/scan_repository']
          extra_dirs.each do |extra_dir|
            it {
              is_expected.to contain_file("/opt/landesk#{extra_dir}").with(
                'ensure' => 'directory',
                # 'owner' => 'landesk',
                # 'group' => 'landesk',
                # 'recurse' => 'true',
              )
            }
          end

          it {
            is_expected.to contain_file('/opt/landesk/cache').with(
               'ensure' => 'directory',
              'owner' => 'landesk',
              'group' => 'landesk',
             )
          }
        end
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
end
