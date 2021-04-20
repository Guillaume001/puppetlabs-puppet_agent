class puppet_agent::osfamily::suse{
  assert_private()

  if $::operatingsystem != 'SLES' {
    fail("${::operatingsystem} not supported")
  }

  if $::puppet_agent::absolute_source {
    # Absolute sources are expected to be actual packages (not repos)
    # so when absolute_source is set just download the package to the
    # system and finish with this class.
    $source = $::puppet_agent::absolute_source
    class { '::puppet_agent::prepare::package':
      source => $source,
    }
    contain puppet_agent::prepare::package
  } else {
    if ($::puppet_agent::is_pe and (!$::puppet_agent::use_alternate_sources)) {
      $pe_server_version = pe_build_version()

      # SLES 11 in PE can no longer install agents from pe_repo
      if $::operatingsystemmajrelease == '11' {
        if $::puppet_agent::source {
          $source = "${::puppet_agent::source}/packages/${pe_server_version}/${::platform_tag}"
        } elsif $::puppet_agent::alternate_pe_source {
          $source = "${::puppet_agent::alternate_pe_source}/packages/${pe_server_version}/${::platform_tag}"
        } else {
          $source = "puppet:///pe_packages/${pe_server_version}/${::platform_tag}/${::puppet_agent::package_name}-${::puppet_agent::prepare::package_version}-1.sles11.${::puppet_agent::arch}.rpm"
        }

        # Nuke the repo if it exists to ensure zypper doesn't remain broken
        file { '/etc/zypp/repos.d/pc_repo.repo':
          ensure => absent,
        }

        class { '::puppet_agent::prepare::package':
          source => $source,
        }
        contain puppet_agent::prepare::package
      } else {
        if $::puppet_agent::source {
          $source = "${::puppet_agent::source}/packages/${pe_server_version}/${::platform_tag}"
        } elsif $::puppet_agent::alternate_pe_source {
          $source = "${::puppet_agent::alternate_pe_source}/packages/${pe_server_version}/${::platform_tag}"
        } else {
          $source = "https://${::puppet_master_server}:8140/packages/${pe_server_version}/${::platform_tag}"
        }
      }
    } else {
      if $::puppet_agent::collection == 'PC1' {
        $source = "${::puppet_agent::yum_source}/sles/${::operatingsystemmajrelease}/${::puppet_agent::collection}/${::puppet_agent::arch}"
      } else {
        $source = "${::puppet_agent::yum_source}/${::puppet_agent::collection}/sles/${::operatingsystemmajrelease}/${::puppet_agent::arch}"
      }
    }

    case $::operatingsystemmajrelease {
      '11', '12', '15': {
        # Import the GPG key
        $legacy_keyname  = 'GPG-KEY-puppet'
        $legacy_gpg_path = "/etc/pki/rpm-gpg/RPM-${legacy_keyname}"
        $keyname         = 'GPG-KEY-puppet-20250406'
        $gpg_path        = "/etc/pki/rpm-gpg/RPM-${keyname}"
        $gpg_homedir     = '/root/.gnupg'

        if getvar('::puppet_agent::manage_pki_dir') == true {
          file { ['/etc/pki', '/etc/pki/rpm-gpg']:
            ensure => directory,
          }
        }

        file { $gpg_path:
          ensure => present,
          owner  => 0,
          group  => 0,
          mode   => '0644',
          source => "puppet:///modules/puppet_agent/${keyname}",
        }

        file { $legacy_gpg_path:
          ensure => present,
          owner  => 0,
          group  => 0,
          mode   => '0644',
          source => "puppet:///modules/puppet_agent/${legacy_keyname}",
        }

        file { "${::env_temp_variable}/rpm_gpg_import_check.sh":
          ensure => file,
          source => 'puppet:///modules/puppet_agent/rpm_gpg_import_check.sh',
          mode   => '0755',
        }
        -> exec { "import-${legacy_keyname}":
          path      => '/bin:/usr/bin:/sbin:/usr/sbin',
          command   => "${::env_temp_variable}/rpm_gpg_import_check.sh import ${gpg_homedir} ${legacy_gpg_path}",
          unless    => "${::env_temp_variable}/rpm_gpg_import_check.sh check ${gpg_homedir} ${legacy_gpg_path}",
          require   => File[$legacy_gpg_path],
          logoutput => 'on_failure',
        }
        -> exec { "import-${keyname}":
          path      => '/bin:/usr/bin:/sbin:/usr/sbin',
          command   => "${::env_temp_variable}/rpm_gpg_import_check.sh import ${gpg_homedir} ${gpg_path}",
          unless    => "${::env_temp_variable}/rpm_gpg_import_check.sh check ${gpg_homedir} ${gpg_path}",
          require   => File[$gpg_path],
          logoutput => 'on_failure',
        }

        unless $::operatingsystemmajrelease == '11' and $::puppet_agent::is_pe {
          if getvar('::puppet_agent::manage_repo') == true {
            # Set up a zypper repository by creating a .repo file which mimics a ini file
            $repo_file = '/etc/zypp/repos.d/pc_repo.repo'
            $repo_name = 'pc_repo'

            # 'auto' versus X.Y.Z
            $_package_version = getvar('puppet_agent::master_or_package_version')

            # In Puppet Enterprise, agent packages are served by the same server
            # as the master, which can be using either a self signed CA, or an external CA.
            # Zypper has issues with validating a self signed CA, so for now disable ssl verification.
            $repo_settings = {
              'name'        => $repo_name,
              'enabled'     => '1',
              'autorefresh' => '0',
              'baseurl'     => "${source}?ssl_verify=no",
              'type'        => 'rpm-md',
            }

            $repo_settings.each |String $setting, String $value| {
              ini_setting { "zypper ${repo_name} ${setting}":
                ensure  => present,
                path    => $repo_file,
                section => $repo_name,
                setting => $setting,
                value   => $value,
                before  => Exec["refresh-${repo_name}"],
              }
            }

            exec { "refresh-${repo_name}":
              path      => '/bin:/usr/bin:/sbin:/usr/sbin',
              unless    => "zypper search -r ${repo_name} -s | grep puppet-agent | awk '{print \$7}' | grep \"^${_package_version}\"",
              command   => "zypper refresh ${repo_name}",
              logoutput => 'on_failure',
            }
          }
        }
      }
      default: {
        fail("${::operatingsystem} ${::operatingsystemmajrelease} not supported")
      }
    }
  }
}
