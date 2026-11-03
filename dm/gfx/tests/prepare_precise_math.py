from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from dmsh_nx2_build import precise_helpers
source=Path(sys.argv[1]).read_text()
result=precise_helpers(source)
assert result.count('#pragma metal fp contract(off)')==5
assert '[[clang::optnone]]' not in result
# Unrelated compiler workarounds must not be rewritten.
probe='[[clang::optnone]] T spvMulExtended(V l, V r)\n{ return T(l*r); }'
assert precise_helpers(probe)==probe
Path(sys.argv[2]).write_text(result)
