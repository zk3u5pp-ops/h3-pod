"""RunPod 残高表示ノード for ComfyUI.

画面に置いて実行すると、RunPod アカウントの残高をノード内に表示する。
GraphQL 権限付きの RunPod API キーが必要。
"""

import json
import urllib.request
import urllib.error

GRAPHQL_URL = "https://api.runpod.io/graphql"
QUERY = "{ myself { clientBalance } }"


class RunPodBalance:
    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "api_key": ("STRING", {"default": "", "multiline": False}),
            },
        }

    RETURN_TYPES = ()
    FUNCTION = "show_balance"
    CATEGORY = "RunPod"
    OUTPUT_NODE = True

    def show_balance(self, api_key):
        api_key = (api_key or "").strip()
        if not api_key:
            return {"ui": {"text": ["残高: (APIキーを入力してください)"]}}

        try:
            req = urllib.request.Request(
                GRAPHQL_URL,
                data=json.dumps({"query": QUERY}).encode("utf-8"),
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json",
                },
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=15) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                text = "残高: 取得できませんでした (このAPIキーにはGraphQLの権限がありません)"
            else:
                text = f"残高: 取得できませんでした (HTTP {e.code})"
            return {"ui": {"text": [text]}}
        except Exception as e:
            return {"ui": {"text": [f"残高: 取得できませんでした ({e})"]}}

        errors = payload.get("errors")
        if errors:
            msg = errors[0].get("message", "GraphQL error")
            return {"ui": {"text": [f"残高: 取得できませんでした ({msg})"]}}

        try:
            balance = payload["data"]["myself"]["clientBalance"]
        except (KeyError, TypeError):
            return {"ui": {"text": ["残高: 取得できませんでした (応答の形式が想定と異なります)"]}}

        return {"ui": {"text": [f"残高: ${balance:,.2f}"]}}


NODE_CLASS_MAPPINGS = {"RunPodBalance": RunPodBalance}
NODE_DISPLAY_NAME_MAPPINGS = {"RunPodBalance": "RunPod 残高表示"}
