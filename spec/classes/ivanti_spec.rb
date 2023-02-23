# frozen_string_literal: true

require 'spec_helper'

describe 'ivanti' do
  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      it { is_expected.to compile }

      context 'Checking for package installation' do
        # Check for packages needed to be installed.
        packages = ['ivanti-software-distribution', 'ivanti-base-agent', 'ivanti-pds2', 'ivanti-schedule', 'ivanti-inventory', 'ivanti-vulnerability', 'ivanti-cba8']
        packages.each do |package|
          it { is_expected.to contain_package(package.to_s).with_ensure('installed') }
        end
      end

      context 'Check sudo file entry for landesk user' do

        it { is_expected.to contain_file('/etc/sudoers.d/10_landesk').with_content(%r{^landesk\s+ALL=\(ALL\)\s+NOPASSWD:\s+ALL$}) }

        # Ensure certificate file copied
        # Ensure landesk is in sudoers
        # landesk ALL=(ALL)  NOPASSWD: ALL
      end
    end
  end
end
