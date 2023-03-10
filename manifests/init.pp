# @summary
#   A Puppet module to install and configure Ivanti agent for Linux.
#
# When this class is declared with the default options, Puppet:
# - Installs the appropriate Ivanti software packages for Linux.
# - Places the required configuration files in a directory, with the [default location](#conf_dir) determined by your operating system.
# - Downloads SSL certificates from (#
# - Configures the server with a default virtual host and standard port (`80`) and address (`\*`) bindings.
# - Creates a document root directory determined by your operating system, typically `/var/www`.
# - Starts the Apache service.
#
# @example
#   class { 'ivanti': }
#
# @param core_certificate
# This is the name of the certificate file that will be downloaded from the EM Core server.
#
# @param core_fqdn
# This fully qualified domain name of the core server from which the @core_certificate 
# will be downloaded and to which the Ivanti agent will register itself.
#
# @param device_id
# A unique device ID (typically, the UUID of the server) used to register to the Core server.
#
# @param external_url
# This is the full URI to the core certificate that will be downloaded and installed
# to the agent.
#
# @param linux_baseclients
# for future use:
# This is the path to the tar bundle that contains the base clinet RPMs.
# Typically, this isn't needed since this module will install the RPM packages
# via a yum/dnf repository.
#
# @param packages
# An array of packages to be installed on the agent.
#
# @param cba
# Install the Ivanti base agent package.
#
# @param sd
# Install the Ivanti software distribution package.
#
# @param vd
# Install the Ivanti vulnerability package.
#
# @param manage_firewall
# Manage the local firewall yes/no.
#
# @param firewall_ports
# An array of firewall ports to be opened to allow communication to the Ivanti agent.
#
# @param privilegeescalationallowed
# Allow sudo privilege excallation for the landesk user.  ${install_dir}/etc/*.conf
# files will be updated.
#
# @param config_files
# A hash of config files to be managed along with (optional) permissions, owner, etc.
#
# @param install_dir
# The directory in which the Ivanti agent will be installed.
#
# @param extra_dirs
# An array of directories -- relative to the ${install_dir} path that the ivanti-cba8
# package creates in the postinstall scriptlet of the RPM package.  These directories
# are root owned and this screws stuff up unless they get changed back to landesk:landesk.
#
class ivanti (
  String $core_certificate,
  Stdlib::Fqdn $core_fqdn,
  String $device_id                       = $facts['dmi']['product']['uuid'].downcase(),
  Stdlib::Httpurl   $external_url         = "http://${core_fqdn}/ldlogon/${core_certificate}",
  Stdlib::Httpurl $linux_baseclients      = "http://${core_fqdn}/ldlogon/unix/linux/baseclient64.tar.gz",  # Linux base client location for non-yum install
  Variant[Array, String] $packages        = $ivanti::packages,
  Boolean $cba                            = true, # Install tandard LANDesk Agents
  Boolean $sd                             = true, # Install Software Distribution
  Boolean $vd                             = true, # Install Vulnerability Scanner
  Boolean $manage_firewall                = false,
  Variant[Array, Integer] $firewall_ports = [9593, 9594, 9595],
  Boolean $privilegeescalationallowed     = true,
  Hash $config_files                      = $ivanti::config_files,
  Stdlib::Unixpath $install_dir           = '/opt/landesk',
  Array[Stdlib::Unixpath] $extra_dirs     = $ivanti::extra_dirs,
) {
  # Install the Ivanti packages
  package { $packages:
    ensure => installed,
  }

#  # Configure sudoers for landesk user AND allow tty-less sudo.
#  file { '/etc/sudoers.d/10_landesk':
#    content => "Defaults:landesk !requiretty \nlandesk ALL=(ALL) NOPASSWD: ALL",
#    owner   => root,
#    group   => root,
#    mode    => '0600',
#  }

  # Install the SSL certificate from the core server.
  file { "${install_dir}/var/cbaroot/certs/${core_certificate}":
    owner   => 'landesk',
    group   => 'landesk',
    mode    => '0644',
    source  => $external_url,
    require => Package[$packages],
  }

  # These directories get created by the ivanti-cba8 RPM as the root user and need to be changed
  # back to landesk:landesk for some of the daemons to work properly.
  $extra_dirs.each | $extra_dir | {
    file {"${install_dir}/${extra_dir}":
      owner => landesk,
      group => landesk,
  }

  # 0644 is not the default mode for the conf files; 0640 is the default mode.  Unfortunately, the
  # cba8 daemon doesn't run properly unless ./etc/landesk.conf has the other read bit set (o+r) so
  # we have to accommodate that fact by merging in default settings into the $config_files (below).
  # The following files have ./bin and ./etc
  $config_file_defaults = {
    owner   => 'landesk',
    group   => 'landesk',
    mode    => '0640',
    before  => Service['cba8'], # Ensure these files are managed before starting/restarting
    notify  => Service['cba8'],
  }

  # Manage files in /opt/landesk/etc/.  Changes to any conf file will trigger the cba8 service restart
  # and a cascade of exec resources.
  $config_files.each | $config_file, $config_file_attributes | {
    # Merge any settings from the hiera hash to create a default set of parameters.
    $attributes = deep_merge($config_file_defaults, $config_file_attributes)
    file { "${config_file}.conf":
      *       => $attributes,
      path    => "${install_dir}/etc/${config_file}.conf",
      content => template("ivanti/${config_file}.conf.erb"),
    }
  }

  service { 'cba8':
    ensure  => 'running',
    enable  => true,
    require => Package[$packages],
    notify  => Exec['broker_config'],
  }

  # TODO firewall rules OR a firewall XML file.

  # Execute the commands to register and then scan the agent.
  # The schedule exec is removed in the short term because the binary fails to return a zero return code.
  # $execs = ['agent_settings', 'broker_config', 'inventory', 'ldiscan', 'policy', 'schedule', 'software_distribution',]
  # Since all of the execs are run in order, we only need to require Service[cba8] on the first exec in the list (agent_settings).
  exec { 'agent_settings':
    command     => "${install_dir}/bin/agent_settings -V",
    user        => 'root',
    logoutput   => true,
    refreshonly => true,
    require     => Service['cba8'],
    notify      => Exec['broker_config'],
  }
  exec { 'broker_config':
    command     => "${install_dir}/bin/broker_config -V",
    user        => 'root',
    logoutput   => true,
    refreshonly => true,
    notify      => Exec['ldiscan'],
  }
  exec { 'ldiscan':
    command     => "${install_dir}/bin/ldiscan -V",
    user        => 'root',
    logoutput   => true,
    refreshonly => true,
    notify      => Exec['vulscan'],
  }
  exec { 'vulscan':
    command     => "${install_dir}/bin/vulscan -V",
    user        => 'root',
    logoutput   => true,
    refreshonly => true,
    notify      => Exec['map-fetchpolicy'],
  }
  exec { 'map-fetchpolicy':
    command     => "${install_dir}/bin/map-fetchpolicy -V",
    user        => 'root',
    logoutput   => true,
    refreshonly => true,
  }

  # Ordering of a few execs is important
  # The ordering here was taken from the .sdtout.log file that is created when installing Ivanti
  # from the bash script.  I'm not sure if the ordering really matters but it makes sense that the broker_config
  # needs to run before ldiscan.  All other ordering is semi-arbitrary (ie, I made a best guess).
  Exec['agent_settings'] ~> Exec['broker_config'] ~> Exec['ldiscan'] ~> Exec['vulscan'] ~> Exec['map-fetchpolicy']
}
