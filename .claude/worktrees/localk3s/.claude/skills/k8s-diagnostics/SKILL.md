---
name: k8s-diagnostics
description: AI-powered Kubernetes troubleshooting using k8sgpt and kubectl.
allowed-tools:
  - shell
---

# K8s Diagnostics Skill

Use this skill when the user reports a cluster issue, a failing pod, or an "OOMKilled" event.

## Troubleshooting Workflow
1. **Initial Scan**: Run `k8sgpt analyze --explain --filter=Pod,Deployment,Service`
2. **Context Gathering**: If `k8sgpt` identifies a pod, run `kubectl get events --namespace <ns> --sort-by='.lastTimestamp'`
3. **Deep Dive**: Get the last 50 lines of logs for the failing container.
4. **Remediation**:
    - Analyze the root cause (e.g., Resource Limits, Probe failure, ConfigMap mismatch).
    - Propose a YAML patch.
    - Ask the user: "I've identified the fix. Should I apply this patch via kubectl?"

## Guidelines
- Always check the `kube-system` namespace if a global issue is suspected.
- Use the **Claude 4.5/4.6 Sonnet** reasoning to correlate multiple errors.


