"""Focused checks for the proposed ops bot grant and token delivery."""

import datetime
import importlib.util
import json
import unittest
from pathlib import Path
from unittest.mock import patch

import yaml


DIRECTORY = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location("ops_sync", DIRECTORY / "sync.py")
SYNC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SYNC)


class OpsBotTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.objects = list(yaml.safe_load_all((DIRECTORY / "rbac.yaml").read_text()))

    def object(self, kind, name, namespace=None):
        return next(
            obj for obj in self.objects
            if obj["kind"] == kind
            and obj["metadata"]["name"] == name
            and obj["metadata"].get("namespace") == namespace
        )

    def test_bot_grants_exact_design_scope(self):
        bot = self.object("ServiceAccount", "bhaiya-ops-bot", "bhaiya")
        self.assertFalse(bot["automountServiceAccountToken"])
        cluster = self.object("ClusterRole", "bhaiya-ops-bot-cluster-read")
        cluster_binding = self.object("ClusterRoleBinding", "bhaiya-ops-bot-cluster-read")
        self.assertEqual(cluster_binding["roleRef"], {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "bhaiya-ops-bot-cluster-read"})
        self.assertEqual(cluster_binding["subjects"], [{"kind": "ServiceAccount", "name": "bhaiya-ops-bot", "namespace": "bhaiya"}])
        self.assertEqual(cluster["rules"], [{
            "apiGroups": [""], "resources": ["namespaces", "nodes"],
            "verbs": ["get", "list", "watch"],
        }])
        workload = self.object("ClusterRole", "bhaiya-ops-bot-workload-read")
        self.assertEqual({tuple(rule["apiGroups"]): set(rule["resources"]) for rule in workload["rules"]}, {
            ("",): {"pods", "services", "endpoints", "persistentvolumeclaims", "events"},
            ("events.k8s.io",): {"events"},
            ("apps",): {"deployments", "replicasets", "statefulsets", "daemonsets"},
            ("batch",): {"jobs", "cronjobs"},
            ("networking.k8s.io",): {"networkpolicies"},
        })
        flux = self.object("Role", "bhaiya-ops-bot-flux-read", "flux-system")
        self.assertEqual({tuple(rule["apiGroups"]): set(rule["resources"]) for rule in flux["rules"]}, {
            ("source.toolkit.fluxcd.io",): {"gitrepositories", "ocirepositories", "helmrepositories"},
            ("kustomize.toolkit.fluxcd.io",): {"kustomizations"},
            ("helm.toolkit.fluxcd.io",): {"helmreleases"},
        })
        for role in (workload, flux):
            self.assertTrue(all(set(rule["verbs"]) == {"get", "list", "watch"} for rule in role["rules"]))
        bindings = [obj for obj in self.objects if obj["kind"] == "RoleBinding"]
        self.assertEqual({(obj["metadata"]["name"], obj["metadata"]["namespace"]) for obj in bindings}, {
            ("bhaiya-ops-bot-workload-read", "bhaiya"),
            ("bhaiya-ops-bot-workload-read", "flux-system"),
            ("bhaiya-ops-bot-flux-read", "flux-system"),
            ("bhaiya-ops-bot-kubeconfig-sync", "bhaiya"),
        })
        for binding in bindings[:3]:
            self.assertEqual(binding["subjects"], [{"kind": "ServiceAccount", "name": "bhaiya-ops-bot", "namespace": "bhaiya"}])
        self.assertEqual(len([obj for obj in self.objects if obj["kind"] == "ClusterRoleBinding"]), 1)

    def test_sync_grant_is_named_only_and_target_is_empty(self):
        sync = self.object("Role", "bhaiya-ops-bot-kubeconfig-sync", "bhaiya")
        sync_binding = self.object("RoleBinding", "bhaiya-ops-bot-kubeconfig-sync", "bhaiya")
        self.assertEqual(sync_binding["subjects"], [{"kind": "ServiceAccount", "name": "bhaiya-ops-bot-kubeconfig-sync", "namespace": "bhaiya"}])
        self.assertEqual(sync["rules"], [
            {"apiGroups": [""], "resources": ["serviceaccounts/token"], "resourceNames": ["bhaiya-ops-bot"], "verbs": ["create"]},
            {"apiGroups": [""], "resources": ["secrets"], "resourceNames": ["bhaiya-ops-bot-kubeconfig"], "verbs": ["patch"]},
        ])
        secret = yaml.safe_load((DIRECTORY / "kubeconfig-secret.yaml").read_text())
        self.assertEqual(secret["metadata"]["name"], "bhaiya-ops-bot-kubeconfig")
        self.assertFalse("data" in secret or "stringData" in secret)
        cron = yaml.safe_load((DIRECTORY / "sync-cronjob.yaml").read_text())
        self.assertTrue(cron["spec"]["suspend"])
        pod = cron["spec"]["jobTemplate"]["spec"]["template"]["spec"]
        self.assertFalse(pod["automountServiceAccountToken"])
        self.assertEqual(pod["serviceAccountName"], "bhaiya-ops-bot-kubeconfig-sync")
        token_sources = [source["serviceAccountToken"] for volume in pod["volumes"]
                         for source in volume.get("projected", {}).get("sources", [])
                         if "serviceAccountToken" in source]
        self.assertEqual(token_sources, [{"path": "token", "expirationSeconds": 600}])

    def test_short_token_is_rejected_before_patch(self):
        now = datetime.datetime(2026, 10, 13, tzinfo=datetime.timezone.utc)
        for minutes in (0, 19):
            expires = (now + datetime.timedelta(minutes=minutes)).isoformat()
            with self.assertRaisesRegex(RuntimeError, "less than 20 minutes"):
                SYNC.token_from_response({"status": {"token": "sensitive", "expirationTimestamp": expires}}, now)
        expires = (now + datetime.timedelta(minutes=20)).isoformat()
        self.assertEqual(SYNC.token_from_response({"status": {"token": "sensitive", "expirationTimestamp": expires}}, now), "sensitive")

    def test_request_and_patch_use_only_named_resources(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        expires = (now + datetime.timedelta(hours=1)).isoformat()
        token_reply = {"status": {"token": "sensitive", "expirationTimestamp": expires}}
        with patch.object(SYNC, "request_json", side_effect=[token_reply, {}]) as request, \
             patch.object(SYNC.Path, "read_text", return_value="job-token"), \
             patch.object(SYNC.Path, "read_bytes", return_value=b"ca-data"):
            SYNC.main()
        self.assertEqual(request.call_count, 2)
        issue, update = [call.args for call in request.call_args_list]
        self.assertEqual(issue[1], "POST")
        self.assertTrue(issue[0].endswith("/namespaces/bhaiya/serviceaccounts/bhaiya-ops-bot/token"))
        self.assertEqual(issue[4]["spec"], {"expirationSeconds": 3600})
        self.assertEqual(update[1], "PATCH")
        self.assertTrue(update[0].endswith("/namespaces/bhaiya/secrets/bhaiya-ops-bot-kubeconfig"))
        self.assertEqual(set(update[4]), {"data"})
        self.assertEqual(set(update[4]["data"]), {"config"})
        config = json.loads(__import__("base64").b64decode(update[4]["data"]["config"]))
        self.assertEqual(config["users"][0]["user"]["token"], "sensitive")


if __name__ == "__main__":
    unittest.main()
