class k8s::server::resources(
  Stdlib::Unixpath $kubeconfig = '/root/.kube/config',

  Variant[Stdlib::IP::Address::V4::CIDR, Stdlib::IP::Address::V6::CIDR] $cluster_cidr = $k8s::server::cluster_cidr,
  Stdlib::IP::Address::Nosubnet $dns_service_address = $k8s::server::dns_service_address,
  String[1] $cluster_domain = $k8s::server::cluster_domain,
  String[1] $direct_master = $k8s::server::direct_master,

  Boolean $manage_bootstrap = true,
  Boolean $manage_coredns = true,
  Boolean $manage_flannel = true,

  String[1] $coredns_image = 'k8s.gcr.io/coredns',
  String[1] $coredns_tag = '1.8.3',
  String[1] $flannel_image = 'quay.io/coreos/flannel',
  String[1] $flannel_tag = 'v0.13.0',
) {
  assert_private()

  if $manage_bootstrap {
    k8s::server::bootstrap_token { 'puppet':
      kubeconfig         => $kubeconfig,

      description        => 'Puppet generated token',
      use_authentication => true,

      addn_data          => {
        metadata => {
          labels => {
            'puppet.com/managed' => 'true',
          },
        },
      },
    }

    kubectl_apply{
      default:
        kubeconfig  => $kubeconfig,
        api_version => 'rbac.authorization.k8s.io/v1',
        kind        => 'ClusterRole';

      'system-bootstrap-node-bootstrapper':
        content => {
          subjects => [
            {
              kind     => 'Group',
              name     => 'system:bootstrappers',
              apiGroup => 'rbac.authorization.k8s.io',
            },
            {
              kind     => 'Group',
              name     => 'system:nodes',
              apiGroup => 'rbac.authorization.k8s.io',
            },
          ],
          roleRef  => {
            kind     => 'ClusterRole',
            name     => 'system:node-bootstrapper',
            apiGroup => 'rbac.authorization.k8s.io',
          }
        };

      'system-bootstrap-approve-node-client-csr':
        content => {
          subjects => [
            {
              kind     => 'Group',
              name     => 'system:bootstrappers',
              apiGroup => 'rbac.authorization.k8s.io',
            },
          ],
          roleRef  => {
            kind     => 'ClusterRole',
            name     => 'system:certificates.k8s.io:certificatesigningrequests:nodeclient',
            apiGroup => 'rbac.authorization.k8s.io',
          },
        };

      'system-bootstrap-node-renewal':
        content => {
          subjects => [
            {
              kind     => 'Group',
              name     => 'system:nodes',
              apiGroup => 'rbac.authorization.k8s.io',
            },
          ],
          roleRef  => {
            kind     => 'ClusterRole',
            name     => 'system:certificates.k8s.io:certificatesigningrequests:selfnodeclient',
            apiGroup => 'rbac.authorization.k8s.io',
          }
        };
    }
  }

  if $manage_coredns {
    kubectl_apply {
      default:
        resource_name => 'coredns',
        namespace     => 'kube-system',
        kubeconfig    => $kubeconfig;

      'coredns ServiceAccount':
        api_version => 'v1',
        kind        => 'ServiceAccount',
        content     => {};

      'coredns ClusterRole':
        api_version   => 'rbac.authorization.k8s.io/v1',
        kind          => 'ClusterRole',
        resource_name => 'system:coredns',
        content       => {
          metadata => {
            labels => {
              'kubernetes.io/bootstrapping' => 'rbac-defaults',
            },
          },
          rules    => [
            {
              apiGroups => [''],
              resources => ['endpoints','services','pods','namespaces'],
              verbs     => ['list','watch'],
            },
            {
              apiGroups => ['discovery.k8s.io'],
              resources => ['endpointslices'],
              verbs     => ['list','watch'],
            },
          ],
        };

      'coredns ClusterRoleBinding':
        api_version   => 'rbac.authorization.k8s.io/v1',
        kind          => 'ClusterRoleBinding',
        resource_name => 'system:coredns',
        content       => {
          metadata => {
            annotations => {
              'rbac.authorization.kubernetes.io/autoupdate' => 'true',
            },
            labels      => {
              'kubernetes.io/bootstrapping' => 'rbac-defaults',
            },
          },
          subjects => [
            {
              kind      => 'ServiceAccount',
              name      => 'coredns',
              namespace => 'kube-system',
            },
          ],
          roleRef  => {
            kind     => 'ClusterRole',
            name     => 'system:coredns',
            apiGroup => 'rbac.authorization.k8s.io',
          },
        };

      'coredns ConfigMap':
        api_version => 'v1',
        kind        => 'ServiceAccount',
        content     => {
          data => {
            'Corefile' => @("COREDNS"),
            .:53 {
              errors
              health {
                lameduck 5s
              }
              ready
              kubernetes ${cluster_domain} in-addr.arpa ip6.arpa {
                fallthrough in-adr.arpa ip6.arpa
              }
              prometheus :9153
              forward . /etc/resolv.conf {
                max_concurrent 1000
              }
              cache 30
              loop
              reload
              loadbalance
            }
            |-COREDNS
          },
        };

      'coredns Deployment':
        api_version => 'apps/v1',
        kind        => 'Deployment',
        content     => {
          metadata => {
            labels => {
              'k8s-app'            => 'kube-dns',
              'kubernetes.io/name' => 'CoreDNS',
            },
          },
          spec     => {
            replicas => 2,
            strategy => {
              type          => 'RollingUpdate',
              rollingUpdate => {
                maxUnavailable => 1,
              },
            },
            selector => {
              matchLabels => {
                'k8s-app' => 'kube-dns',
              },
            },
            template => {
              metadata => {
                labels      => {
                  'k8s-app' => 'kube-dns',
                },
              },
              spec     => {
                affinity           => {
                  podAntiAffinity => {
                    preferredDuringSchedulingIgnoredDuringExecution => [
                      {
                        weight          => 100,
                        podAffinityTerm => {
                          labelSelector => {
                            matchExpressions => [
                              {
                                key      => 'k8s-app',
                                operator => 'In',
                                values   => [ 'coredns' ],
                              },
                            ],
                          },
                          topologyKey   => 'kubernetes.io/hostname',
                        },
                      },
                    ],
                  },
                },
                priorityClassName  => 'system-cluster-critical',
                serviceAccountName => 'coredns',
                tolerations        => [
                  {
                    key      => 'CriticalAddonsOnly',
                    operator => 'Exists',
                  },
                  {
                    key    => 'node-role.kubernetes.io/master',
                    effect => 'NoSchedule',
                  },
                ],
                nodeSelector       => {
                  'kubernetes.io/os' => 'linux',
                },
                containers         => [
                  {
                    name            => 'coredns',
                    image           => "${coredns_image}:${coredns_tag}",
                    imagePullPolicy => 'IfNotPresent',
                    resources       => {
                      limits   => {
                        memory => '170Mi',
                      },
                      requests => {
                        cpu    => '100m',
                        memory => '70Mi',
                      },
                    },
                    args            => [ '-conf', '/etc/coredns/Corefile' ],
                    volumeMounts    => [
                      {
                        name      => 'config-volume',
                        mountPath => '/etc/coredns',
                        readOnly  => true,
                      },
                    ],
                    ports           => [
                      {
                        name          => 'dns',
                        protocol      => 'UDP',
                        containerPort => 53
                      },
                      {
                        name          => 'dns-tcp',
                        protocol      => 'TCP',
                        containerPort => 53
                      },
                      {
                        name          => 'metrics',
                        protocol      => 'TCP',
                        containerPort => 9153
                      },
                    ],
                    livenessProbe   => {
                      httpGet            => {
                        path => '/health',
                        port => 8080,
                      },
                      initialDelaySecond => 60,
                      timeoutSeconds     => 5,
                      successThreshold   => 1,
                      failureThreshold   => 5,
                    },
                    readinessProbe  => {
                      httpGget => '/ready',
                      port     => 8181,
                    },
                    securityContext => {
                      allowPrivilegeEscalation => false,
                      capabilities             => {
                        add  => [ 'NET_BIND_SERVICE' ],
                        drop => [ 'all' ],
                      },
                      readOnlyRootFilesystem   => true,
                    },
                  },
                ],
                dnsPolicy          => 'Default',
                volumes            => [
                  {
                    name      => 'config-volume',
                    configMap => {
                      name  => 'coredns',
                      items => [
                        {
                          key  => 'Corefile',
                          path => 'Corefile',
                        },
                      ],
                    },
                  },
                ],
              },
            },
          },
        },
        require     => Kubectl_apply[
          'coredns ServiceAccount',
          'coredns ConfigMap',
        ];

      'coredns Service':
        api_version   => 'v1',
        kind          => 'Service',
        resource_name => 'kube-dns',
        content       => {
          metadata => {
            annotations => {
              'prometheus.io/port'   => '9153',
              'prometheus.io/scrape' => 'true',
            },
            labels      => {
              'k8s-app'                       => 'kube-dns',
              'kubernetes.io/cluster-service' => 'true',
              'kubernetes.io/name'            => 'CoreDNS',
            },
          },
          spec     => {
            selector  => {
              'k8s-app' => 'kube-dns',
            },
            clusterIP => $dns_service_address,
            ports     => [
              {
                name     => 'dns',
                port     => 53,
                protocol => 'UDP',
              },
              {
                name     => 'dns-tcp',
                port     => 53,
                protocol => 'TCP',
              }
            ],
          },
        };
    }
  }

  if $manage_flannel {
    kubectl_apply {
      default:
        namespace     => 'kube-system',
        resource_name => 'flannel',
        kubeconfig    => $kubeconfig;

      'flannel ClusterRole':
        api_version => 'rbac.authorization.k8s.io/v1',
        kind        => 'ClusterRole',
        content     => {
          rules => [
            {
              apiGroups => [''],
              resources => ['pods'],
              verbs     => ['get'],
            },
            {
              apiGroups => [''],
              resources => ['nodes'],
              verbs     => ['list','watch'],
            },
            {
              apiGroups => [''],
              resources => ['nodes/status'],
              verbs     => ['patch'],
            },
          ],
        };

      'flannel ClusterRoleBinding':
        api_version => 'rbac.authorization.k8s.io/v1',
        kind        => 'ClusterRoleBinding',
        content     => {
          subjects => [
            {
              kind      => 'ServiceAccount',
              name      => 'flannel',
              namespace => 'kube-system',
            },
          ],
          roleRef  => {
            kind     => 'ClusterRole',
            name     => 'flannel',
            apiGroup => 'rbac.authorization.k8s.io',
          },
        };

      'flannel ServiceAccount':
        api_version => 'v1',
        kind        => 'ServiceAccount',
        content     => {};

      'flannel ConfigMap':
        api_version => 'v1',
        kind        => 'ConfigMap',
        content     => {
          metadata => {
            labels => {
              tier      => 'node',
              'k8s-app' => 'flannel',
            }
          },
          data     => {
            'cni-conf.json' => to_json({
              name       => 'cbr0',
              cniVersion => '0.3.1',
              plugins    => [
                {
                  type     => 'flannel',
                  delegate => {
                    hairpinMode      => true,
                    isDefaultGateway => true,
                  },
                },
                {
                  type         => 'portmap',
                  capabilities => {
                    portMappings => true,
                  },
                },
              ],
            }),
            'net-conf.json' => to_json({
              'Network' => $cluster_cidr,
              'Backend' => {
                'Type' => 'vxlan',
              },
            }),
          },
        };

      'flannel DaemonSet':
        api_version => 'apps/v1',
        kind        => 'DaemonSet',
        content     => {
          metadata => {
            labels => {
              'tier'    => 'node',
              'k8s-app' => 'flannel',
            },
          },
          spec     => {
            selector       => {
              matchLabels => {
                'tier'    => 'node',
                'k8s-app' => 'flannel',
              },
            },
            template       => {
              metadata => {
                labels => {
                  'tier'    => 'node',
                  'k8s-app' => 'flannel',
                },
              },
              spec     => {
                hostNetwork        => true,
                priorityClassName  => 'system-node-critical',
                serviceAccountName => 'flannel',
                tolerations        => [
                  {
                    effect   => 'NoSchedule',
                    operator => 'Exists',
                  },
                  {
                    effect   => 'NoExecute',
                    operator => 'Exists',
                  },
                ],
                nodeSelector       => {
                  'kubernetes.io/os' => 'linux',
                },
                containers         => [
                  {
                    name            => 'flannel',
                    image           => "${flannel_image}:${flannel_tag}",
                    command         => [ '/opt/bin/flanneld' ],
                    args            => [ '--ip-masq', '--kube-subnet-mgr' ],
                    resources       => {
                      requests => {
                        cpu    => '100m',
                        memory => '50Mi',
                      },
                      limits   => {
                        cpu    => '100m',
                        memory => '50Mi',
                      },
                    },
                    securityContext => {
                      privileged   => false,
                      capabilities => {
                        add => [ 'NET_ADMIN', 'NET_RAW' ],
                      },
                    },
                    env             => [
                      {
                        name      => 'POD_NAME',
                        valueFrom => {
                          fieldRef => {
                            fieldPath => 'metadata.name',
                          },
                        },
                      },
                      {
                        name      => 'POD_NAMESPACE',
                        valueFrom => {
                          fieldRef => {
                            fieldPath => 'metadata.namespace',
                          },
                        },
                      },
                    ],
                    volumeMounts    => [
                      {
                        name      => 'run',
                        mountPath => '/run/flannel',
                      },
                      {
                        name      => 'flannel-cfg',
                        mountPath => '/etc/kube-flannel/',
                      },
                    ],
                  },
                ],
                initContainers     => [
                  {
                    name         => 'install-cni',
                    image        => "${flannel_image}:${flannel_tag}",
                    command      => [ 'cp' ],
                    args         => [
                      '-f',
                      '/etc/kube-flannel/cni.conf.json',
                      '/etc/cni/net.d/10-flannel.conflits',
                    ],
                    volumeMounts => [
                      {
                        name      => 'cni',
                        mountPath => '/etc/cni/net.d',
                      },
                      {
                        name      => 'flannel-cfg',
                        mountPath => '/etc/kube-flannel',
                      },
                    ],
                  },
                ],
                volumes            => [
                  {
                    name     => 'run',
                    hostPath => {
                      path => '/run',
                    },
                  },
                  {
                    name     => 'cni',
                    hostPath => {
                      path => '/etc/kubernetes/cni/net.d',
                    },
                  },
                  {
                    name      => 'flannel-cfg',
                    configMap => {
                      name => 'kube-flannel-cfg',
                    },
                  },
                  {
                    name     => 'host-cni-bin',
                    hostPath => {
                      path => '/opt/cni/bin',
                    },
                  },
                ],
              },
            },
            updateStrategy => {
              rollingUpdate => {
                maxUnavailable => 1,
              },
              type          => 'RollingUpdate',
            },
          },
        };
    }
  }

  kubectl_apply {
    default:
      kubeconfig  => $kubeconfig,
      api_version => 'rbac.authorization.k8s.io/v1',
      kind        => 'ClusterRoleBinding',
      update      => false;

    # 'system:default SA RoleBinding':
    #   name => 'system:default-sa',
    #   data => {
    #     subjects => [
    #       {
    #         kind      => 'ServiceAccount',
    #         name      => 'default',
    #         namespace => 'kube-system',
    #       },
    #     ],
    #     roleRef  => {
    #       kind     => 'ClusterRole',
    #       name     => 'cluster-admin',
    #       apiGroup => 'rbac.authorization.k8s.io',
    #     }
    #   };

    'controller-manager RoleBinding':
      resource_name => 'controller-manager',
      content       => {
        subjects => [
          {
            kind      => 'ServiceAccount',
            name      => 'kube-controller-manager',
            namespace => 'kube-system',
          }
        ],
        roleRef  => {
          kind     => 'ClusterRole',
          name     => 'system:kube-controller-manager',
          apiGroup => 'rbac.authorization.k8s.io',
        },
      };

    'kube-proxy RoleBinding':
      resource_name => 'kube-proxy',
      content       => {
        subjects => [
          {
            kind      => 'ServiceAccount',
            name      => 'kube-proxy',
            namespace => 'kube-system',
          },
        ],
        roleRef  => {
          kind     => 'ClusterRole',
          name     => 'system:node-proxier',
          apiGroup => 'rbac.authorization.k8s.io',
        },
      };
  }
  # Service accounts
  kubectl_apply {
    default:
      kubeconfig  => $kubeconfig,
      api_version => 'v1',
      namespace   => 'kube-system',
      kind        => 'ServiceAccount';

    'kube-controller-manager SA':
      resource_name => 'kube-controller-manager';

    'kube-proxy SA':
      resource_name => 'kube-proxy';
  }
  # Config maps
  kubectl_apply {
    default:
      kubeconfig  => $kubeconfig,
      api_version => 'v1',
      kind        => 'ConfigMap',
      namespace   => 'kube-system',
      update      => false;

    'kubeconfig-in-cluster':
      content => {
        data => {
          kubeconfig => to_yaml({
              apiVersion => 'v1',
              clusters   => [
                {
                  name    => 'local',
                  cluster => {
                    server                  => $direct_master,
                    'certificate-authority' => '/var/run/secrets/kubernetes.io/serviceaccount/ca.crt',
                  },
                }
              ],
              users      => [
                {
                  name => 'service-account',
                  user => {
                    tokenfile => '/var/run/secrets/kubernetes.io/serviceaccount/token',
                  },
                },
              ],
              contexts   => [
                {
                  context => {
                    cluster => 'local',
                    user    => 'service-account',
                  },
                },
              ],
          }),
        },
      };
  }
}