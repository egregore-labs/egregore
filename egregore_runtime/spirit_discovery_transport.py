"""Private bounded transport child; no provider or model execution."""
import json
import sys
from .spirit_discovery import _http_get_inner, parse_json

def main():
    try:
        raw=sys.stdin.buffer.read(20001)
        if len(raw)>20000: return 2
        value=parse_json(raw)
        result=_http_get_inner(value['origin'],value['params'],value['headers'])
        output=json.dumps(result,ensure_ascii=False).encode()
        if len(output)>2000000: return 2
        sys.stdout.buffer.write(output)
        return 0
    except Exception:
        return 2
if __name__=='__main__': sys.exit(main())
