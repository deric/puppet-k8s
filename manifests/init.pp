class k8s(
  Enum['present', 'absent'] $ensure = 'present',
  Enum['container', 'package', 'tarball', 'loose', 'hyperkube', 'manual'] $packaging = 'tarball',
  String[1] $version = '1.18.16',
  String[1] $etcd_version = '3.4.15',

  String[1] $container_registry = 'gcr.io/google_containers',
  String[1] $container_image = 'hyperkube',
  Optional[String] $container_image_tag = undef,
  Enum['docker', 'crictl'] $container_manager = 'crictl',
  String[1] $crictl_package = 'cri-tools',

  Boolean $manage_etcd = true,
  Boolean $manage_image = false,
  Boolean $manage_package = true,
  Boolean $manage_container_manager = false,

  Boolean $purge_manifests = true,

  String[1] $native_url_template = 'http://storage.googleapis.com/kubernetes-release/release/v%{version}/bin/%{kernel}/%{arch}/%{binary}',
  String[1] $tarball_url_template = 'https://dl.k8s.io/v%{version}/kubernetes-%{component}-%{kernel}-%{arch}.tar.gz',
  String[1] $package_template = 'kubernetes-%{component}',
  String[1] $hyperkube_name = 'hyperkube',

  Stdlib::HTTPUrl $master = 'https://kubernetes',
  Optional[Array[Stdlib::HTTPUrl]] $etcd_servers = undef,
  Variant[Stdlib::IP::Address::V4::CIDR, Stdlib::IP::Address::V6::CIDR] $service_cluster_cidr = '10.1.0.0/24',
  Variant[Stdlib::IP::Address::V4::CIDR, Stdlib::IP::Address::V6::CIDR] $cluster_cidr = '10.0.0.0/16',
  Stdlib::IP::Address::Nosubnet $api_address = k8s::first_ip_in_cidr($service_cluster_cidr),

  Enum['node','server','none'] $role = 'none',
) {
  if $manage_container_manager {
    if $container_manager == 'docker' {
      $pkg = 'docker'
    } else {
      $pkg = $crictl_package
    }

    package { 'k8s container manager':
      ensure  => installed,
      package => $pkg,
    }
  }

  group { 'kube':
    ensure => present,
    system => true,
  }
  user { 'kube':
    ensure     => present,
    comment    => 'Kubernetes user',
    gid        => 'kube',
    home       => '/opt/k8s',
    managehome => false,
    shell      => '/sbin/nologin',
    system     => true,
  }

  file {
    default:
      ensure  => directory,
      force   => true,
      purge   => true,
      recurse => true;

    '/opt/k8s': ;
    '/opt/k8s/bin': ;
  }
  file { '/var/run/kubernetes':
    ensure => directory,
    owner  => 'kube',
    group  => 'kube',
  }

  file { '/etc/sysconfig/kube-common':
    ensure  => file,
    content => epp('k8s/sysconfig.epp', {
        comment               => 'General Kubernetes Configuration',
        environment_variables => {
          'KUBE_LOGTOSTDERR' => '--alsologtostderr',
          'KUBE_LOG_LEVEL'   => '',
        },
    }),
  }

  file {
    default:
      ensure => directory;

    '/etc/cni': ;
    '/etc/cni/net.d': ;
    '/etc/kubernetes':
      purge   => true,
      recurse => true;
    '/etc/kubernetes/manifests':
      purge   => $purge_manifests,
      recurse => true;
    '/srv/kubernetes': ;
    '/srv/kubernetes/certs':
      purge   => true,
      recurse => true;
    '/var/lib/kubernetes': ;
  }

  if $role == 'server' {
    include ::k8s::server
  } elsif $role == 'node' {
    include ::k8s::node
  }
}
