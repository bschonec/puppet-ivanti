# @summary A short summary of the purpose of this class
#
# A description of what this class does

# @packages
# The packages required to install Ivanti
#
# @example
#   include ivanti
class ivanti (
  Optional[Variant[Array, String]] $packages     = ['ivanti-software-distribution',
                                                    'ivanti-base-agent',
                                                    'ivanti-pds2',
                                                    'ivanti-schedule',
                                                    'ivanti-inventory',
                                                    'ivanti-vulnerability',
                                                    'ivanti-cba8', ],
){

  # Install the Ivanti packages
  package { $packages:
    ensure => installed,
  }

  file{'/etc/sudoers.d/10_landesk':
    content => 'landesk ALL=(ALL) NOPASSWD: ALL',
    owner   => root,
    group   => root,
    mode    => '0600',

  }

  # create sudoers entry
  #sudo::conf {'testlandesk':
  #  priority => 10,
  #  content => 'landesk ALL=(ALL) NOPASSWD: ALL',
  #}

}
