"""Offline integration tests: real Bash/jq, with curl replaced by a local stub."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "cf_dns.sh"
ZONE_ID = "a" * 32
RECORD_ID = "b" * 32
OTHER_ID = "c" * 32
TOKEN = "test-token-never-print-this"

MOCK_CURL = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
from urllib.parse import urlparse

root = Path(os.environ["MOCK_ROOT"])
args = sys.argv[1:]
headers = sys.stdin.read()
request = {
    "method": args[args.index("--request") + 1],
    "path": urlparse(args[-1]).path.removeprefix("/client/v4"),
    "query": [args[i + 1] for i, value in enumerate(args) if value == "--data-urlencode"],
    "authorized": headers == "Authorization: Bearer test-token-never-print-this\nContent-Type: application/json\n",
    "token_in_argv": any("test-token-never-print-this" in arg for arg in args),
    "payload": json.loads(args[args.index("--data-raw") + 1]) if "--data-raw" in args else None,
}
with (root / "requests").open("a") as stream:
    stream.write(json.dumps(request) + "\n")
cursor_path = root / "cursor"
cursor = int(cursor_path.read_text()) if cursor_path.exists() else 0
responses = json.loads((root / "responses").read_text())
cursor_path.write_text(str(cursor + 1))
if cursor >= len(responses):
    sys.exit(98)
response = responses[cursor]
if response.get("exit"):
    sys.exit(response["exit"])
body = response.get("body")
if response.get("echo_write"):
    body = {"success": True, "result": dict(request["payload"], id="b" * 32)}
print(response.get("raw", json.dumps(body)))
print(response.get("status", 200), end="")
'''


def listed(records, pages=1):
    return {"body": {"success": True, "result": records,
                     "result_info": {"total_pages": pages}}}


def zone(zone_id=ZONE_ID, account="Example"):
    return {"id": zone_id, "name": "example.com", "account": {"name": account}}


def record(record_id=RECORD_ID, name="www.example.com", kind="A",
           content="192.0.2.1", proxied=False, ttl=300):
    return {"id": record_id, "name": name, "type": kind, "content": content,
            "proxied": proxied, "ttl": ttl, "comment": "keep me", "tags": ["owner:test"]}


class CloudflareDNSTests(unittest.TestCase):
    def run_script(self, answers, responses, *, hidden_token=False, args=(), trace=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            curl = root / "curl"
            curl.write_text(MOCK_CURL)
            curl.chmod(0o755)
            (root / "responses").write_text(json.dumps(responses))
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", MOCK_ROOT=str(root))
            env.pop("CF_API_TOKEN", None)
            if hidden_token:
                answers = [TOKEN] + answers
            else:
                env["CF_API_TOKEN"] = TOKEN
            command = ["bash", "-x", str(SCRIPT)] if trace else [str(SCRIPT)]
            result = subprocess.run(command + list(args), input="\n".join(answers) + "\n",
                                    text=True, capture_output=True, env=env, timeout=10)
            log = root / "requests"
            requests = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        self.assertNotIn(TOKEN, result.stdout + result.stderr)
        for request in requests:
            self.assertTrue(request["authorized"])
            self.assertFalse(request["token_in_argv"])
        return result, requests

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_create_a_with_defaults(self):
        result, calls = self.run_script(
            ["example.com", "www", "", "192.0.2.10", "", "", "yes", ""],
            [listed([zone()]), listed([]), {"echo_write": True}])
        self.assert_success(result)
        self.assertEqual([call["method"] for call in calls], ["GET", "GET", "POST"])
        self.assertEqual(calls[-1]["path"], f"/zones/{ZONE_ID}/dns_records")
        self.assertEqual(calls[-1]["payload"], {"type": "A", "name": "www.example.com",
                         "content": "192.0.2.10", "proxied": False, "ttl": 1})
        self.assertIn("Saved:", result.stdout)

    def test_create_cname_hidden_token_proxy_and_full_name(self):
        result, calls = self.run_script(
            ["EXAMPLE.COM.", "www.example.com.", "cname", "Target.Example.NET.", "yes", "yes", "no"],
            [listed([zone()]), listed([]), {"echo_write": True}], hidden_token=True, trace=True)
        self.assert_success(result)
        self.assertEqual(calls[-1]["payload"], {"type": "CNAME", "name": "www.example.com",
                         "content": "target.example.net", "proxied": True, "ttl": 1})

    def test_update_uses_patch_and_preserves_unrelated_metadata(self):
        result, calls = self.run_script(
            ["example.com", "www", "A", "192.0.2.2", "", "", "yes", "no"],
            [listed([zone()]), listed([record()]), {"echo_write": True}])
        self.assert_success(result)
        self.assertEqual(calls[-1]["method"], "PATCH")
        self.assertEqual(calls[-1]["path"], f"/zones/{ZONE_ID}/dns_records/{RECORD_ID}")
        self.assertEqual(calls[-1]["payload"], {"type": "A", "name": "www.example.com",
                         "content": "192.0.2.2", "proxied": False, "ttl": 300})

    def test_multiple_records_selects_only_chosen_id(self):
        result, calls = self.run_script(
            ["example.com", "www", "A", "0", "3", "2", "", "", "", "yes", "no"],
            [listed([zone()]), listed([record(), record(OTHER_ID, content="192.0.2.2")]),
             {"echo_write": True}])
        self.assert_success(result)
        self.assertEqual(calls[-1]["path"], f"/zones/{ZONE_ID}/dns_records/{OTHER_ID}")
        self.assertEqual(calls[-1]["payload"]["content"], "192.0.2.2")
        self.assertEqual(len(calls), 3)

    def test_cname_update_preserves_content_proxy_and_ttl_defaults(self):
        result, calls = self.run_script(
            ["example.com", "www", "CNAME", "", "", "yes", "no"],
            [listed([zone()]), listed([record(kind="CNAME", content="target.example.net", proxied=True, ttl=1)]),
             {"echo_write": True}])
        self.assert_success(result)
        self.assertEqual(calls[-1]["method"], "PATCH")
        self.assertEqual(calls[-1]["payload"]["content"], "target.example.net")
        self.assertTrue(calls[-1]["payload"]["proxied"])
        self.assertEqual(calls[-1]["payload"]["ttl"], 1)

    def test_existing_enterprise_ttl_is_retained(self):
        result, calls = self.run_script(
            ["example.com", "www", "A", "", "", "", "yes", "no"],
            [listed([zone()]), listed([record(ttl=45)]), {"echo_write": True}])
        self.assert_success(result)
        self.assertEqual(calls[-1]["payload"]["ttl"], 45)

    def test_confirmation_defaults_to_cancel(self):
        result, calls = self.run_script(
            ["example.com", "@", "A", "192.0.2.1", "no", "1", "", "no"],
            [listed([zone()]), listed([])])
        self.assert_success(result)
        self.assertEqual(len(calls), 2)
        self.assertIn("Cancelled. No changes sent.", result.stdout)
        self.assertIn("name=example.com", calls[1]["query"])

    def test_invalid_inputs_repeat_until_valid(self):
        result, calls = self.run_script(
            ["https://example.com", "example.com", "other.net.", "bad/name", "app.api",
             "TXT", "A", "256.1.1.1", "01.2.3.4", "1.2.3", "192.0.2.1",
             "maybe", "no", "0", "59", "86401", "3600", "yes", "no"],
            [listed([zone()]), listed([]), {"echo_write": True}])
        self.assert_success(result)
        self.assertEqual(calls[-1]["payload"]["name"], "app.api.example.com")
        self.assertEqual(calls[-1]["payload"]["ttl"], 3600)

    def test_invalid_cname_target(self):
        result, calls = self.run_script(
            ["example.com", "www", "CNAME", "https://target.example.net", "192.0.2.1",
             "www.example.com", "target.example.net", "no", "", "yes", "no"],
            [listed([zone()]), listed([]), {"echo_write": True}])
        self.assert_success(result)
        self.assertEqual(calls[-1]["payload"]["content"], "target.example.net")

    def test_multiple_zones_and_record_pagination(self):
        result, calls = self.run_script(
            ["example.com", "2", "www", "A", "", "", "", "yes", "no"],
            [listed([zone()], pages=2), listed([zone(OTHER_ID, "Second")], pages=2),
             listed([], pages=2), listed([record()], pages=2), {"echo_write": True}])
        self.assert_success(result)
        self.assertIn("page=2", calls[1]["query"])
        self.assertIn("page=2", calls[3]["query"])
        self.assertEqual(calls[-1]["path"], f"/zones/{OTHER_ID}/dns_records/{RECORD_ID}")

    def test_missing_zone(self):
        result, calls = self.run_script(["example.com"], [listed([])])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No accessible zone", result.stderr)
        self.assertEqual(len(calls), 1)

    def test_authentication_failure_redacts_token(self):
        result, calls = self.run_script(["example.com"], [{"status": 403, "body": {
            "success": False, "errors": [{"code": 10000, "message": f"Invalid token {TOKEN}"}]}}])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HTTP 403", result.stderr)
        self.assertIn("[redacted]", result.stderr)
        self.assertEqual(len(calls), 1)

    def test_network_failure(self):
        result, calls = self.run_script(["example.com"], [{"exit": 28}])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("connection, TLS, or timeout", result.stderr)
        self.assertEqual(len(calls), 1)

    def test_malformed_response(self):
        result, _ = self.run_script(["example.com"], [{"raw": "<html>Bad gateway</html>", "status": 502}])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("malformed response", result.stderr)

    def test_invalid_list_response(self):
        result, _ = self.run_script(["example.com"], [{"body": {"success": True, "result": {}}}])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid list", result.stderr)

    def test_api_write_error_is_reported_even_with_http_200(self):
        result, calls = self.run_script(
            ["example.com", "www", "A", "192.0.2.1", "no", "", "yes"],
            [listed([zone()]), listed([]), {"body": {"success": False, "errors": [
                {"code": 1004, "message": "DNS validation error"}]}}])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("1004: DNS validation error", result.stderr)
        self.assertNotIn("Saved:", result.stdout)
        self.assertEqual(len(calls), 3)

    def test_invalid_saved_record_does_not_report_success(self):
        result, _ = self.run_script(
            ["example.com", "www", "A", "192.0.2.1", "no", "", "yes"],
            [listed([zone()]), listed([]), {"body": {"success": True, "result": None}}])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Check the record before retrying", result.stderr)
        self.assertNotIn("Saved:", result.stdout)

    def test_conflicts_never_write(self):
        for kind, conflict in [("A", "CNAME"), ("CNAME", "A"), ("CNAME", "AAAA"), ("A", "NS")]:
            with self.subTest(kind=kind, conflict=conflict):
                result, calls = self.run_script(["example.com", "www", kind],
                                               [listed([zone()]), listed([record(kind=conflict)])])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Conflicting records", result.stderr)
                self.assertEqual(len(calls), 2)

    def test_manage_another_record_reuses_zone(self):
        result, calls = self.run_script(
            ["example.com", "@", "A", "192.0.2.1", "no", "", "yes", "yes",
             "*.app", "CNAME", "target.example.net", "no", "", "yes", "no"],
            [listed([zone()]), listed([]), {"echo_write": True}, listed([]), {"echo_write": True}])
        self.assert_success(result)
        self.assertEqual(len(calls), 5)
        self.assertEqual(calls[2]["payload"]["name"], "example.com")
        self.assertEqual(calls[4]["payload"]["name"], "*.app.example.com")

    def test_eof_before_confirmation_never_writes(self):
        result, calls = self.run_script(["example.com", "www", "A", "192.0.2.1"],
                                       [listed([zone()]), listed([])])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Input ended", result.stderr)
        self.assertEqual(len(calls), 2)

    def test_write_failure_is_not_retried(self):
        result, calls = self.run_script(
            ["example.com", "www", "A", "192.0.2.1", "no", "", "yes"],
            [listed([zone()]), listed([]), {"exit": 28}])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Check the record before retrying", result.stderr)
        self.assertEqual(len(calls), 3)

    def test_help_makes_no_requests(self):
        result, calls = self.run_script([], [], args=["--help"])
        self.assert_success(result)
        self.assertIn("Usage:", result.stdout)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
