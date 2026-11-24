"""Approve a physical capture challenge as the existing restricted demo viewer.

No credentials or code values are printed or passed as command-line arguments.
No production service is modified. With explicit owner approval, the optional
temporary session slot changes only the demo viewer's limit from three to four
and restores it immediately. Helper sessions are logged out; the device retains
its own normal viewer session.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import urlencode, urlsplit

from demo import Demo, VERSION, require, save_private


def session_limit(demo, viewer_id, expected, replacement):
    """Change only one field on the current policy, preserving unrelated edits."""
    try:
        demo.login(demo.credentials["admin"])
        policy = demo.api("/Users/" + viewer_id)["Policy"]
        require(policy.get("MaxActiveSessions") == expected,
                "Demo viewer session limit changed concurrently; inspect private checkpoint")
        policy["MaxActiveSessions"] = replacement
        demo.api("/Users/" + viewer_id + "/Policy", "POST", policy)
        require(demo.api("/Users/" + viewer_id)["Policy"].get("MaxActiveSessions") == replacement,
                "Demo viewer session limit readback failed")
    finally:
        demo.logout()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--env", required=True)
    p.add_argument("--server", required=True)
    p.add_argument("--code-file", required=True, type=Path)
    p.add_argument("--temporary-session-slot", action="store_true",
                   help="Requires owner approval: temporarily use four sessions, then restore three")
    a = p.parse_args()
    origin = urlsplit(a.server)
    require(origin.scheme == "https" and origin.hostname and not origin.username
            and not origin.password and not origin.query and not origin.fragment
            and origin.path in ("", "/"), "Use the selected demo HTTPS origin")
    demo = Demo(a.env)
    # macOS curl uses system trust; the local Python trust store may differ.
    public = json.loads(subprocess.check_output([
        "curl", "--fail", "--silent", "--show-error", "--max-time", "25",
        a.server.rstrip("/") + "/System/Info/Public"
    ]))
    require(public.get("Id") == demo.info["Id"] and public.get("Version") == VERSION,
            "Capture origin is not the configured isolated demo")
    code = json.loads(a.code_file.read_text())["code"]
    require(re.fullmatch(r"[0-9]{6}", code) is not None, "Invalid challenge format")
    user = demo.login(demo.credentials["viewer"])
    try:
        require(not user.get("Policy", {}).get("IsAdministrator"), "Use a non-admin viewer")
        original_limit = user.get("Policy", {}).get("MaxActiveSessions")
    finally:
        demo.logout()
    checkpoint = demo.root / "private" / "capture-session-slot.json"
    if a.temporary_session_slot:
        require(original_limit == 3 and not checkpoint.exists(),
                "Expected original three-session limit and no pending recovery checkpoint")
        save_private(checkpoint, {"viewer_id": user["Id"], "original_limit": 3,
                                  "temporary_limit": 4, "server_id": demo.info["Id"]})
    try:
        if a.temporary_session_slot:
            session_limit(demo, user["Id"], 3, 4)
        demo.login(demo.credentials["viewer"])
        require(demo.api("/QuickConnect/Authorize?" + urlencode({"code": code}), "POST") is True,
                "Quick Connect approval was not acknowledged")
    finally:
        demo.logout()
        if a.temporary_session_slot:
            session_limit(demo, user["Id"], 4, 3)
            checkpoint.unlink()
    a.code_file.unlink()
    print(f"Demo {VERSION}: restricted viewer approved capture device; helpers logged out; original limit restored")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        # Demo.api deliberately reports only the endpoint path and HTTP status;
        # its errors never include query values, bodies, passwords or tokens.
        print("Demo capture approval failed: " + str(error))
        raise SystemExit(1)
    except Exception as error:
        # Deliberately omit exceptions that could contain URLs, responses or secrets.
        print("Demo capture approval failed (" + type(error).__name__ + ")")
        raise SystemExit(1)
