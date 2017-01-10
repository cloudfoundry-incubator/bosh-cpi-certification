#!/usr/bin/env bash

set -e

source pipelines/aws/utils.sh

: ${AWS_ACCESS_KEY:?}
: ${AWS_SECRET_KEY:?}
: ${AWS_REGION_NAME:?}
: ${BOSH_CLIENT:?}
: ${BOSH_CLIENT_SECRET:?}
: ${AWS_STACK_NAME:?}
: ${STEMCELL_NAME:?}

export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY}
export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_KEY}
export AWS_DEFAULT_REGION=${AWS_REGION_NAME}

# inputs
stemcell_path="$(realpath stemcell/*.tgz)"
e2e_release="$(realpath pipelines/aws/assets/e2e-test-release)"
bosh_cli=$(realpath bosh-cli/bosh-cli-*)
chmod +x $bosh_cli

: ${SUBNET_ID:=$(            stack_info "PublicSubnetID")}
: ${AVAILABILITY_ZONE:=$(    stack_info "AvailabilityZone")}
: ${DIRECTOR_IP:=$(          stack_info "DirectorEIP")}
: ${IAM_INSTANCE_PROFILE:=$( stack_info "IAMInstanceProfile")}
: ${ELB_NAME:=$(             stack_info "ELB")}

time $bosh_cli -n env ${DIRECTOR_IP//./-}.sslip.io

e2e_deployment_name=e2e-test
e2e_release_version=1.0.0

# TODO: remove `cp` line once this story has been accepted: https://www.pivotaltracker.com/story/show/128789021
e2e_release_home="$HOME/${e2e_release##*/}"
cp -r ${e2e_release} ${e2e_release_home}
pushd ${e2e_release_home}
  time $bosh_cli -n create-release --force --name ${e2e_deployment_name} --version ${e2e_release_version}
  time $bosh_cli -n upload-release
popd

time $bosh_cli -n upload-stemcell "${stemcell_path}"

e2e_manifest_filename=e2e-manifest.yml
e2e_cloud_config_filename=e2e-cloud-config.yml

cat > "${e2e_cloud_config_filename}" <<EOF
networks:
  - name: private
    type: dynamic
    cloud_properties: {subnet: ${SUBNET_ID}}

vm_types:
  - name: default
    cloud_properties: &default_cloud_properties
      instance_type: m3.medium
      availability_zone: ${AVAILABILITY_ZONE}
  - name: raw_ephemeral_pool
    cloud_properties:
      <<: *default_cloud_properties
      raw_instance_storage: true
  - name: elb_registration_pool
    cloud_properties:
      <<: *default_cloud_properties
      elbs: [${ELB_NAME}]
  - name: spot_instance_pool
    cloud_properties:
      <<: *default_cloud_properties
      spot_bid_price: 0.10 # 10x the normal bid price

compilation:
  reuse_compilation_vms: true
  workers: 1
  network: private
  cloud_properties:
    instance_type: m3.medium
    availability_zone: ${AVAILABILITY_ZONE}
EOF


cat > "${e2e_manifest_filename}" <<EOF
---
name: ${e2e_deployment_name}

releases:
  - name: ${e2e_deployment_name}
    version: latest

update:
  canaries: 1
  canary_watch_time: 30000-240000
  update_watch_time: 30000-600000
  max_in_flight: 3

stemcells:
  - alias: stemcell
    name: ${STEMCELL_NAME}
    version: latest

instance_groups:
  - name: iam-instance-profile-test
    jobs:
    - name: iam-instance-profile-test
      release: ${e2e_deployment_name}
      properties:
        iam_instance_profile: ${IAM_INSTANCE_PROFILE}
    stemcell: stemcell
    lifecycle: errand
    instances: 1
    vm_type: default
    networks:
      - name: private
        default: [dns, gateway]
  - name: raw-ephemeral-disk-test
    jobs:
      - name: raw-ephemeral-disk-test
        release: ${e2e_deployment_name}
        properties: {}
    stemcell: stemcell
    lifecycle: errand
    instances: 1
    vm_type: raw_ephemeral_pool
    networks:
      - name: private
        default: [dns, gateway]
  - name: elb-registration-test
    jobs:
      - name: elb-registration-test
        release: ${e2e_deployment_name}
        properties:
          load_balancer_name: ${ELB_NAME}
          aws_region: ${AWS_REGION_NAME}
    stemcell: stemcell
    lifecycle: errand
    instances: 1
    vm_type: elb_registration_pool
    networks:
      - name: private
        default: [dns, gateway]
  - name: spot-instance-test
    jobs:
      - name: spot-instance-test
        release: ${e2e_deployment_name}
        properties:
          aws_region: ${AWS_REGION_NAME}
    stemcell: stemcell
    lifecycle: errand
    instances: 1
    vm_type: spot_instance_pool
    networks:
      - name: private
        default: [dns, gateway]
EOF

time $bosh_cli -n update-cloud-config "${e2e_cloud_config_filename}"

time $bosh_cli -n deploy -d ${e2e_deployment_name} "${e2e_manifest_filename}"

time $bosh_cli -n run-errand -d ${e2e_deployment_name} iam-instance-profile-test

time $bosh_cli -n run-errand -d ${e2e_deployment_name} raw-ephemeral-disk-test

time $bosh_cli -n run-errand -d ${e2e_deployment_name} elb-registration-test

# spot instances do not work in China
if [ "${AWS_REGION_NAME}" != "cn-north-1" ]; then
  time $bosh_cli -n run-errand -d ${e2e_deployment_name} spot-instance-test
else
  echo "Skipping spot instance tests for ${AWS_REGION_NAME}..."
fi
