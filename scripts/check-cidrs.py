#!/usr/bin/env python3
"""Fail if the NetworkPolicy's ipBlocks stop matching the Terraform subnets.

The NetworkPolicy has to name the public subnet ranges as literals — Kustomize
cannot read Terraform state. That leaves the same fact written in two places,
which is a latent bug rather than a documentation problem: change var.vpc_cidr
or var.az_count and the policy silently stops admitting the load balancer,
while the manifest still applies cleanly and every test still passes.

This recomputes the ranges from terraform/variables.tf and asserts that the
policy admits every public subnet and no private one.
"""

from __future__ import annotations

import ipaddress
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
VARIABLES_TF = ROOT / "terraform" / "variables.tf"
NETWORK_POLICY = ROOT / "k8s" / "base" / "networkpolicy.yaml"

# Mirrors local.public_subnets / local.private_subnets in terraform/main.tf.
NEWBITS = 4
PRIVATE_OFFSET = 8


def variable_default(name: str, body: str) -> str:
    """Extract a variable's default from HCL without a full parser."""
    block = re.search(
        rf'variable\s+"{name}"\s*\{{(.*?)\n\}}', body, re.S
    )
    if not block:
        sys.exit(f"check-cidrs: variable {name!r} not found in {VARIABLES_TF}")

    default = re.search(r'^\s*default\s*=\s*"?([^"\n]+)"?\s*$', block.group(1), re.M)
    if not default:
        sys.exit(f"check-cidrs: variable {name!r} has no default")
    return default.group(1).strip()


def cidrsubnet(prefix: str, newbits: int, netnum: int) -> ipaddress.IPv4Network:
    """Terraform's cidrsubnet(), for the IPv4 case this config uses."""
    base = ipaddress.ip_network(prefix)
    return list(base.subnets(prefixlen_diff=newbits))[netnum]


def policy_allowed_blocks() -> list[ipaddress.IPv4Network]:
    text = NETWORK_POLICY.read_text()
    blocks = re.findall(r"^\s*cidr:\s*([0-9./]+)\s*$", text, re.M)
    if not blocks:
        sys.exit(f"check-cidrs: no ipBlock cidr entries found in {NETWORK_POLICY}")
    return [ipaddress.ip_network(b) for b in blocks]


def main() -> int:
    body = VARIABLES_TF.read_text()
    vpc_cidr = variable_default("vpc_cidr", body)
    az_count = int(variable_default("az_count", body))

    public = [cidrsubnet(vpc_cidr, NEWBITS, i) for i in range(az_count)]
    private = [cidrsubnet(vpc_cidr, NEWBITS, i + PRIVATE_OFFSET) for i in range(az_count)]
    allowed = policy_allowed_blocks()

    print(f"vpc_cidr={vpc_cidr}  az_count={az_count}")
    print(f"policy admits: {', '.join(str(a) for a in allowed)}")

    failures: list[str] = []

    # Every public subnet must be admitted, or the ALB cannot reach the pods.
    for net in public:
        if not any(net.subnet_of(a) for a in allowed):
            failures.append(f"public subnet {net} is NOT admitted — the ALB would be blocked")

    # No private subnet may be admitted, or pod-to-pod traffic is allowed and
    # the default-deny is decorative.
    for net in private:
        if any(net.subnet_of(a) or a.subnet_of(net) for a in allowed):
            failures.append(f"private subnet {net} IS admitted — pod-to-pod traffic would be allowed")

    if failures:
        print("\nFAIL:")
        for f in failures:
            print(f"  - {f}")
        print(
            "\nUpdate the ipBlock entries in k8s/base/networkpolicy.yaml to match "
            "local.public_subnets in terraform/main.tf."
        )
        return 1

    print(f"OK: {len(public)} public subnets admitted, {len(private)} private subnets excluded")
    return 0


if __name__ == "__main__":
    sys.exit(main())
