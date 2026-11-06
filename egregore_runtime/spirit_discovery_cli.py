"""Neutral discovery CLI; fixed adapters provide runtime outside request data."""
import json
from pathlib import Path
import sys
from .spirit_discovery import DiscoveryError, discover, parse_json, query_request

def main(*, runtime=None, argv=None):
    args=list(sys.argv[1:] if argv is None else argv)
    try:
        if args == ['--json']:
            raw=sys.stdin.buffer.read(4097)
            if len(raw)>4096: raise DiscoveryError('invalid-query')
            request=parse_json(raw)
        elif len(args) in (1,2):
            request={'operation':args[0]}
            if len(args)==2: request['query' if args[0]=='capabilities.find' else 'id']=args[1]
        else: raise DiscoveryError('invalid-query')
        query_request(request)
        root=Path(__file__).absolute().parent.parent
        print(json.dumps(discover(root,request,runtime=runtime),ensure_ascii=False))
        return 0
    except (DiscoveryError, OSError, UnicodeError, ValueError, TypeError, RecursionError):
        print(json.dumps({'schema':'egregore.capability-query-error/v1','error':'invalid-or-unavailable-discovery','execution_authority':False}))
        return 2
if __name__=='__main__': sys.exit(main())
