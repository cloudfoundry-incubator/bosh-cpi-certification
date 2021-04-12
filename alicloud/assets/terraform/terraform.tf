variable "access_key" {}
variable "secret_key" {}
variable "region" {}
variable "env_name" {}
variable "public_key" {}

terraform {
  backend "oss" {}
}

provider "alicloud" {
  access_key = "${var.access_key}"
  secret_key = "${var.secret_key}"
  region     = "${var.region}"
}

data "alicloud_zones" "default" {}

# Create a VPC to launch our instances into
resource "alicloud_vpc" "default" {
  name       = "${var.env_name}"
  cidr_block = "172.16.0.0/16"
}

# Create an nat gateway to give our subnet access to the outside world
resource "alicloud_nat_gateway" "default" {
  vpc_id = "${alicloud_vpc.default.id}"
  name   = "${var.env_name}"
}

resource "alicloud_snat_entry" "default" {
  snat_table_id     = "${alicloud_nat_gateway.default.snat_table_ids}"
  source_vswitch_id = "${alicloud_vswitch.default.id}"
  snat_ip           = "${alicloud_eip.natgw.ip_address}"
}

resource "alicloud_vswitch" "default" {
  vpc_id            = "${alicloud_vpc.default.id}"
  cidr_block        = "${cidrsubnet(alicloud_vpc.default.cidr_block, 8, 0)}"
  availability_zone = "${data.alicloud_zones.default.zones.0.id}"
}

resource "alicloud_snat_entry" "alicloud_resources" {
  snat_table_id     = "${alicloud_nat_gateway.default.snat_table_ids}"
  source_vswitch_id = "${alicloud_vswitch.alicloud_resources.id}"
  snat_ip           = "${alicloud_eip.natgw.ip_address}"
}

resource "alicloud_vswitch" "alicloud_resources" {
  vpc_id            = "${alicloud_vpc.default.id}"
  cidr_block        = "${cidrsubnet(alicloud_vpc.default.cidr_block, 8, 1)}"
  availability_zone = "${data.alicloud_zones.default.zones.0.id}"
  name              = "${var.env_name}-alicloud-resources"
}

resource "alicloud_security_group" "allow_all" {
  vpc_id      = "${alicloud_vpc.default.id}"
  name        = "allow_all-${var.env_name}"
  description = "Allow local and concourse traffic"
}

resource "alicloud_security_group_rule" "all-in" {
  type              = "ingress"
  ip_protocol       = "all"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "-1/-1"
  priority          = 1
  security_group_id = "${alicloud_security_group.allow_all.id}"
  cidr_ip           = "0.0.0.0/0"
}

resource "alicloud_security_group_rule" "all-out" {
  type              = "egress"
  ip_protocol       = "all"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "-1/-1"
  priority          = 1
  security_group_id = "${alicloud_security_group.allow_all.id}"
  cidr_ip           = "0.0.0.0/0"
}

resource "alicloud_eip" "director" {
  name                 = "${var.env_name}-director"
  bandwidth            = "10"
  internet_charge_type = "PayByBandwidth"
}

resource "alicloud_eip" "bats" {
  name                 = "${var.env_name}-bats"
  bandwidth            = "10"
  internet_charge_type = "PayByBandwidth"
}

resource "alicloud_eip" "natgw" {
  name                 = "${var.env_name}-nat-gw"
  bandwidth            = "10"
  internet_charge_type = "PayByBandwidth"
}

resource "alicloud_eip_association" "natgw" {
  allocation_id = "${alicloud_eip.natgw.id}"
  instance_id   = "${alicloud_nat_gateway.default.id}"
}

resource "alicloud_slb" "e2e" {
  name                 = "${var.env_name}"
  vswitch_id           = "${alicloud_vswitch.alicloud_resources.id}"
  internet_charge_type = "paybytraffic"
  specification        = "slb.s1.small"
}
resource "alicloud_slb_listener" "slb-80-80" {
  frontend_port    = 80
  protocol         = "http"
  backend_port     = 80
  load_balancer_id = "${alicloud_slb.e2e.id}"
  bandwidth        = 10
  health_check     = "off"

}

resource "alicloud_key_pair" "director" {
  key_name   = "${var.env_name}"
  public_key = "${var.public_key}"

}

output "vpc_id" {
  value = "${alicloud_vpc.default.id}"
}
output "region" {
  value = "${var.region}"
}

# Used by bats
output "key_pair_name" {
  value = "${alicloud_key_pair.director.key_name}"
}

output "security_group_id" {
  value = "${alicloud_security_group.allow_all.id}"
}
output "external_ip" {
  value = "${alicloud_eip.director.ip_address}"
}
output "zone" {
  value = "${alicloud_vswitch.default.availability_zone}"
}
output "vswitch_id" {
  value = "${alicloud_vswitch.default.id}"
}
output "internal_cidr" {
  value = "${alicloud_vpc.default.cidr_block}"
}
output "internal_gw" {
  value = "${cidrhost(alicloud_vpc.default.cidr_block, 1)}"
}
output "dns_recursor_ip" {
  value = "8.8.8.8"
}
output "internal_ip" {
  value = "${cidrhost(alicloud_vpc.default.cidr_block, 6)}"
}
output "reserved_range" {
  value = "${cidrhost(alicloud_vpc.default.cidr_block, 2)}-${cidrhost(alicloud_vpc.default.cidr_block, 9)}"
}
output "static_range" {
  value = "${cidrhost(alicloud_vpc.default.cidr_block, 10)}-${cidrhost(alicloud_vpc.default.cidr_block, 30)}"
}
output "bats_eip" {
  value = "${alicloud_eip.bats.ip_address}"
}
output "network_static_ip_1" {
  value = "${cidrhost(alicloud_vpc.default.cidr_block, 29)}"
}
output "network_static_ip_2" {
  value = "${cidrhost(alicloud_vpc.default.cidr_block, 30)}"
}

output "e2e_slb_name" {
  value = "${alicloud_slb.e2e.id}"
}