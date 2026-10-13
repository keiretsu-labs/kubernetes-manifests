# Bhaiya ops bot Ottawa access

This app creates `bhaiya/bhaiya-ops-bot` for read-only Ottawa diagnosis. Its
cluster grant covers only Namespace and Node names; workload reads are bound in
`bhaiya` and `flux-system`, and Flux reads are bound only in `flux-system`.
The bot identity has no Secret reads, logs, exec, or write verbs.

`bhaiya/bhaiya-ops-bot-kubeconfig-sync` is staged suspended until its API egress
is reviewed. Once enabled, it requests a one-hour token every five minutes. It
refuses to publish a token with less than 20 minutes remaining and
patches only `data.config` in the metadata-only
`bhaiya/bhaiya-ops-bot-kubeconfig` Secret. The generated token and kubeconfig
never enter Git or logs. The CronJob uses its own projected ten-minute API
credential and a separate named-resource Role.

The Bot Computer is not configured to mount this Secret in this change. After
the sync is observed working, the Bhaiya mount allowlist needs the generated
Computer slug and this Secret's `config` key at `/workspace/.kube/config`.
The sync Job and Computer also need reviewed API egress for their specific
labels. Network policy changes are outside this app's current scope. Enable the
CronJob only in the same reviewed change that supplies its egress policy.
