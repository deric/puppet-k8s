class k8s::node(
  Enum['present', 'absent'] $ensure = $k8s::ensure,

  Stdlib::HTTPUrl $master = $k8s::master,
  Enum['cert', 'token', 'bootstrap'] $node_auth = $k8s::node_auth,
  Enum['cert', 'token', 'incluster'] $proxy_auth = 'cert',

  # For cert auth
  Optional[Stdlib::Unixpath] $ca_cert = undef,
  Optional[Stdlib::Unixpath] $node_cert = undef,
  Optional[Stdlib::Unixpath] $node_key = undef,

  Optional[Stdlib::Unixpath] $proxy_cert = undef,
  Optional[Stdlib::Unixpath] $proxy_key = undef,

  # For token and bootstrap auth
  Optional[Stdlib::Unixpath] $node_token = undef,
  Optional[Stdlib::Unixpath] $proxy_token = undef,
) {
  include ::k8s::node::kubelet
  include ::k8s::node::kube_proxy
}
