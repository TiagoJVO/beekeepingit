"""PreToolUse hook: deny Read/Write/Edit on paths matching this repo's
secret-file conventions (mirrors the patterns in .gitignore: .env, .env.*,
*.local, secrets/, *.pem, *.key). Never raises - any parse failure or
missing file_path falls through to an empty allow decision, so a malformed
hook payload can only fail open, never accidentally block a legitimate
operation with a stack trace.
"""
import sys, json, re

PATTERN = re.compile(
    r"(^|[/\\])(\.env(\..*)?|[^/\\]*\.local|secrets[/\\].*|[^/\\]*\.pem|[^/\\]*\.key)$",
    re.IGNORECASE,
)


def main():
    try:
        payload = json.load(sys.stdin)
        file_path = (payload.get("tool_input") or {}).get("file_path", "") or ""
    except Exception:
        print("{}")
        return

    if file_path and PATTERN.search(file_path):
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": (
                    "Blocked: path matches a secret-file pattern "
                    "(.env/.local/secrets//.pem/.key, per .gitignore) - "
                    "read/write it directly instead of through the agent."
                ),
            }
        }))
    else:
        print("{}")


main()
